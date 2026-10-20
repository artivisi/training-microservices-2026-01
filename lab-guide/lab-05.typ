#import "../_template/panduan.typ": note, perintah

= Lab 5: _Saga_, _Transactional Outbox_, dan Kafka

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

- membuat mutasi saldo di `account` menjadi _idempotent_ dengan _unique index_ atas `reference`, sehingga _retry_ setelah _timeout_ aman dilakukan;
- menjalankan transfer sebagai _saga_ yang diatur oleh `transfer` (_orchestration_), lengkap dengan langkah kompensasi ketika _credit_ gagal setelah _debit_ berhasil;
- memberi langkah kompensasi _retry policy_ tersendiri yang tidak melewati _circuit breaker_, sehingga gangguan singkat di `account` tidak membuat uang tertahan;
- menyimpan perubahan status transfer dan _event_-nya dalam satu transaksi database melalui pola _transactional outbox_;
- mengirim _event_ dari tabel `outbox` ke Kafka dengan _relay_ dan memahami jaminan _at-least-once_ yang dihasilkannya;
- membuat service ketiga, `notification`, yang membaca _event_ dari Kafka sebagai anggota _consumer group_.

== Gambaran

Di akhir Lab 4, `transfer` memanggil `account` melalui gRPC dengan _timeout_, _retry_, dan _circuit breaker_. Dua celah dari Lab 2 masih tersisa. Pertama, _debit_ yang terkena _timeout_ tidak boleh di-_retry_, karena `account` mungkin sudah memproses _debit_ tersebut dan _retry_ akan memotong saldo dua kali. Kedua, bila _credit_ ke rekening tujuan gagal setelah _debit_ berhasil, uang sudah keluar dari rekening asal tetapi tidak masuk ke rekening tujuan. Transfer hanya ditandai `FAILED` (HTTP `502`, `ErrCreditFailed`) dan uang tersebut harus dikembalikan secara manual.

Lab ini menutup kedua celah tersebut dan sekaligus menambah service ketiga:

+ *Mutasi _idempotent_.* Setiap _debit_ dan _credit_ membawa `reference` (ID transfer). `account` menerapkan mutasi dengan kombinasi rekening, jenis, dan `reference` yang sama hanya sekali. Panggilan ulang dijawab sukses dengan saldo saat ini. Dengan jaminan tersebut, `transfer` boleh me-_retry_ panggilan yang terkena _timeout_.
+ *_Saga_.* Transfer terdiri atas langkah-langkah lokal, dan setiap langkah yang sudah berhasil memiliki langkah kompensasi. Dua panggilan ke `account` tidak bisa disatukan dalam satu transaksi database, sehingga _rollback_ diganti dengan langkah yang membatalkan efek langkah sebelumnya: _credit_ balik ke rekening asal (_reversal_). _Reversal_ dikirim lewat koneksi gRPC tersendiri yang tidak melewati _circuit breaker_ dan terus di-_retry_ hingga 30 detik.
+ *_Transactional outbox_.* Service lain perlu mengetahui hasil transfer. `transfer` tidak mengirim _event_ langsung ke Kafka, tetapi menulisnya ke tabel `outbox` dalam transaksi yang sama dengan perubahan status. _Relay_ di dalam `transfer` kemudian mengirim isi tabel tersebut ke Kafka.
+ *`notification`.* Service baru ini membaca _event_ dari _topic_ `transfer-events`, menyimpan satu baris notifikasi per _event_, lalu mencatat log `notification sent` sebagai pengganti pengiriman SMS atau _push notification_.

#perintah[```
 channel ── POST /transfers ──▶ transfer ── gRPC Debit / Credit ──▶ account
                                  │                                   │
                       db-transfer: transfer + outbox       db-account: account + mutation
                       (satu transaksi per perubahan)       (unique: account, type, reference)
                                  │
                         relay, setiap 500 ms
                                  ▼
                 Kafka, topic transfer-events (3 partition, key = transfer_id)
                                  │
                       consumer group "notification"
                                  ▼
                            notification ──▶ db-notification
```]

Status transfer mengikuti _state machine_ (mesin status) berikut. _Event_ hanya dihasilkan untuk status akhir yang perlu diketahui service lain.

#table(
  columns: (auto, 1fr, auto),
  [Status], [Kondisi], [_Event_],
  [`PENDING`], [Transfer tercatat, _debit_ belum berhasil], [–],
  [`DEBITED`], [_Debit_ rekening asal berhasil], [–],
  [`COMPLETED`], [_Credit_ rekening tujuan berhasil], [`TransferCompleted`],
  [`FAILED`], [_Debit_ gagal, saldo tidak berubah], [`TransferFailed`],
  [`COMPENSATED`], [_Credit_ gagal, lalu _debit_ dikembalikan dengan _credit_ ke rekening asal], [`TransferCompensated`],
  [`COMPENSATION_FAILED`], [_Credit_ gagal dan pengembalian juga gagal, sehingga perlu penanganan manual], [–],
)

Mengapa tidak langsung menulis ke Kafka setelah transaksi database selesai? Database dan Kafka tidak memiliki transaksi bersama. Bila proses berhenti di antara keduanya, ada dua kemungkinan buruk: status sudah tersimpan tetapi _event_-nya hilang, atau _event_ terkirim untuk perubahan yang ternyata di-_rollback_. Dengan tabel `outbox`, perubahan status dan _event_ ditulis ke database yang sama, sehingga keduanya dapat disimpan dalam satu transaksi.

== Titik Awal

Lab ini melanjutkan kondisi akhir Lab 4. Peserta yang belum menyelesaikan Lab 4 dapat memulai dari _checkpoint_-nya:

#perintah[```bash
git checkout lab-04
cd studi-kasus
```]

Semua perintah di bab ini dijalankan dari folder `studi-kasus`, kecuali bila disebutkan lain.

Lab ini dimulai dengan database kosong. Hentikan service `account` dan `transfer` yang masih berjalan dari Lab 4 (`Ctrl+C`), lalu hapus seluruh data lab:

#perintah[```bash
make infra-reset
```]

Langkah ini wajib. _Unique index_ baru di tabel `mutation` (bagian berikutnya) gagal dibuat bila database dari Lab 1–4 sudah berisi mutasi dengan `reference` ganda, dan `account` berhenti saat _startup_ dengan _error_ `apply schema: ... could not create unique index "mutation_idempotency" (SQLSTATE 23505)`. Infrastruktur dijalankan lagi setelah Kafka ditambahkan ke `compose.yaml`.

== Langkah

=== Kafka dan Database Notification di Docker Compose

Kafka dijalankan sebagai satu _node_ dalam mode KRaft: satu proses berperan sebagai _broker_ sekaligus _controller_, tanpa ZooKeeper. Service berjalan di laptop, sedangkan _container_ pembuat _topic_ berjalan di jaringan Docker Compose. Kedua kelompok _client_ tersebut membutuhkan alamat yang berbeda, karena _client_ Kafka hanya menggunakan alamat _bootstrap_ untuk kontak pertama. Setelah itu _client_ menghubungi _advertised listener_, yaitu alamat yang dikirimkan _broker_ untuk _listener_ tersebut. Karena itu ada dua _listener_ untuk _client_: `HOST` (`localhost:19092`) untuk service di laptop dan `INTERNAL` (`kafka:29092`) untuk _container_. Port `HOST` di laptop adalah 19092, bukan port bawaan Kafka 9092, agar tidak bentrok dengan Kafka lain yang mungkin sudah berjalan di laptop.

_Topic_ dibuat secara sengaja oleh _container_ `kafka-init` yang hanya berjalan sekali, dan pembuatan _topic_ otomatis dimatikan. Bila nama _topic_ di konfigurasi service salah ketik, service langsung gagal dengan _error_ dan _topic_ baru tidak terbentuk. _Topic_ `transfer-events` dibuat dengan 3 _partition_ agar hingga tiga _instance_ `notification` dapat bekerja paralel. Semua _event_ dengan _key_ yang sama (ID transfer) selalu masuk ke _partition_ yang sama sehingga urutannya terjaga.

Tambahkan tiga service berikut ke `compose.yaml`, di bawah `db-transfer`:

```yaml
  db-notification:
    image: postgres:18.6-alpine
    environment:
      POSTGRES_DB: notification
      POSTGRES_USER: notification
      POSTGRES_PASSWORD: notification123
    ports:
      - "15434:5432"
    volumes:
      - db-notification:/var/lib/postgresql
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "notification", "-d", "notification"]
      interval: 2s
      retries: 30

  # Single-node Kafka in KRaft mode: the same process is broker and controller,
  # no ZooKeeper. Two client listeners:
  #   HOST     localhost:19092 for the services running on the laptop
  #   INTERNAL kafka:29092 for containers on the compose network (kafka-init)
  # A client connects to the bootstrap address, then reconnects to the address
  # the broker advertises for its listener; that is why each audience needs its
  # own listener.
  kafka:
    image: apache/kafka:4.3.1
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: HOST://:19092,INTERNAL://:29092,CONTROLLER://:9093
      KAFKA_ADVERTISED_LISTENERS: HOST://localhost:19092,INTERNAL://kafka:29092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: HOST:PLAINTEXT,INTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: INTERNAL
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@localhost:9093
      # One broker: internal topics cannot have more than one replica.
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      # A new consumer gets its partitions at once instead of after 3 s.
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      # Topics are created on purpose (kafka-init), never by a typo in a client.
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "false"
      KAFKA_LOG_DIRS: /var/lib/kafka/data
    ports:
      - "19092:19092"
    volumes:
      - kafka:/var/lib/kafka/data
    healthcheck:
      test: ["CMD", "/opt/kafka/bin/kafka-broker-api-versions.sh", "--bootstrap-server", "localhost:19092"]
      interval: 5s
      timeout: 10s
      retries: 30

  # One-shot: creates the topic and exits. 3 partitions = up to 3 consumers of
  # one group work in parallel; events with the same key (transfer ID) always
  # land in the same partition, so they stay in order.
  # Profile "init" keeps it out of "up --wait", which waits for running
  # containers and does not expect one that exits; make infra-up runs it with
  # "docker compose run" after Kafka is healthy.
  kafka-init:
    image: apache/kafka:4.3.1
    profiles: ["init"]
    depends_on:
      kafka:
        condition: service_healthy
    entrypoint: ["/opt/kafka/bin/kafka-topics.sh"]
    command: ["--bootstrap-server", "kafka:29092", "--create", "--if-not-exists",
              "--topic", "transfer-events", "--partitions", "3", "--replication-factor", "1"]
```

Lengkapi daftar _volume_ di akhir `compose.yaml`:

```yaml
volumes:
  db-account:
  db-transfer:
  db-notification:
  kafka:
```

`kafka-init` ditempatkan di _profile_ `init` karena `docker compose up --wait` menunggu semua _container_ berstatus `healthy`, sedangkan `kafka-init` memang selesai lalu berhenti. Target `infra-up` di `Makefile` (folder `studi-kasus`) menjalankannya secara terpisah setelah Kafka berstatus `healthy`. Target `infra-down` dan `infra-reset` juga perlu `--profile init`, karena `docker compose down` melewati service dari _profile_ yang tidak aktif, dan sisa _container_ `kafka-init` akan menghalangi penghapusan jaringan Compose. Ubah ketiga target tersebut:

```make
# kafka-init creates the topic (idempotent: --if-not-exists).
infra-up:
	docker compose up -d --wait
	docker compose run --rm kafka-init

# --profile init: down skips services of inactive profiles, and a leftover
# kafka-init container would keep the network from being removed.
infra-down:
	docker compose --profile init down

# Removes the database and Kafka volumes too: all lab data is lost.
infra-reset:
	docker compose --profile init down -v
```

#note[*Penting.* Baris _recipe_ di `Makefile` harus diawali karakter _tab_, bukan spasi. Bila editor mengganti _tab_ menjadi spasi, `make` berhenti dengan pesan `missing separator`.]

Jalankan infrastruktur dan periksa bahwa _topic_ sudah dibuat:

#perintah[```bash
make infra-up
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:19092 --describe --topic transfer-events
```]

Pada `make infra-up` pertama, `kafka-init` mencetak `Created topic transfer-events.`. Pada pemanggilan berikutnya `kafka-init` tidak mencetak apa pun karena opsi `--if-not-exists`. Perintah `--describe` menampilkan `PartitionCount: 3` beserta tiga baris `Partition: 0`, `1`, dan `2`.

=== Mutasi _Idempotent_ di Account

_Idempotency key_ untuk mutasi sudah ada sejak Lab 2: setiap _debit_ dan _credit_ membawa `reference` berisi ID transfer. Yang belum ada adalah aturan bahwa kombinasi rekening, jenis mutasi, dan `reference` hanya boleh diterapkan sekali. Aturan tersebut paling kuat bila dijaga oleh database sendiri melalui _unique index_, karena dua _retry_ yang datang bersamaan pun tetap diperiksa oleh _index_ yang sama.

Tambahkan di akhir `account/internal/account/schema.sql`:

```sql
-- Idempotency (Lab 5): one mutation per account, type and reference. A retried
-- debit with the same reference (the transfer ID) hits this index instead of
-- moving the money twice. Created separately so it also lands on a database
-- created in Labs 1-4, unless that database already holds duplicate references:
-- then this statement fails and the service does not start. Lab 5 starts with
-- make infra-reset for that reason.
create unique index if not exists mutation_idempotency
    on mutation (account_number, type, reference);
```

Jenis mutasi ikut menjadi bagian _idempotency key_. Dengan demikian _debit_ dan _credit_ dengan `reference` yang sama tetap dianggap dua mutasi yang berbeda.

Selanjutnya `Store.Mutate` perlu memberi tahu pemanggilnya apakah mutasi benar-benar diterapkan atau hanya pengulangan. Ubah deklarasi `Mutate` di _interface_ `Store` (`account/internal/account/account.go`):

```go
	// Mutate debits or credits the account and records the mutation, atomically.
	// It returns the account with its new balance. When a mutation with the same
	// account, type and reference exists already, nothing changes: it returns
	// the current account and applied = false.
	Mutate(ctx context.Context, number string, t MutationType, req MutationRequest) (a Account, applied bool, err error)
```

Di Lab 2, `PostgresStore.Mutate` mengubah saldo terlebih dahulu, lalu mencatat baris `mutation`. Urutannya sekarang dibalik: baris `mutation` ditulis lebih dahulu dengan `on conflict do nothing` sebagai pemeriksaan _idempotency_. Bila tidak ada baris yang masuk, mutasi tersebut sudah pernah diterapkan, dan saldo tidak disentuh lagi. Urutan ini juga menangani _race condition_. Panggilan kedua dengan `reference` yang sama tertahan oleh _unique index_ sampai transaksi pertama selesai, lalu mendapati konflik. _Foreign key_ ke tabel `account` sekaligus memeriksa keberadaan rekening, sehingga pemanggilan `s.Get` untuk membedakan "rekening tidak ada" dari "saldo kurang" tidak diperlukan lagi.

Ganti seluruh fungsi `Mutate` di `account/internal/account/store.go`:

```go
func (s *PostgresStore) Mutate(ctx context.Context, number string, t MutationType, req MutationRequest) (Account, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Account{}, false, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

	// The mutation row goes in first, as the idempotency check. A concurrent call
	// with the same reference waits on the unique index until this transaction
	// ends and then sees the conflict, so two racing retries still apply once.
	tag, err := tx.Exec(ctx, `
		insert into mutation (account_number, type, amount, reference)
		values (@number, @type, @amount, @reference)
		on conflict (account_number, type, reference) do nothing`,
		pgx.NamedArgs{"number": number, "type": string(t), "amount": req.Amount, "reference": req.Reference})
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" { // foreign_key_violation: no such account
		return Account{}, false, ErrNotFound
	}
	if err != nil {
		return Account{}, false, err
	}
	if tag.RowsAffected() == 0 {
		// Applied before: this is a retry of a call whose answer got lost (timeout,
		// dropped connection). Answer with the current account, as if it were the
		// first call. A stricter API would also compare the amount and reject a
		// different amount under the same reference.
		//
		// Read inside the same transaction, not with s.Get: that would take a second
		// pool connection while this one is still held, and under load (pool
		// exhausted by concurrent retries) wait for itself.
		rows, err := tx.Query(ctx,
			`select number, owner_name, balance, created_at from account where number = @number`,
			pgx.NamedArgs{"number": number})
		if err != nil {
			return Account{}, false, err
		}
		a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
		if err != nil {
			return Account{}, false, err
		}
		return a, false, tx.Commit(ctx)
	}

	delta := req.Amount
	if t == Debit {
		delta = delta.Neg()
	}
	// The balance check sits in the WHERE clause, so two concurrent debits cannot
	// both pass it: the second one waits for the row lock and re-evaluates.
	rows, err := tx.Query(ctx, `
		update account set balance = balance + @delta
		where number = @number and balance + @delta >= 0
		returning number, owner_name, balance, created_at`,
		pgx.NamedArgs{"number": number, "delta": delta})
	if err != nil {
		return Account{}, false, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
	if errors.Is(err, pgx.ErrNoRows) {
		// The account exists (the foreign key accepted the mutation row), so the
		// balance is too low. Rollback removes the mutation row again: a later
		// retry with the same reference is evaluated afresh.
		return Account{}, false, ErrInsufficientFunds
	}
	if err != nil {
		return Account{}, false, err
	}
	return a, true, tx.Commit(ctx)
}
```

Query `update account` di tengah fungsi tidak berubah dari Lab 2. Yang hilang adalah `insert into mutation` di akhir fungsi (sudah pindah ke awal) serta pemanggilan `s.Get` di blok penanganan `pgx.ErrNoRows`.

Blok untuk panggilan ulang (`RowsAffected() == 0`) membaca saldo dengan `tx.Query` di transaksi yang sama, bukan dengan `s.Get`. `s.Get` meminjam koneksi kedua dari _pool_ selagi koneksi pertama masih dipegang transaksi. Bila banyak _retry_ datang bersamaan dan seluruh koneksi _pool_ sudah dipegang, setiap pemanggilan memegang satu koneksi sambil menunggu koneksi kedua yang tidak pernah dilepas, sehingga tidak ada yang selesai.

Di sisi gRPC, mutasi yang tidak diterapkan ulang tetap dijawab sukses. Pemanggil yang melakukan _retry_ karena jawaban pertama tidak sampai memang mengharapkan jawaban sukses, dan uangnya tetap hanya berpindah sekali. Ubah bagian akhir fungsi `mutate` di `account/internal/account/grpc.go`:

```go
	a, applied, err := s.store.Mutate(ctx, number, t, req)
	if err != nil {
		return Account{}, s.toStatus(err)
	}
	if !applied {
		// Not an error: the caller retried after losing our first answer. It gets
		// a success with the current balance, and the money moved only once.
		s.log.Info("mutation already applied, not repeated", "number", a.Number, "type", t, "reference", req.Reference)
		return a, nil
	}
	s.log.Info("account mutated", "number", a.Number, "type", t, "amount", req.Amount, "reference", req.Reference)
	return a, nil
```

Aturan ini termasuk bagian kontrak API, sehingga perlu dituliskan di `proto/account/v1/account.proto`. Ganti komentar _field_ `reference` di `DebitRequest` dan tambahkan komentar di `CreditRequest`:

```protobuf
message DebitRequest {
  string number = 1;
  string amount = 2;
  // reference ties the mutation to the business transaction, e.g. a transfer ID.
  // It is the idempotency key: a Debit or Credit repeated with the same number
  // and reference is not applied again and answers with the current account,
  // so callers may retry after a timeout.
  string reference = 3;
}

message CreditRequest {
  string number = 1;
  string amount = 2;
  // Same idempotency rule as DebitRequest.reference.
  string reference = 3;
}
```

Hanya komentar yang berubah, tetapi komentar tersebut ikut tersalin ke kode hasil _generate_. Jalankan ulang _generator_ agar `proto/gen` tetap sesuai dengan `.proto`:

#perintah[```bash
make proto
```]

_Test_ di `account` menggunakan `fakeStore` di `account/internal/account/http_test.go`. `fakeStore` harus mengikuti _signature_ `Mutate` yang baru dan meniru _unique index_ dengan _map_. _Field_ `mutateErr` dari Lab 4 tetap ada. Ubah _struct_, konstruktor, dan metode `Mutate`-nya:

```go
// fakeStore keeps accounts in memory so the HTTP layer is tested without PostgreSQL.
type fakeStore struct {
	accounts map[string]Account
	// applied holds "number type reference" of every mutation, like the unique
	// index on the mutation table.
	applied   map[string]bool
	pingErr   error
	mutateErr error // returned by Mutate when set, e.g. a context error
}

func newFakeStore() *fakeStore {
	return &fakeStore{accounts: map[string]Account{}, applied: map[string]bool{}}
}

func (f *fakeStore) Mutate(_ context.Context, number string, t MutationType, req MutationRequest) (Account, bool, error) {
	if f.mutateErr != nil {
		return Account{}, false, f.mutateErr
	}
	a, ok := f.accounts[number]
	if !ok {
		return Account{}, false, ErrNotFound
	}
	key := number + " " + string(t) + " " + req.Reference
	if f.applied[key] {
		return a, false, nil
	}
	if t == Debit {
		if a.Balance.LessThan(req.Amount) {
			return Account{}, false, ErrInsufficientFunds
		}
		a.Balance = a.Balance.Sub(req.Amount)
	} else {
		a.Balance = a.Balance.Add(req.Amount)
	}
	f.accounts[number] = a
	f.applied[key] = true
	return a, true, nil
}
```

Tambahkan _test_ berikut di akhir `account/internal/account/grpc_test.go`. _Test_ ini mengirim _debit_ yang sama dua kali, seperti _retry_ setelah _timeout_, dan memeriksa bahwa saldo hanya berkurang sekali:

```go
func TestGRPCMutationIsIdempotent(t *testing.T) {
	store := newFakeStore()
	store.accounts["1234567890"] = Account{Number: "1234567890", OwnerName: "Budi", Balance: decimal.RequireFromString("500000")}
	c := newGRPCClient(t, store)
	ctx := context.Background()

	// The same debit twice, e.g. a retry after a timeout: applied once, and both
	// calls answer with the balance after that one debit.
	for i := range 2 {
		got, err := c.Debit(ctx, &accountv1.DebitRequest{Number: "1234567890", Amount: "100000", Reference: "T-1"})
		if err != nil || got.GetAccount().GetBalance() != "400000.00" {
			t.Fatalf("call %d: Debit = %v, %v; want balance 400000.00", i+1, got, err)
		}
	}
	// Same reference, other type: a different mutation (a reversal uses its own
	// reference anyway, see the transfer saga).
	got, err := c.Credit(ctx, &accountv1.CreditRequest{Number: "1234567890", Amount: "100000", Reference: "T-1"})
	if err != nil || got.GetAccount().GetBalance() != "500000.00" {
		t.Fatalf("Credit = %v, %v; want balance 500000.00", got, err)
	}
}
```

#perintah[```bash
make -C account test
```]

=== _Retry_ untuk _Timeout_ di Client Transfer

Di Lab 3 dan Lab 4, fungsi `notProcessed` di `transfer/internal/accountclient/client.go` hanya mengizinkan _retry_ untuk `codes.Unavailable`. _Timeout_ sengaja tidak di-_retry_ karena _debit_ yang terlambat dijawab mungkin sudah diterapkan. Setelah mutasi menjadi _idempotent_, alasan tersebut tidak berlaku lagi: _retry_ dengan `reference` yang sama tidak menerapkan mutasi dua kali. Ganti fungsi `notProcessed` dengan `retryable`:

```go
// retryable reports whether the call may be retried:
//   - Unavailable: the server refused the call before running it (the fault
//     injector does exactly that) or no connection could be made.
//   - DeadlineExceeded and our own attempt timeout: the answer was late, and the
//     account service may have applied the mutation anyway. Retrying is safe
//     since Lab 5 because Debit and Credit are idempotent by reference (the
//     transfer ID): a repeated call is not applied twice. Before Lab 5 a
//     timed-out debit was never retried, because a retry could debit twice.
//
// Internal and Unknown are not retried: they come from a bug or a broken
// dependency on the server side, and the same request will most likely fail the
// same way. Business codes are final answers.
func retryable(_ any, err error) bool {
	if errors.Is(err, timeout.ErrExceeded) {
		return true
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded:
		return true
	}
	return false
}
```

Sesuaikan juga pemanggilnya di fungsi `New`, pada _builder_ `retrypolicy`:

```go
	retry := retrypolicy.NewBuilder[any]().
		HandleIf(retryable).
		// Explicit even though retryable already ignores ErrOpen: retrying against
		// an open breaker only burns backoff time and fails anyway.
		AbortOnErrors(circuitbreaker.ErrOpen).
```

Dua _test_ di `transfer/internal/accountclient/client_test.go` sekarang memeriksa perilaku yang sudah tidak berlaku. Ganti `TestNoRetryOnTimeout` dan `TestNoRetryOnDeadlineExceeded` dengan dua _test_ berikut. _Test_ pertama juga memeriksa bahwa _retry_ membawa `reference` yang sama:

```go
// A timed-out attempt is retried since Lab 5: the account service deduplicates
// by reference, so even a debit that was applied late is not applied twice.
func TestRetryOnTimeout(t *testing.T) {
	c, fake := newTestClient(t, func(ctx context.Context, n int64) error {
		if n == 1 {
			select {
			case <-time.After(300 * time.Millisecond):
			case <-ctx.Done():
			}
		}
		return nil
	})
	if err := debit(c); err != nil {
		t.Fatalf("err = %v, want success on the second attempt", err)
	}
	if got := fake.calls.Load(); got != 2 {
		t.Fatalf("calls = %d, want 2 (timeout, then OK)", got)
	}
	if req := fake.last.Load(); req.GetReference() != "ref" {
		t.Fatalf("retry reference = %q, want the same reference", req.GetReference())
	}
}

func TestRetryOnDeadlineExceeded(t *testing.T) {
	c, fake := newTestClient(t, always(codes.DeadlineExceeded))
	if err := debit(c); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("err = %v, want DeadlineExceeded", err)
	}
	if got := fake.calls.Load(); got != 4 {
		t.Fatalf("calls = %d, want 4 (1 attempt + 3 retries)", got)
	}
}
```

=== _Policy_ Tersendiri untuk _Reversal_

Langkah kompensasi _saga_ (bagian berikutnya) adalah _credit_ balik ke rekening asal, yang disebut _reversal_. _Reversal_ dijalankan tepat setelah _credit_ ke rekening tujuan gagal, dan penyebab kegagalan yang paling umum adalah `account` sedang mati atau _circuit breaker_ baru saja terbuka. Bila _reversal_ melewati _circuit breaker_ yang sama, _reversal_ langsung ditolak tanpa dikirim, dan transfer berakhir `COMPENSATION_FAILED` sehingga uang tertahan dan harus dikoreksi manual.

_Circuit breaker_ mencegah pemanggil menunggu service yang mati dan mencegah service menerima panggilan dalam jumlah besar sekaligus. Pada _reversal_, kedua manfaat tersebut kalah penting dibanding risiko koreksi manual. _Reversal_ jarang terjadi, sedangkan bila percobaannya dihentikan terlalu cepat, transfer harus dikoreksi manual. Karena itu _reversal_ mendapat _policy_ sendiri:

- tanpa _circuit breaker_;
- _retry_ untuk semua kegagalan infrastruktur (`Unavailable`, `DeadlineExceeded`, `Internal`, `Unknown`, _timeout_ per percobaan), dengan kriteria yang sama dengan `countsAsFailure`, sedangkan jawaban bisnis seperti `NotFound` tetap final;
- jumlah percobaan tidak dibatasi, tetapi durasinya dibatasi 30 detik, dengan _backoff_ 200 ms hingga 5 detik ditambah _jitter_. Batas 30 detik cukup untuk menunggu _restart_ `account` atau _pod_ yang dipindahkan Kubernetes.

Pengulangan aman karena setiap percobaan membawa `reference` yang sama, `<transfer_id>:reversal`, dan `account` hanya memproses setiap `reference` satu kali.

Lengkapi juga komentar _package_ di awal `transfer/internal/accountclient/client.go`:

```go
// Package accountclient calls the account service gRPC API through failsafe-go
// policies: per-attempt timeout, retry with backoff, and a circuit breaker,
// installed as a gRPC unary client interceptor. The saga's reversal credit goes
// through a second connection with its own policy (see Reverse).
package accountclient
```

_Interceptor_ gRPC melekat pada koneksi, sehingga _reversal_ membutuhkan koneksi gRPC kedua ke `account`. Di `transfer/internal/accountclient/client.go`, tambahkan tiga _field_ di akhir _struct_ `Settings`, tiga fungsi bantu untuk menghitung durasi terburuk (digunakan _test_ `transfer/main_test.go` di bagian berikutnya), lalu isi ketiga _field_ tersebut di akhir `ProductionSettings`:

```go
	// The reversal (saga compensation) keeps retrying for up to ReversalMaxDuration,
	// with backoff from ReversalBackoffMin to ReversalBackoffMax, and no breaker.
	ReversalMaxDuration time.Duration
	ReversalBackoffMin  time.Duration
	ReversalBackoffMax  time.Duration
}

// jitterFactor is the same for both policies: a delay varies by up to ±25%.
const jitterFactor = 0.25

// WorstCaseCall is the longest a Debit or Credit can take: every attempt runs
// into its timeout, with the longest backoff (plus jitter) between attempts.
func (s Settings) WorstCaseCall() time.Duration {
	attempts := time.Duration(s.MaxRetries + 1)
	backoff := time.Duration(float64(s.BackoffMax) * (1 + jitterFactor))
	return attempts*s.AttemptTimeout + time.Duration(s.MaxRetries)*backoff
}

// WorstCaseReversal is the longest a Reverse can take: the retry window, plus
// one last attempt that started just before the window closed.
func (s Settings) WorstCaseReversal() time.Duration {
	return s.ReversalMaxDuration + s.AttemptTimeout
}

// WorstCaseSaga is the longest the account calls of one transfer can take:
// debit, credit, and the reversal, each at its worst.
func (s Settings) WorstCaseSaga() time.Duration {
	return 2*s.WorstCaseCall() + s.WorstCaseReversal()
}
```

```go
	BreakerSuccesses: 3,
	// 30 s covers a restart of the account service (or a pod rescheduled in
	// Kubernetes), which is the usual reason for the forward credit to fail.
	ReversalMaxDuration: 30 * time.Second,
	ReversalBackoffMin:  200 * time.Millisecond,
	ReversalBackoffMax:  5 * time.Second,
}
```

Ganti juga `WithJitterFactor(0.25)` di _builder_ `retry` menjadi `WithJitterFactor(jitterFactor)`.

_Struct_ `Client` mendapat koneksi kedua:

```go
type Client struct {
	conn    *grpc.ClientConn
	api     accountv1.AccountServiceClient
	breaker circuitbreaker.CircuitBreaker[any]
	// reversalConn carries only Reverse, under the reversal policy.
	reversalConn *grpc.ClientConn
	reversalAPI  accountv1.AccountServiceClient
}
```

Di awal fungsi `New`, tolak durasi _reversal_ yang tidak positif. _Policy_ _reversal_ tidak membatasi jumlah percobaan, sehingga durasi nol berarti _retry_ selamanya:

```go
	// A zero duration here would mean "retry forever": the reversal policy has
	// no retry count limit.
	if s.ReversalMaxDuration <= 0 {
		return nil, errors.New("accountclient: Settings.ReversalMaxDuration must be positive")
	}
```

Lalu ganti bagian akhir `New`, mulai dari `opts = append(...)` hingga `return &Client{...}`, dengan _policy_ _reversal_, dua koneksi, dan fungsi bantu `dial`. Isi `dial` adalah opsi koneksi dari Lab 4 yang sebelumnya ditulis langsung di `New`:

```go
	// The reversal policy: retry without a breaker, for a longer but bounded window.
	//
	// A reversal runs right after the forward credit failed, and the usual reason
	// for that failure is the account service being down or the breaker being
	// open. Behind the same breaker, the reversal would be rejected instantly and
	// the transfer would end in COMPENSATION_FAILED: money stuck, a person needed.
	// The breaker exists to protect callers from waiting on a dead service and to
	// spare the service a flood of calls; neither weighs as much here. A reversal
	// is rare, and giving up on it costs a manual correction. So it waits for the
	// account service to come back, up to ReversalMaxDuration.
	//
	// Repeating is safe: every attempt carries the same reference
	// (<transfer_id>:reversal), and the account service applies a reference once.
	reversalRetry := retrypolicy.NewBuilder[any]().
		// Every infrastructure failure, Internal included: giving up early is the
		// expensive outcome here. Business codes (NotFound) are still final.
		HandleIf(countsAsFailure).
		WithMaxRetries(-1). // bounded by the duration, not the count
		WithMaxDuration(s.ReversalMaxDuration).
		WithBackoff(s.ReversalBackoffMin, s.ReversalBackoffMax).
		WithJitterFactor(jitterFactor).
		ReturnLastFailure().
		OnRetry(func(e failsafe.ExecutionEvent[any]) {
			log.Warn("retrying reversal", "next_attempt", e.Attempts(), "elapsed", e.ElapsedTime(), "cause", e.LastError())
		}).
		Build()
	reversalResilience := failsafegrpc.NewUnaryClientInterceptor[any](reversalRetry, timeout.New[any](s.AttemptTimeout))

	// An interceptor belongs to a connection, so the reversal gets a connection of
	// its own. The cost is one more TCP connection to the account service.
	conn, err := dial(target, resilience, opts)
	if err != nil {
		return nil, err
	}
	reversalConn, err := dial(target, reversalResilience, opts)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return &Client{
		conn: conn, api: accountv1.NewAccountServiceClient(conn), breaker: breaker,
		reversalConn: reversalConn, reversalAPI: accountv1.NewAccountServiceClient(reversalConn),
	}, nil
}

func dial(target string, interceptor grpc.UnaryClientInterceptor, extra []grpc.DialOption) (*grpc.ClientConn, error) {
	opts := append([]grpc.DialOption{
		// Plaintext: fine on a laptop, not in production. Service-to-service calls
		// there go over TLS (or mTLS through a service mesh); Lab 7 adds tokens.
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(interceptor),
		// After a failed connect, gRPC waits before reconnecting, growing up to
		// 120 s by default. Capped at 5 s so a restarted account service is used
		// again within seconds, which is what the breaker's half-open trials and
		// the reversal retries need.
		grpc.WithConnectParams(grpc.ConnectParams{
			Backoff:           backoff.Config{BaseDelay: time.Second, Multiplier: 1.6, Jitter: 0.2, MaxDelay: 5 * time.Second},
			MinConnectTimeout: 5 * time.Second,
		}),
	}, extra...)
	conn, err := grpc.NewClient(target, opts...)
	if err != nil {
		return nil, fmt.Errorf("account gRPC client for %s: %w", target, err)
	}
	return conn, nil
}
```

`Close` menutup kedua koneksi, dan metode baru `Reverse` mengirim _credit_ melalui koneksi _reversal_:

```go
func (c *Client) Close() error { return errors.Join(c.conn.Close(), c.reversalConn.Close()) }
```

```go
// Reverse credits the amount back to the source account as the saga's
// compensating step, under the reversal policy (see New): no breaker, retries
// for up to ReversalMaxDuration.
func (c *Client) Reverse(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	_, err := c.reversalAPI.Credit(ctx, &accountv1.CreditRequest{Number: number, Amount: amount.String(), Reference: reference})
	return mapError("reverse", number, err)
}
```

`testSettings` di `client_test.go` juga membutuhkan ketiga _field_ baru, karena `New` menolak `ReversalMaxDuration` nol. _File_ _test_ di _checkpoint_ sudah memuat kedua _test_ _retry_ di atas, `testSettings` yang lengkap, dan empat _test_ _reversal_:

- `TestReversalBypassesOpenBreaker`: _circuit breaker_ terbuka dan _credit_ biasa ditolak tanpa dikirim, sedangkan _reversal_ tetap dikirim, di-_retry_ selama `account` mati, berhasil setelah `account` kembali, dan selalu membawa `reference` `T-1:reversal`;
- `TestReversalGivesUpAfterMaxDuration`: _reversal_ berhenti setelah batas durasinya;
- `TestReversalBusinessRejectionIsFinal`: `NotFound` tidak di-_retry_;
- `TestNewRejectsMissingReversalWindow`: `New` menolak `ReversalMaxDuration` nol.

Ambil _file_ tersebut dari _checkpoint_:

#perintah[```bash
git checkout lab-05 -- transfer/internal/accountclient/client_test.go
```]

=== Status _Saga_ dan _Event_ Transfer

Model domain transfer mendapat tiga tambahan: status baru, jenis _event_, dan _struct_ `Event` untuk _payload_ _event_. `EventID` unik untuk setiap _event_, sehingga _consumer_ nantinya dapat mengenali _event_ yang dikirim ulang (Lab 6).

Di `transfer/internal/transfer/transfer.go`, ganti komentar _package_ serta blok `Status` dan konstantanya:

```go
// Package transfer moves money between two accounts by calling the account
// service. A transfer is a saga: a sequence of local steps, each with a
// compensating step that undoes it when a later step fails.
package transfer
```

```go
// Status is the saga state:
//
//	PENDING -> DEBITED -> COMPLETED   happy path
//	PENDING -> FAILED                 debit failed, nothing to undo
//	DEBITED -> COMPENSATED            credit failed, debit reversed
//	DEBITED -> COMPENSATION_FAILED    credit failed, reversal failed too
type Status string

const (
	Pending   Status = "PENDING"
	Debited   Status = "DEBITED"
	Completed Status = "COMPLETED"
	Failed    Status = "FAILED"
	// Compensated: the credit failed and the debit was reversed. No money moved.
	Compensated Status = "COMPENSATED"
	// CompensationFailed: the source account is debited and the reversal did not
	// go through. Needs a person (or a reconciliation job) to fix.
	CompensationFailed Status = "COMPENSATION_FAILED"
)

// EventType names the integration events other services consume. Only the end
// states that someone outside cares about have an event.
type EventType string

const (
	EventCompleted   EventType = "TransferCompleted"
	EventFailed      EventType = "TransferFailed"
	EventCompensated EventType = "TransferCompensated"
)

// Event is the payload published to Kafka. EventID is unique per event, so a
// consumer can recognise a redelivered one (Lab 6).
type Event struct {
	EventID     string          `json:"event_id"`
	TransferID  string          `json:"transfer_id"`
	FromAccount string          `json:"from_account"`
	ToAccount   string          `json:"to_account"`
	Amount      decimal.Decimal `json:"amount"`
	Status      Status          `json:"status"`
	Reason      string          `json:"reason,omitempty"`
	OccurredAt  time.Time       `json:"occurred_at"`
}
```

Tambahkan `ErrStaleState` ke blok `var` berisi _error_, tepat di bawah `ErrNotFound`:

```go
	// ErrStaleState: the transfer was not in the expected state, e.g. another
	// process moved it on already.
	ErrStaleState = errors.New("transfer is not in the expected state")
```

Di blok yang sama, ganti `ErrCreditFailed` dari Lab 3 dengan `ErrReversalFailed`. Sejak Lab 5, _credit_ yang gagal setelah _debit_ tidak lagi berarti uang tertahan, karena _debit_ dikembalikan. Uang baru tertahan bila pengembaliannya juga gagal:

```go
	// The credit failed and so did the reversal of the debit
	// (COMPENSATION_FAILED): the source account is short by the amount and needs
	// a manual correction. The transfer is not safe to retry.
	ErrReversalFailed = errors.New("debit reversal failed")
```

_Interface_ `AccountClient` mendapat metode ketiga, `Reverse`, yang diimplementasikan `accountclient.Client` di bagian sebelumnya:

```go
type AccountClient interface {
	Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error
	Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error
	// Reverse is a credit that undoes a debit (the saga's compensating step). It
	// runs under its own resiliency policy, not behind the breaker that Debit
	// and Credit share.
	Reverse(ctx context.Context, number string, amount decimal.Decimal, reference string) error
}
```

Metode `Finish` di _interface_ `Store` diganti `Transition`. Perbedaannya ada di dua hal: `Transition` hanya mengubah status bila transfer masih berada di status asal yang diharapkan, dan `Transition` menulis _event_ ke `outbox` dalam transaksi yang sama:

```go
	// Transition moves the transfer from one status to the next and, when event
	// is not empty, writes that event to the outbox in the same database
	// transaction: either both are stored or neither. It returns ErrStaleState
	// when the transfer is not in status from.
	Transition(ctx context.Context, id string, from, to Status, reason string, event EventType) (Transfer, error)
```

=== _Schema_ Transfer dan Tabel Outbox

Kolom `status` di Lab 2 berukuran `varchar(10)` dengan _check constraint_ untuk tiga status saja, sedangkan `COMPENSATION_FAILED` terdiri atas 19 karakter. Perubahan kolom dan _constraint_ ditulis sebagai `alter table` yang dijalankan ulang setiap kali service dimulai. Dengan cara ini database yang dibuat di Lab 2–4 ikut diperbarui. Ganti isi `transfer/internal/transfer/schema.sql`:

```sql
create table if not exists transfer (
    id             uuid           primary key default gen_random_uuid(),
    from_account   varchar(10)    not null,
    to_account     varchar(10)    not null,
    amount         numeric(19, 2) not null check (amount > 0),
    status         varchar(20)    not null,
    failure_reason text,
    created_at     timestamptz    not null default now(),
    updated_at     timestamptz    not null default now()
);

-- Saga states (Lab 5). Re-applied on every start so a database created in
-- Labs 2-4, with only PENDING/COMPLETED/FAILED, gets the new states as well.
alter table transfer alter column status type varchar(20);
alter table transfer drop constraint if exists transfer_status_check;
alter table transfer add constraint transfer_status_check check (status in
    ('PENDING', 'DEBITED', 'COMPLETED', 'FAILED', 'COMPENSATED', 'COMPENSATION_FAILED'));

-- Transactional outbox (Lab 5). An event is inserted in the same transaction as
-- the state change it reports; the relay publishes it to Kafka afterwards and
-- sets published_at. Writing to the database and to Kafka directly would be two
-- systems without a shared transaction: a crash between them loses the event
-- or publishes one for a change that was rolled back.
create table if not exists outbox (
    id           uuid        primary key,
    aggregate_id uuid        not null,
    event_type   varchar(50) not null,
    payload      jsonb       not null,
    created_at   timestamptz not null default now(),
    published_at timestamptz
);

-- The relay only ever looks for unpublished rows; a partial index stays small
-- however many published rows pile up.
create index if not exists outbox_unpublished on outbox (created_at) where published_at is null;
```

Kolom `aggregate_id` berisi ID transfer. Istilah _aggregate_ menunjuk entitas yang perubahannya dilaporkan oleh _event_ tersebut. Kolom `published_at` yang masih kosong menandakan _event_ belum terkirim ke Kafka.

=== _Package_ Outbox dan _Relay_

_Package_ baru `outbox` memiliki dua tanggung jawab. Fungsi `Insert` menulis satu baris `outbox` di dalam transaksi milik pemanggil. `Relay` berjalan sebagai _goroutine_: setiap 500 ms _relay_ mengambil hingga 100 baris yang belum terkirim, mengirimnya ke Kafka, lalu mengisi `published_at`.

Tiga keputusan desain di _relay_ perlu dipahami sebelum menulis kodenya:

- *Penguncian baris.* Query `for update skip locked` mengunci baris yang sedang dikirim. Bila beberapa _instance_ `transfer` berjalan, setiap _relay_ melewati baris yang sudah dikunci _relay_ lain, sehingga satu baris tidak dikirim dua kali oleh dua _relay_ dan _relay_ tidak saling menunggu.
- *Urutan kirim lalu tandai.* Kafka mengonfirmasi penerimaan terlebih dahulu, baru kemudian `published_at` diisi dan transaksi di-_commit_. Bila proses berhenti di antara kedua langkah tersebut, baris tetap berstatus belum terkirim dan dikirim lagi pada siklus berikutnya. Cara ini menghasilkan jaminan _at-least-once_: _event_ tidak pernah hilang, tetapi sesekali terkirim dua kali. Urutan sebaliknya (tandai dulu, kirim kemudian) justru dapat menghilangkan _event_.
- *Konfigurasi _producer_.* _Key_ Kafka berisi ID transfer dan `kafka.Hash` memilih _partition_ berdasarkan _key_ tersebut, sehingga semua _event_ satu transfer tetap berurutan. `RequireAll` menunggu konfirmasi dari semua replika yang sinkron. Pembuatan _topic_ otomatis dimatikan juga di sisi _client_.

Tambahkan _dependency_ Kafka dan UUID ke modul `transfer`:

#perintah[```bash
cd transfer
go get github.com/segmentio/kafka-go@v0.4.51 github.com/google/uuid@v1.6.0
cd ..
```]

Buat _file_ `transfer/internal/outbox/outbox.go`:

```go
// Package outbox implements the transactional outbox: events are stored in the
// service's own database, in the same transaction as the state change they
// report, and a relay publishes them to Kafka afterwards.
package outbox

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/segmentio/kafka-go"
)

// Message is one outbox row. The table itself is created by the transfer schema.
type Message struct {
	ID          string // event ID, also sent as Kafka header event_id
	AggregateID string // transfer ID, used as the Kafka key
	EventType   string
	Payload     []byte // JSON
}

// Insert writes m inside tx. tx must be the transaction that also writes the
// state change, otherwise the outbox gives no guarantee at all.
func Insert(ctx context.Context, tx pgx.Tx, m Message) error {
	_, err := tx.Exec(ctx, `
		insert into outbox (id, aggregate_id, event_type, payload)
		values (@id, @aggregate_id, @event_type, @payload)`,
		pgx.NamedArgs{"id": m.ID, "aggregate_id": m.AggregateID, "event_type": m.EventType, "payload": m.Payload})
	if err != nil {
		return fmt.Errorf("insert outbox message: %w", err)
	}
	return nil
}

// Publisher is the part of kafka.Writer the relay uses; tests can fake it.
type Publisher interface {
	WriteMessages(ctx context.Context, msgs ...kafka.Message) error
}

// NewKafkaWriter builds the producer for the relay.
func NewKafkaWriter(brokers []string, topic string) *kafka.Writer {
	return &kafka.Writer{
		Addr:  kafka.TCP(brokers...),
		Topic: topic,
		// Same key, same partition: all events of one transfer stay in order.
		Balancer: &kafka.Hash{},
		// Acknowledged by every in-sync replica before WriteMessages returns; only
		// then may the relay mark the rows published.
		RequiredAcks: kafka.RequireAll,
		// The topic is created on purpose, with its partition count (compose
		// kafka-init). A typo in KAFKA_TOPIC must fail, not create a new topic.
		AllowAutoTopicCreation: false,
		// The relay hands over a whole batch in one call; do not wait the default
		// 1 s for more messages that will not come.
		BatchTimeout: 10 * time.Millisecond,
		BatchSize:    BatchSize,
	}
}

const (
	// PollInterval is how long an event waits at most before the relay looks.
	PollInterval = 500 * time.Millisecond
	// BatchSize caps the rows claimed per poll.
	BatchSize = 100
)

type Relay struct {
	pool *pgxpool.Pool
	pub  Publisher
	log  *slog.Logger
}

func NewRelay(pool *pgxpool.Pool, pub Publisher, log *slog.Logger) *Relay {
	return &Relay{pool: pool, pub: pub, log: log}
}

// Run polls the outbox until ctx is cancelled. A failed batch (Kafka down,
// database down) is logged and tried again on the next tick: the rows stay
// unpublished, nothing is lost.
func (r *Relay) Run(ctx context.Context) {
	r.log.Info("outbox relay started", "interval", PollInterval.String())
	ticker := time.NewTicker(PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			r.log.Info("outbox relay stopped")
			return
		case <-ticker.C:
		}
		n, err := r.publishBatch(ctx)
		if err != nil {
			if ctx.Err() == nil {
				r.log.Warn("outbox publish failed, will retry", "error", err)
			}
			continue
		}
		if n > 0 {
			r.log.Info("outbox events published", "count", n)
		}
	}
}

// publishBatch claims up to BatchSize unpublished rows, publishes them, and marks
// them published, all while holding the row locks of one transaction.
//
// "for update skip locked" lets several transfer instances run a relay each:
// rows locked by one relay are skipped by the others instead of being published
// twice or blocking them.
//
// Delivery is at-least-once. Kafka has acknowledged the batch before the update
// commits; when the commit fails or the process dies in between, the rows are
// still unpublished and go out again on the next poll. Consumers therefore see
// duplicates now and then and must be idempotent (Lab 6). The opposite order,
// commit first and publish after, would lose events instead: worse.
func (r *Relay) publishBatch(ctx context.Context) (int, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

	rows, err := tx.Query(ctx, `
		select id::text, aggregate_id::text, event_type, payload
		from outbox
		where published_at is null
		order by created_at
		limit @limit
		for update skip locked`,
		pgx.NamedArgs{"limit": BatchSize})
	if err != nil {
		return 0, err
	}
	pending, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Message])
	if err != nil {
		return 0, err
	}
	if len(pending) == 0 {
		return 0, nil
	}

	msgs := make([]kafka.Message, len(pending))
	ids := make([]string, len(pending))
	for i, m := range pending {
		msgs[i] = kafka.Message{
			Key:   []byte(m.AggregateID),
			Value: m.Payload,
			Headers: []kafka.Header{
				{Key: "event_type", Value: []byte(m.EventType)},
				{Key: "event_id", Value: []byte(m.ID)},
			},
		}
		ids[i] = m.ID
	}
	// Bounded, so a hanging broker does not hold the row locks forever.
	pubCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := r.pub.WriteMessages(pubCtx, msgs...); err != nil {
		return 0, fmt.Errorf("publish %d events: %w", len(msgs), err)
	}

	// The duplicate window described above starts here.
	if _, err := tx.Exec(ctx, `update outbox set published_at = now() where id = any(@ids::uuid[])`,
		pgx.NamedArgs{"ids": ids}); err != nil {
		return 0, fmt.Errorf("mark %d events published: %w", len(ids), err)
	}
	return len(pending), tx.Commit(ctx)
}
```

=== Perubahan Status dan _Event_ dalam Satu Transaksi

`PostgresStore.Transition` menjalankan dua perintah dalam satu transaksi: `update transfer` dan, bila ada _event_, `outbox.Insert`. Klausa `and status = @from` menjaga _state machine_. Transfer yang sudah dipindahkan ke status lain oleh proses lain tidak akan tertimpa, dan `Transition` mengembalikan `ErrStaleState`.

Fungsi bantu `one` yang semula metode `PostgresStore` diubah menjadi fungsi biasa yang menerima _interface_ `querier`. _Interface_ tersebut dipenuhi oleh _pool_ maupun transaksi, sehingga query yang sama dapat dijalankan di keduanya.

Di `transfer/internal/transfer/store.go`, tambahkan _import_ berikut:

```go
	"encoding/json"

	"github.com/google/uuid"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/outbox"
```

Tambahkan metode `Pool` tepat di bawah `Close`. _Relay_ membaca tabel `outbox` dari database yang sama, sehingga cukup menggunakan _pool_ milik `PostgresStore`:

```go
// Pool is shared with the outbox relay, which reads the outbox table of this
// same database.
func (s *PostgresStore) Pool() *pgxpool.Pool { return s.pool }
```

Ganti metode `Finish` dengan `Transition`:

```go
func (s *PostgresStore) Transition(ctx context.Context, id string, from, to Status, reason string, event EventType) (Transfer, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Transfer{}, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

	// "and status = @from" guards the state machine: a transfer that some other
	// process moved on already is not overwritten.
	t, err := one(ctx, tx, `
		update transfer set status = @to, failure_reason = nullif(@reason, ''), updated_at = now()
		where id = @id and status = @from
		returning `+columns,
		pgx.NamedArgs{"id": id, "from": string(from), "to": string(to), "reason": reason})
	if errors.Is(err, ErrNotFound) {
		return Transfer{}, fmt.Errorf("%s -> %s: %w", from, to, ErrStaleState)
	}
	if err != nil {
		return Transfer{}, err
	}

	if event != "" {
		e := Event{
			EventID:     uuid.NewString(),
			TransferID:  t.ID,
			FromAccount: t.FromAccount,
			ToAccount:   t.ToAccount,
			Amount:      t.Amount,
			Status:      t.Status,
			Reason:      t.FailureReason,
			OccurredAt:  t.UpdatedAt,
		}
		payload, err := json.Marshal(e)
		if err != nil {
			return Transfer{}, err
		}
		if err := outbox.Insert(ctx, tx, outbox.Message{
			ID: e.EventID, AggregateID: t.ID, EventType: string(event), Payload: payload,
		}); err != nil {
			return Transfer{}, err
		}
	}
	return t, tx.Commit(ctx)
}
```

Terakhir, ubah `Create`, `Get`, dan fungsi bantu `one`. Isi `switch` di dalam `one` yang menerjemahkan `pgx.ErrNoRows` dan kode `22P02` menjadi `ErrNotFound` tidak berubah:

```go
func (s *PostgresStore) Create(ctx context.Context, req CreateRequest) (Transfer, error) {
	return one(ctx, s.pool, `
		insert into transfer (from_account, to_account, amount, status)
		values (@from, @to, @amount, 'PENDING')
		returning `+columns,
		pgx.NamedArgs{"from": req.FromAccount, "to": req.ToAccount, "amount": req.Amount})
}

func (s *PostgresStore) Get(ctx context.Context, id string) (Transfer, error) {
	return one(ctx, s.pool, `select `+columns+` from transfer where id = @id`, pgx.NamedArgs{"id": id})
}

// querier is what the pool and a transaction have in common.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func one(ctx context.Context, q querier, sql string, args pgx.NamedArgs) (Transfer, error) {
	rows, err := q.Query(ctx, sql, args)
	// ... the rest of the former s.one is unchanged ...
}
```

=== _Saga Orchestrator_ di Service Transfer

Seluruh alur _saga_ berada di satu tempat, yaitu `Service.Execute`. Pendekatan ini disebut _orchestration_: satu service mengatur urutan langkah dan kompensasinya. Pada pendekatan lainnya, _choreography_, setiap service bereaksi terhadap _event_ dari service lain tanpa pengatur pusat.

Kompensasi berupa _credit_ ke rekening asal melalui `AccountClient.Reverse`, dengan `reference` tersendiri, yaitu ID transfer ditambah akhiran `:reversal`. Akhiran tersebut diperlukan karena aturan _idempotency_ di `account`. Tanpa akhiran, _reversal_ akan dianggap pengulangan _credit_ lain dengan ID yang sama. Sebaliknya, _reversal_ yang di-_retry_ tetap menggunakan `reference` yang sama, sehingga _reversal_ pun hanya diterapkan sekali.

Bila _reversal_ tetap gagal setelah 30 detik _retry_, transfer berakhir di `COMPENSATION_FAILED` tanpa _event_, karena hasil akhirnya bagi nasabah belum pasti. Kondisi ini dicatat sebagai log `ERROR` untuk ditangani manual, dan _error_ yang dikembalikan membungkus `ErrReversalFailed`.

Ganti seluruh isi `transfer/internal/transfer/service.go` mulai dari deklarasi `Service` hingga sebelum metode `Get`. Metode `Get` dan bagian sesudahnya tidak berubah:

```go
// ReversalSuffix marks the compensating credit. The reversal needs its own
// reference: under the transfer ID alone, the account service would treat it
// as a repeat of a credit with that ID (see the idempotency rule in
// account.proto). A retried reversal reuses this reference and is therefore
// applied once as well.
const ReversalSuffix = ":reversal"

type Service struct {
	store    Store
	accounts AccountClient
	log      *slog.Logger
}

func NewService(store Store, accounts AccountClient, log *slog.Logger) *Service {
	return &Service{store: store, accounts: accounts, log: log}
}

// Execute runs the transfer saga, orchestrated from here:
//
//  1. record the transfer                -> PENDING
//  2. debit the source                   -> DEBITED   (failed: FAILED)
//  3. credit the destination             -> COMPLETED (failed: step 4)
//  4. compensate: credit the source back -> COMPENSATED
//
// There is no transaction across the two account calls; every step is a local
// transaction in one service, and a failed step is undone by a compensating
// step instead of a rollback. Each end state and its event are stored together
// (Store.Transition), and the outbox relay publishes the event afterwards.
//
// The returned error is the reason the transfer did not complete; the transfer
// itself is returned whenever it was recorded.
func (s *Service) Execute(ctx context.Context, req CreateRequest) (Transfer, error) {
	t, err := s.store.Create(ctx, req)
	if err != nil {
		return Transfer{}, fmt.Errorf("record transfer: %w", err)
	}

	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
		// Known gap: when every attempt timed out, the debit may still have been
		// applied, and FAILED is then wrong. Compensating blindly is no answer
		// either: a reversal of a debit that never happened creates money. The
		// production answer is a reconciliation job that repeats the debit with
		// the same reference (idempotent) until it gets a definite answer, then
		// continues or reverses. Here it stays FAILED and is logged.
		return s.finish(ctx, t, Pending, Failed, fmt.Sprintf("debit failed: %v", err), EventFailed, err)
	}

	debited, err := s.store.Transition(ctx, t.ID, Pending, Debited, "", "")
	if err != nil {
		// The money left the source but our own database did not record it. The
		// transfer stays PENDING; the reconciliation above would find it.
		s.log.Error("debit applied but not recorded", "transfer_id", t.ID, "error", err)
		return t, fmt.Errorf("mark transfer debited: %w", err)
	}

	if err := s.accounts.Credit(ctx, debited.ToAccount, debited.Amount, debited.ID); err != nil {
		return s.compensate(ctx, debited, err)
	}

	return s.finish(ctx, debited, Debited, Completed, "", EventCompleted, nil)
}

// compensate undoes the debit by crediting the amount back to the source.
//
// The reversal goes through AccountClient.Reverse, not Credit: the forward credit
// has often just failed because the account service is down, which may well have
// opened the shared breaker. Reverse has no breaker and keeps retrying for a
// while (see accountclient), so a short outage ends in COMPENSATED instead of
// COMPENSATION_FAILED.
//
// Same ambiguity as the debit: a credit that timed out on every attempt may have
// arrived, and the reversal then gives the money back twice over (destination
// and source). Business rejections (destination not found) and an open breaker
// are certain not to have been applied; the reconciliation job resolves the rest.
func (s *Service) compensate(ctx context.Context, t Transfer, cause error) (Transfer, error) {
	reason := fmt.Sprintf("credit failed: %v", cause)
	s.log.Warn("credit failed after debit, reversing the debit", "transfer_id", t.ID, "error", cause)

	if err := s.accounts.Reverse(ctx, t.FromAccount, t.Amount, t.ID+ReversalSuffix); err != nil {
		// The source account is short by the amount. The reversal is idempotent, so
		// repeating it later is safe; production runs that from a background job.
		// Here a person repeats it. No event: the customer outcome is not final yet.
		s.log.Error("compensation failed, source account needs manual reversal",
			"transfer_id", t.ID, "from_account", t.FromAccount, "amount", t.Amount, "error", err)
		reason = fmt.Sprintf("%s; reversal failed: %v", reason, err)
		return s.finish(ctx, t, Debited, CompensationFailed, reason, "", fmt.Errorf("%w: %w", ErrReversalFailed, errors.Join(cause, err)))
	}
	return s.finish(ctx, t, Debited, Compensated, reason, EventCompensated, cause)
}

// finish stores the end state with its event. cause is the saga's outcome error
// (nil on success) and is returned as is, so the HTTP layer can map it.
func (s *Service) finish(ctx context.Context, t Transfer, from, to Status, reason string, event EventType, cause error) (Transfer, error) {
	done, err := s.store.Transition(ctx, t.ID, from, to, reason, event)
	if err != nil {
		s.log.Error("saga end state not recorded", "transfer_id", t.ID, "status", to, "error", err)
		return t, errors.Join(cause, fmt.Errorf("mark transfer %s: %w", to, err))
	}
	switch to {
	case Completed:
		s.log.Info("transfer completed", "transfer_id", t.ID, "amount", t.Amount)
	case CompensationFailed:
		// logged in compensate
	default:
		s.log.Warn("transfer not completed", "transfer_id", t.ID, "status", to, "reason", reason)
	}
	return done, cause
}
```

Komentar di `Execute` dan `compensate` menyebut celah yang sengaja dibiarkan. Bila semua percobaan _debit_ atau _credit_ berakhir _timeout_, hasilnya di `account` tidak pasti. Lab ini tetap menandai `FAILED` atau menjalankan kompensasi. Sistem _production_ menjalankan _reconciliation job_ yang mengulang mutasi dengan `reference` yang sama hingga jawabannya pasti, dan pengulangan tersebut aman karena mutasi sudah _idempotent_.

=== Kode Status HTTP untuk Hasil _Saga_

Di Lab 3 dan Lab 4, setiap kegagalan _credit_ setelah _debit_ dijawab `502` (`ErrCreditFailed`), karena uang sudah keluar dan _request_ tidak boleh diulang. Dengan kompensasi, _credit_ yang gagal berakhir `COMPENSATED`. _Debit_ sudah dikembalikan sehingga tidak ada uang yang berpindah, dan kode HTTP-nya mengikuti penyebab kegagalan _credit_, sama seperti kegagalan _debit_. Uang hanya tertahan pada `COMPENSATION_FAILED`.

#table(
  columns: (auto, 1fr),
  [Kode], [Kondisi],
  [`201`], [`COMPLETED`],
  [`422`], [Rekening tidak ada atau saldo kurang (`FAILED`), termasuk `COMPENSATED` karena rekening tujuan tidak ada],
  [`503`], [_Circuit breaker_ terbuka saat _debit_ (`FAILED`), atau saat _credit_ lalu _debit_ dikembalikan (`COMPENSATED`). Tidak ada uang yang berpindah, sehingga _request_ aman diulang],
  [`502`], [_Dependency_ gagal karena sebab lain (`FAILED` atau `COMPENSATED`)],
  [`500`], [`COMPENSATION_FAILED`: _debit_ sudah terjadi dan pengembaliannya gagal],
)

`COMPENSATION_FAILED` berarti uang tertahan karena kegagalan di sisi sistem sendiri, apa pun jawaban `account` sebelumnya. Kondisi tersebut dijawab `500` dan tidak boleh tampak sebagai `503` atau `422`, karena kedua kode tersebut membuat pemanggil mengulang _request_. Karena itu pemeriksaan `ErrReversalFailed` berada sebelum pemetaan _error_ lain. Pemeriksaan ini menggunakan _error_, bukan `t.Status`, agar tetap berlaku ketika status `COMPENSATION_FAILED` sendiri gagal disimpan. Di `transfer/internal/transfer/http.go`, ubah `switch` di fungsi `create`: hapus kasus `ErrCreditFailed` dan sesuaikan komentarnya.

```go
	switch {
	case err == nil:
		w.Header().Set("Location", "/transfers/"+t.ID)
		writeJSON(w, http.StatusCreated, t)
	case t.ID == "":
		h.internalError(w, r, err)
	case errors.Is(err, ErrReversalFailed):
		// Checked first: the source account is debited and the reversal did not go
		// through (COMPENSATION_FAILED, also when that state itself could not be
		// stored). Money is stuck on our side, whatever the account service
		// answered: this is our failure, not the caller's, and never a 503 or 422
		// that would invite a retry.
		writeJSON(w, http.StatusInternalServerError, t)
	case errors.Is(err, ErrAccountNotFound), errors.Is(err, ErrInsufficientFunds):
		// Includes COMPENSATED when the destination account does not exist.
		writeJSON(w, http.StatusUnprocessableEntity, t)
	case errors.Is(err, ErrAccountUnavailable):
		// The open breaker refused the debit (FAILED), or refused the credit and the
		// debit was reversed (COMPENSATED). Either way no money moved: 503 tells the
		// caller it is safe to come back later.
		writeJSON(w, http.StatusServiceUnavailable, t)
	default:
		// Recorded but not completed because a dependency failed (FAILED or
		// COMPENSATED).
		writeJSON(w, http.StatusBadGateway, t)
	}
```

_Test_ `TestCreateStatus` di `transfer/internal/transfer/http_test.go` dari Lab 3 ikut berubah. Kasus "_breaker_ terbuka di antara _debit_ dan _credit_" sekarang mengharapkan `503`, kasus "rekening tujuan tidak ada" mengharapkan `422`, dan kasus baru "_reversal_ juga gagal" mengharapkan `500`. _File_-nya diambil dari _checkpoint_ di bagian _test_ _saga_.

=== Konfigurasi dan _Relay_ di `main.go` Transfer

`transfer` membutuhkan dua variabel baru, `KAFKA_BROKERS` dan `KAFKA_TOPIC`. Seperti variabel lain, keduanya wajib diisi, dan service berhenti saat _startup_ bila salah satunya kosong. Di `transfer/config.go`, tambahkan dua _field_ di _struct_ `Config`:

```go
	// KafkaBrokers is a comma-separated list of host:port.
	KafkaBrokers []string
	KafkaTopic   string
```

lalu isi keduanya di `LoadConfig`, di bawah `AccountGRPCAddr`:

```go
		KafkaBrokers:    strings.Split(get("KAFKA_BROKERS"), ","),
		KafkaTopic:      get("KAFKA_TOPIC"),
```

Tambahkan kedua variabel ke target `run` di `transfer/Makefile`:

```make
run:
	HTTP_ADDR=:28082 \
	DATABASE_URL=postgres://transfer:transfer123@localhost:15433/transfer \
	ACCOUNT_GRPC_ADDR=localhost:29091 \
	KAFKA_BROKERS=localhost:19092 \
	KAFKA_TOPIC=transfer-events \
	go run .
```

_Relay_ dijalankan sebagai _goroutine_ di `transfer/main.go`. _Writer_ Kafka tidak membuka koneksi sebelum pengiriman pertama, sehingga `transfer` tetap bisa dimulai dan menerima transfer selama Kafka mati. Urutan _shutdown_ juga penting: _relay_ harus berhenti sebelum _pool_ database ditutup oleh `defer store.Close()`. `defer` dijalankan dalam urutan terbalik, sehingga fungsi untuk menghentikan _relay_ yang didaftarkan belakangan akan berjalan lebih dahulu.

Tambahkan _import_ `.../transfer/internal/outbox`, lalu sisipkan blok berikut di fungsi `run`, tepat setelah `srv := &http.Server{...}` dan sebelum `errCh := make(chan error, 1)`:

```go
	// The relay connects lazily too: the service starts and accepts transfers
	// while Kafka is down; events wait in the outbox until it is back.
	writer := outbox.NewKafkaWriter(cfg.KafkaBrokers, cfg.KafkaTopic)
	defer writer.Close()
	relayCtx, stopRelay := context.WithCancel(context.Background())
	relayDone := make(chan struct{})
	go func() {
		outbox.NewRelay(store.Pool(), writer, log).Run(relayCtx)
		close(relayDone)
	}()
	// Runs before the deferred store.Close: the relay must stop using the pool first.
	defer func() {
		stopRelay()
		<-relayDone
	}()
```

Lengkapi log _startup_ dengan konfigurasi Kafka:

```go
		log.Info("transfer service listening", "addr", cfg.HTTPAddr, "account_grpc", cfg.AccountGRPCAddr,
			"kafka_brokers", cfg.KafkaBrokers, "kafka_topic", cfg.KafkaTopic)
```

Saat menerima SIGTERM, server HTTP menunggu transfer yang sedang berjalan. Di Lab 4 batasnya 10 detik, padahal durasi _saga_ kini bisa jauh lebih panjang: _debit_ dan _credit_ masing-masing hingga 11,75 detik (4 percobaan × 2 detik ditambah 3 _backoff_ × 1,25 detik), lalu _reversal_ hingga 32 detik (durasi _retry_ 30 detik ditambah satu percobaan terakhir 2 detik). Bila _saga_ terhenti di tengah jalan, barisnya tertinggal di status `PENDING` atau `DEBITED` dan tidak ada proses yang melanjutkannya. Tambahkan konstanta berikut di `transfer/main.go`, di atas fungsi `main`:

```go
// shutdownGrace is how long the HTTP server waits on SIGTERM for transfers in
// flight. A saga cut mid-way leaves a PENDING or DEBITED row that nothing
// resumes (see README), so the wait covers the worst case of one saga under
// accountclient.ProductionSettings:
//
//	debit    4 attempts x 2 s + 3 backoffs x 1.25 s  = 11.75 s
//	credit   same                                    = 11.75 s
//	reversal 30 s retry window + one last 2 s attempt = 32 s
//	                                                    55.5 s
//
// plus a few seconds for the database writes in between. TestShutdownGrace
// fails when the policies grow past it. The platform must give the process at
// least this long before SIGKILL (Kubernetes: terminationGracePeriodSeconds).
const shutdownGrace = 60 * time.Second
```

Di cabang `case <-ctx.Done():`, ganti `10*time.Second` dengan `shutdownGrace`, lalu tambahkan komentar berikut tepat sebelum `srv.Shutdown`. Komentar ini menjelaskan mengapa urutan _shutdown_ sudah benar tanpa kode tambahan:

```go
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()
		// HTTP first: transfers in flight finish and write their outbox rows; the
		// deferred relay stop comes after, and anything left is published by the
		// next start.
```

Angka 60 detik harus tetap mengikuti _policy_ di `accountclient`. Buat `transfer/main_test.go` yang gagal bila durasi terburuk _saga_ melewati `shutdownGrace`:

```go
package main

import (
	"testing"
	"time"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/accountclient"
)

// TestShutdownGrace keeps shutdownGrace in step with the resiliency policies: a
// longer retry or reversal window must come with a longer shutdown wait.
func TestShutdownGrace(t *testing.T) {
	const dbMargin = 3 * time.Second
	if need := accountclient.ProductionSettings.WorstCaseSaga() + dbMargin; shutdownGrace < need {
		t.Fatalf("shutdownGrace = %s, want at least %s (worst-case saga + %s)", shutdownGrace, need, dbMargin)
	}
}
```

Masih ada satu celah. Bila proses dimatikan paksa (SIGKILL atau _crash_) di antara dua langkah, baris `PENDING` atau `DEBITED` tertinggal tanpa ada yang melanjutkannya. Sistem _production_ menambahkan _recovery job_ yang melanjutkan atau mengompensasi baris seperti itu. Di Lab 9, `terminationGracePeriodSeconds` untuk `transfer` disesuaikan dengan angka ini.

=== _Test_ untuk _Saga_

`fakeStore` di `transfer/internal/transfer/service_test.go` harus mengganti `Finish` dengan `Transition` dan mencatat _event_ yang ditulis, sehingga _test_ dapat memeriksa urutan panggilan ke `account` sekaligus _event_ yang masuk ke _outbox_. Bagian utamanya:

```go
// fakeStore keeps transfers in memory and records the outbox events written
// with each transition.
type fakeStore struct {
	transfers map[string]Transfer
	events    []EventType
	seq       int
}

func (f *fakeStore) Transition(_ context.Context, id string, from, to Status, reason string, event EventType) (Transfer, error) {
	t := f.transfers[id]
	if t.Status != from {
		return Transfer{}, ErrStaleState
	}
	t.Status, t.FailureReason = to, reason
	f.transfers[id] = t
	if event != "" {
		f.events = append(f.events, event)
	}
	return t, nil
}
```

`fakeAccounts` juga berubah. _Fake_ ini kini mengenali setiap panggilan dari deskripsinya (`debit 1111111111`, `credit 2222222222`, `reverse 1111111111`), mengambil _error_ dari _map_, dan mencatat setiap panggilan beserta `reference`-nya. Dengan begitu _test_ dapat memeriksa bahwa pengembalian menggunakan `Reverse` dengan akhiran `:reversal`:

```go
// fakeAccounts answers each call by its description ("debit 1111111111",
// "credit 2222222222", "reverse 1111111111") and records the calls with their
// references.
type fakeAccounts struct {
	errs  map[string]error
	calls []string
}

func (f *fakeAccounts) Reverse(_ context.Context, number string, _ decimal.Decimal, ref string) error {
	return f.call("reverse "+number, ref)
}

func (f *fakeAccounts) call(desc, ref string) error {
	f.calls = append(f.calls, desc+" ref="+ref)
	return f.errs[desc]
}
```

_Table-driven test_ `TestExecuteSaga` memeriksa enam skenario: sukses, saldo kurang, _circuit breaker_ terbuka saat _debit_, _credit_ gagal lalu dikembalikan, _circuit breaker_ terbuka di antara _debit_ dan _credit_ (tetap dikembalikan karena `Reverse` tidak melewati _breaker_), dan pengembalian yang juga gagal. Sebagai contoh, skenario kompensasi mengharapkan tiga panggilan ke `account` dan satu _event_:

```go
		{"credit fails after debit: debit reversed",
			map[string]error{"credit 2222222222": ErrAccountNotFound}, Compensated, ErrAccountNotFound,
			[]string{"debit 1111111111 ref=1", "credit 2222222222 ref=1", "reverse 1111111111 ref=1:reversal"},
			[]EventType{EventCompensated}},
```

`http_test.go` menggunakan `fakeAccounts` yang sama, sehingga kedua _file_ diambil bersama dari _checkpoint_. `service_test.go` di _checkpoint_ juga tetap memuat `TestValidateAmount` dari Lab 4:

#perintah[```bash
git checkout lab-05 -- transfer/internal/transfer/service_test.go transfer/internal/transfer/http_test.go
cd transfer && go mod tidy && cd ..
make -C transfer test
```]

=== Service `notification`

`notification` adalah modul Go baru di _workspace_. Service ini mengetahui hasil transfer hanya dari _event_ di Kafka dan tidak pernah memanggil `transfer`. Struktur _payload_ _event_ ditulis ulang di modul `notification` dan tidak diimpor dari `transfer`. Kedua service hanya berbagi format data (kontrak), sedangkan kodenya tetap terpisah.

Buat modul dan daftarkan ke `go.work`:

#perintah[```bash
mkdir -p notification/internal/notification
cd notification
go mod init github.com/artivisi/training-microservices-2026-01/studi-kasus/notification
go mod edit -go=1.26.0
cd ..
go work use ./notification
```]

`go mod edit -go=1.26.0` menyamakan versi Go modul dengan `go.work`, karena `go mod init` menuliskan versi _toolchain_ yang terpasang di laptop.

==== Konfigurasi

Selain variabel yang sudah dikenal dari service lain, `notification` membutuhkan `KAFKA_GROUP_ID`. Kafka menyimpan _committed offset_ (posisi baca terakhir) per _consumer group_. Semua _instance_ `notification` menggunakan _group_ yang sama, sehingga setiap _event_ ditangani oleh salah satu _instance_ saja.

Buat `notification/config.go`:

```go
package main

import (
	"fmt"
	"os"
	"strings"
)

// Config comes from environment variables only (12-factor). Every variable is
// required: a missing value stops the service at startup instead of running
// with a guessed default.
type Config struct {
	HTTPAddr    string
	DatabaseURL string
	// KafkaBrokers is a comma-separated list of host:port.
	KafkaBrokers []string
	KafkaTopic   string
	// KafkaGroupID is the consumer group. Kafka keeps the committed offsets per
	// group; every instance of this service uses the same group, so each event is
	// handled by one of them.
	KafkaGroupID string
}

func LoadConfig() (Config, error) {
	var missing []string
	get := func(name string) string {
		v := os.Getenv(name)
		if v == "" {
			missing = append(missing, name)
		}
		return v
	}
	cfg := Config{
		HTTPAddr:     get("HTTP_ADDR"),
		DatabaseURL:  get("DATABASE_URL"),
		KafkaBrokers: strings.Split(get("KAFKA_BROKERS"), ","),
		KafkaTopic:   get("KAFKA_TOPIC"),
		KafkaGroupID: get("KAFKA_GROUP_ID"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	return cfg, nil
}
```

Buat `notification/Makefile`. Seperti service lain, semua langkah _pipeline_ nantinya memanggil target di _file_ ini:

```make
# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := notification

.PHONY: run test build clean

run:
	HTTP_ADDR=:28083 \
	DATABASE_URL=postgres://notification:notification123@localhost:15434/notification \
	KAFKA_BROKERS=localhost:19092 \
	KAFKA_TOPIC=transfer-events \
	KAFKA_GROUP_ID=notification \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
```

==== Model dan _Schema_

Kolom `event_id` di tabel `notification` sengaja belum dibuat unik. _Event_ yang dikirim ulang akan tersimpan dan dikirim lagi sebagai notifikasi ganda. Celah ini terlihat di bagian verifikasi dan ditutup di Lab 6.

Buat `notification/internal/notification/schema.sql`:

```sql
-- One row per notification sent to the customer (here: logged).
-- event_id is deliberately NOT unique yet: a redelivered event is stored and
-- sent again. Lab 6 makes the consumer idempotent.
create table if not exists notification (
    id          bigint generated always as identity primary key,
    event_id    uuid        not null,
    transfer_id uuid        not null,
    event_type  varchar(50) not null,
    message     text        not null,
    created_at  timestamptz not null default now()
);

create index if not exists notification_transfer on notification (transfer_id);
```

Buat `notification/internal/notification/notification.go`. Fungsi `Message` menyusun teks untuk nasabah berdasarkan jenis _event_. Jenis _event_ yang tidak dikenal ditandai `ok = false` dan dilewati oleh _consumer_:

```go
// Package notification tells customers about the outcome of their transfers. It
// learns about transfers only from events on Kafka; it never calls the transfer
// service.
package notification

import (
	"context"
	"fmt"
	"time"

	"github.com/shopspring/decimal"
)

type Notification struct {
	ID         int64     `json:"id"`
	EventID    string    `json:"event_id"`
	TransferID string    `json:"transfer_id"`
	EventType  string    `json:"event_type"`
	Message    string    `json:"message"`
	CreatedAt  time.Time `json:"created_at"`
}

// TransferEvent is the payload published by the transfer service. It is
// declared here again, not imported: services share the message format (the
// contract), not code. This side reads only the fields it needs.
type TransferEvent struct {
	EventID     string          `json:"event_id"`
	TransferID  string          `json:"transfer_id"`
	FromAccount string          `json:"from_account"`
	ToAccount   string          `json:"to_account"`
	Amount      decimal.Decimal `json:"amount"`
	Status      string          `json:"status"`
	OccurredAt  time.Time       `json:"occurred_at"`
}

// Message builds the customer-facing text for an event type. ok is false for an
// event type this service does not notify about.
func Message(eventType string, e TransferEvent) (msg string, ok bool) {
	amount := e.Amount.StringFixed(2)
	switch eventType {
	case "TransferCompleted":
		return fmt.Sprintf("Transfer %s dari %s ke %s berhasil.", amount, e.FromAccount, e.ToAccount), true
	case "TransferFailed":
		return fmt.Sprintf("Transfer %s dari %s ke %s gagal. Saldo tidak berubah.", amount, e.FromAccount, e.ToAccount), true
	case "TransferCompensated":
		return fmt.Sprintf("Transfer %s dari %s ke %s dibatalkan. Dana sudah dikembalikan ke %s.",
			amount, e.FromAccount, e.ToAccount, e.FromAccount), true
	}
	return "", false
}

type Store interface {
	Insert(ctx context.Context, n Notification) (Notification, error)
	ListByTransfer(ctx context.Context, transferID string) ([]Notification, error)
	Ping(ctx context.Context) error
}
```

Buat `notification/internal/notification/store.go`:

```go
package notification

import (
	"context"
	_ "embed"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schema string

const columns = `id, event_id::text, transfer_id::text, event_type, message, created_at`

type PostgresStore struct {
	pool *pgxpool.Pool
}

// NewPostgresStore connects, verifies the connection, and applies the schema.
func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect to database: %w", err)
	}
	if _, err := pool.Exec(ctx, schema); err != nil {
		pool.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &PostgresStore{pool: pool}, nil
}

func (s *PostgresStore) Close() { s.pool.Close() }

func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *PostgresStore) Insert(ctx context.Context, n Notification) (Notification, error) {
	rows, err := s.pool.Query(ctx, `
		insert into notification (event_id, transfer_id, event_type, message)
		values (@event_id, @transfer_id, @event_type, @message)
		returning `+columns,
		pgx.NamedArgs{"event_id": n.EventID, "transfer_id": n.TransferID, "event_type": n.EventType, "message": n.Message})
	if err != nil {
		return Notification{}, err
	}
	return pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Notification])
}

func (s *PostgresStore) ListByTransfer(ctx context.Context, transferID string) ([]Notification, error) {
	rows, err := s.pool.Query(ctx,
		`select `+columns+` from notification where transfer_id = @transfer_id order by id`,
		pgx.NamedArgs{"transfer_id": transferID})
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Notification])
}
```

==== _Consumer_ Kafka

_Consumer_ menggunakan `kafka.Reader` dari kafka-go dengan `GroupID`. Kafka membagi _partition_ _topic_ ke anggota _group_. Karena _topic_ memiliki 3 _partition_, pekerjaan dapat dibagi ke paling banyak tiga _instance_. _Group_ yang belum memiliki _committed offset_ mulai membaca dari _event_ paling awal (`kafka.FirstOffset`), sehingga _event_ yang dikirim ke Kafka sebelum `notification` pertama kali dijalankan tidak terlewat.

Urutan pemrosesan menentukan jaminan pengiriman. _Offset_ baru di-_commit_ setelah notifikasi tersimpan di database. Bila proses berhenti di antara kedua langkah tersebut, _event_ dikirim ulang setelah _restart_ (_at-least-once_) dan tidak pernah hilang. Konsekuensinya, _event_ yang sama dapat diterima lebih dari sekali, baik karena urutan ini maupun karena duplikasi dari _relay_ _outbox_ yang sudah dibahas sebelumnya.

Dua jenis kegagalan ditangani dengan cara berbeda. Pada kegagalan sementara, seperti Kafka atau database yang mati, koneksi putus, atau _timeout_, service tidak berhenti dan menunggu hingga kondisinya kembali normal. Kegagalan permanen berasal dari _event_ itu sendiri, sehingga setiap pengulangan pasti gagal lagi dan menahan semua _event_ berikutnya di _partition_ yang sama. _Event_ seperti ini disebut _poison message_, dan _consumer_ mencatatnya di log level `ERROR` lalu melewatinya:

- JSON yang tidak dapat dibaca;
- `event_id` atau `transfer_id` yang bukan UUID dalam bentuk standar 36 karakter (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`), karena kolom tujuannya bertipe `uuid` dan _insert_ akan gagal dengan `22P02` di setiap percobaan;
- _error_ PostgreSQL kelas 22 (data tidak valid, misalnya `22P02` atau `22001`) dan kelas 23 (_constraint_, misalnya `23502` atau `23514`).

_Error_ lain, termasuk kelas 42 (misalnya tabel tidak ada), tetap diulang. Kesalahan _schema_ seperti itu menggagalkan setiap _event_ tanpa kecuali, sehingga melewatinya berarti membuang seluruh notifikasi. Jenis _event_ yang tidak dikenal juga dilewati, dengan log level `WARN`. Di sistem _production_, _event_ yang dilewati dikirim ke _dead-letter topic_ untuk diperiksa secara manual.

Tambahkan _dependency_ modul:

#perintah[```bash
cd notification
go get github.com/segmentio/kafka-go@v0.4.51 github.com/jackc/pgx/v5@v5.11.0 \
  github.com/google/uuid@v1.6.0 github.com/shopspring/decimal@v1.6.0
cd ..
```]

Buat `notification/internal/notification/consumer.go`:

```go
package notification

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/segmentio/kafka-go"
)

// Reader is the part of kafka.Reader the consumer uses; tests can fake it.
type Reader interface {
	FetchMessage(ctx context.Context) (kafka.Message, error)
	CommitMessages(ctx context.Context, msgs ...kafka.Message) error
}

// NewKafkaReader joins the consumer group. Kafka assigns the topic's partitions
// to the group's members; with 3 partitions, up to 3 instances share the work.
func NewKafkaReader(brokers []string, topic, groupID string) *kafka.Reader {
	return kafka.NewReader(kafka.ReaderConfig{
		Brokers: brokers,
		Topic:   topic,
		GroupID: groupID,
		// Where a group without a committed offset starts: from the oldest event,
		// so nothing published before the first start is missed.
		StartOffset: kafka.FirstOffset,
		// 0 = CommitMessages commits synchronously, at the moment we call it.
		CommitInterval: 0,
	})
}

type Consumer struct {
	reader Reader
	store  Store
	log    *slog.Logger
	// retryDelay is the pause before a failed fetch or insert is tried again.
	retryDelay time.Duration
}

func NewConsumer(reader Reader, store Store, log *slog.Logger) *Consumer {
	return &Consumer{reader: reader, store: store, log: log, retryDelay: time.Second}
}

// Run handles events one by one until ctx is cancelled. Kafka or database
// outages are waited out, never a reason to stop.
//
// The offset is committed only AFTER the notification is stored: a crash in
// between means the event is delivered again after the restart (at-least-once),
// never that it is lost. The price is duplicates; together with the outbox
// relay's own duplicate window this consumer does see the same event twice
// sometimes. It is deliberately NOT idempotent yet: a redelivered event becomes
// a second notification. Lab 6 fixes that.
func (c *Consumer) Run(ctx context.Context) {
	for {
		m, err := c.reader.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			// Kafka unreachable or the group rebalancing. Not a reason to stop the
			// service: wait and fetch again; the committed offset says where.
			c.log.Warn("fetching event failed, retrying", "error", err)
			if !c.pause(ctx) {
				return
			}
			continue
		}
		if err := c.handle(ctx, m); err != nil {
			return // only ctx cancellation ends handle with an error
		}
		if err := c.reader.CommitMessages(ctx, m); err != nil {
			if ctx.Err() != nil {
				return
			}
			// The notification is stored but Kafka does not know. The event comes
			// again after a restart or rebalance: one more duplicate, nothing lost.
			c.log.Warn("committing offset failed", "partition", m.Partition, "offset", m.Offset, "error", err)
		}
	}
}

// handle stores the notification for m. Errors fall in two groups:
//
//   - Transient (database down, connection lost, timeout): retried until it
//     succeeds. Skipping would lose the notification, and moving on to later
//     events of the same partition would break their order.
//   - Permanent (the event itself is bad): logged at ERROR and skipped, so the
//     offset is committed. Retrying would fail the same way forever and block
//     every later event of the partition behind it (a poison message). In
//     production the event would go to a dead-letter topic for a person to look
//     at.
//
// The event is validated before the insert, so most bad events never reach the
// database; permanentDBError catches what slips through.
func (c *Consumer) handle(ctx context.Context, m kafka.Message) error {
	eventType := header(m, "event_type")
	log := c.log.With("event_type", eventType, "partition", m.Partition, "offset", m.Offset)

	var e TransferEvent
	if err := json.Unmarshal(m.Value, &e); err != nil {
		log.Error("skipping unreadable event", "error", err, "payload", string(m.Value))
		return nil
	}
	// The columns are uuid: a malformed ID would fail the insert with 22P02 on
	// every try.
	if !isUUID(e.EventID) || !isUUID(e.TransferID) {
		log.Error("skipping event with invalid event_id or transfer_id", "event_id", e.EventID,
			"transfer_id", e.TransferID, "payload", string(m.Value))
		return nil
	}
	msg, ok := Message(eventType, e)
	if !ok {
		log.Warn("skipping event type without notification", "event_id", e.EventID)
		return nil
	}

	n := Notification{EventID: e.EventID, TransferID: e.TransferID, EventType: eventType, Message: msg}
	for {
		stored, err := c.store.Insert(ctx, n)
		if err == nil {
			// Stand-in for the real channel (SMS, push, e-mail).
			log.Info("notification sent", "event_id", e.EventID, "transfer_id", e.TransferID,
				"notification_id", stored.ID, "message", msg)
			return nil
		}
		if permanentDBError(err) {
			log.Error("skipping event the database rejects", "event_id", e.EventID, "error", err,
				"payload", string(m.Value))
			return nil
		}
		log.Warn("storing notification failed, retrying", "event_id", e.EventID, "error", err)
		if !c.pause(ctx) {
			return errors.Join(ctx.Err(), err)
		}
	}
}

// isUUID accepts only the canonical 36-character form, the one the transfer
// service writes. uuid.Validate alone also accepts forms like "urn:uuid:...",
// which PostgreSQL rejects.
func isUUID(s string) bool {
	return len(s) == 36 && uuid.Validate(s) == nil
}

// permanentDBError reports whether PostgreSQL rejected the data itself, so the
// same insert fails the same way on every retry: SQLSTATE class 22 (data
// exception, e.g. 22P02 invalid uuid text, 22001 value too long) and class 23
// (integrity constraint, e.g. 23502 not null, 23514 check). Everything else is
// treated as transient and retried: connection errors, timeouts, and also
// schema errors (class 42, e.g. a missing table). Those fail every event, not
// one; retrying blocks consumption but loses nothing until a fix is deployed,
// while skipping would throw away every notification.
func permanentDBError(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	return strings.HasPrefix(pgErr.Code, "22") || strings.HasPrefix(pgErr.Code, "23")
}

// pause waits retryDelay and reports false when ctx ended first.
func (c *Consumer) pause(ctx context.Context) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(c.retryDelay):
		return true
	}
}

func header(m kafka.Message, key string) string {
	for _, h := range m.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}
```

Kegagalan sementara saat menyimpan ke database di-_retry_ terus-menerus dan tidak dilewati. Melewati _event_ berarti notifikasinya hilang, dan melanjutkan ke _event_ berikutnya di _partition_ yang sama akan merusak urutan. _Event_ yang dilewati karena kegagalan permanen tetap di-_commit_, agar tidak menghambat _partition_ selamanya.

==== API HTTP dan `main.go`

API `notification` hanya menyediakan `GET /notifications?transfer_id=...` beserta _probe_. Parameter `transfer_id` wajib diisi agar _channel_ tidak dapat meminta daftar notifikasi seluruh nasabah sekaligus. _Readiness probe_ hanya memeriksa database. Selama Kafka mati, _consumer_ cukup menunggu, dan API tetap dapat menjawab dari database.

Buat `notification/internal/notification/http.go`:

```go
package notification

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type Handler struct {
	store Store
	log   *slog.Logger
}

func NewHandler(store Store, log *slog.Logger) *Handler {
	return &Handler{store: store, log: log}
}

func (h *Handler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /notifications", h.list)
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	return mux
}

// list answers GET /notifications?transfer_id=... The filter is required: an
// unfiltered list of every customer's notifications is not something a channel
// should be able to ask for.
func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	transferID := r.URL.Query().Get("transfer_id")
	if _, err := uuid.Parse(transferID); err != nil {
		writeError(w, http.StatusBadRequest, "query parameter transfer_id must be a transfer ID (UUID)")
		return
	}
	ns, err := h.store.ListByTransfer(r.Context(), transferID)
	if err != nil {
		h.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if ns == nil {
		ns = []Notification{} // [] in JSON, not null
	}
	writeJSON(w, http.StatusOK, ns)
}

func (h *Handler) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
}

// readyz checks the database only. Kafka is not checked: while it is down the
// consumer simply waits, and the HTTP API can still answer from the database.
func (h *Handler) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.store.Ping(ctx); err != nil {
		h.log.Warn("readiness check failed", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "DOWN", "database": "DOWN"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP", "database": "UP"})
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
```

`main.go` menjalankan server HTTP dan _consumer_ sebagai dua _goroutine_. Saat berhenti, _consumer_ dihentikan terlebih dahulu, lalu `reader.Close()` (lewat `defer`) mengirim permintaan untuk keluar dari _consumer group_, sehingga Kafka menyerahkan _partition_ ke anggota lain tanpa menunggu _session timeout_. Meski begitu, Kafka masih dapat melaporkan _group_ tersebut sebagai `Stable` selama beberapa detik setelah `notification` berhenti. Buat `notification/main.go`:

```go
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/notification/internal/notification"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("notification service stopped", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	store, err := notification.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           notification.NewHandler(store, log).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Close leaves the consumer group, so Kafka hands this instance's partitions
	// to the remaining members right away instead of after a session timeout.
	reader := notification.NewKafkaReader(cfg.KafkaBrokers, cfg.KafkaTopic, cfg.KafkaGroupID)
	defer reader.Close()
	consumerCtx, stopConsumer := context.WithCancel(context.Background())
	defer stopConsumer()

	errCh := make(chan error, 1)
	go func() {
		log.Info("notification service listening", "addr", cfg.HTTPAddr)
		errCh <- srv.ListenAndServe()
	}()
	consumerDone := make(chan struct{})
	go func() {
		defer close(consumerDone)
		log.Info("consuming events", "kafka_brokers", cfg.KafkaBrokers, "topic", cfg.KafkaTopic, "group", cfg.KafkaGroupID)
		notification.NewConsumer(reader, store, log).Run(consumerCtx)
	}()

	select {
	case err := <-errCh:
		stopConsumer()
		<-consumerDone
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		// The event in progress is cut off before its offset commit, so it comes
		// again on the next start: never lost, a duplicate if its insert went through.
		stopConsumer()
		<-consumerDone
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
```

_Test_ untuk `notification` menggunakan _fake reader_ dan _fake store_, dengan ID _event_ dan ID transfer berupa UUID asli. Lima _test_ di dalamnya memeriksa hal berikut:

- `TestConsumerStoresAndCommits`: _consumer_ menunggu Kafka dan database yang mati, lalu meng-_commit_ setiap _event_;
- `TestConsumerIsNotIdempotentYet`: _event_ ganda masih menghasilkan dua notifikasi (celah yang ditutup Lab 6);
- `TestConsumerSkipsPoisonMessages`: _poison message_ dilewati dan di-_commit_;
- `TestPermanentDBError`: kelas SQLSTATE dipilah dengan benar;
- `TestListNotifications`: parameter `transfer_id` divalidasi.

Ambil _file_-nya dari _checkpoint_, lalu rapikan `go.mod` dan jalankan:

#perintah[```bash
git checkout lab-05 -- notification/internal/notification/consumer_test.go
cd notification && go mod tidy && cd ..
make -C notification test
```]

=== _Make Target_ untuk Lab 5

Tiga target baru di `Makefile` (folder `studi-kasus`) membantu mengamati alur _event_ tanpa _tools_ tambahan di laptop. Semua perintah Kafka dijalankan di dalam _container_ `kafka` yang sudah membawa skrip-skrip Kafka:

- `events` menampilkan seluruh isi _topic_ beserta _partition_, _header_, dan _key_-nya.
- `outbox` menampilkan 20 baris `outbox` terbaru. Baris dengan `published_at` kosong berisi _event_ yang belum terkirim.
- `replay` mengembalikan _offset_ _group_ `notification` ke awal _topic_, sehingga semua _event_ dikirim ulang. Kafka hanya mengizinkan _reset_ pada _group_ tanpa anggota aktif, sehingga `notification` harus dihentikan terlebih dahulu.

Tambahkan `notification` ke daftar service agar `make test` ikut menjalankan _test_-nya, lalu tambahkan variabel dan target berikut:

```make
SERVICES := account transfer notification
```

```make
KAFKA_TOPIC := transfer-events
KAFKA_BIN := /opt/kafka/bin

.PHONY: infra-up infra-down infra-reset test proto fault-slow fault-error fault-clear fault-status breaker \
	events outbox replay
```

```make
# Lab 5 helpers.

# Prints every event on the topic with its partition, headers and key, then
# exits after 5 s without new events (that exit is logged as a TimeoutException
# by the console consumer; it is not an error).
events:
	docker compose exec kafka $(KAFKA_BIN)/kafka-console-consumer.sh --bootstrap-server localhost:19092 \
		--topic $(KAFKA_TOPIC) --from-beginning --timeout-ms 5000 \
		--property print.key=true --property print.headers=true --property print.partition=true

# The newest outbox rows in the transfer database; published_at empty = not on Kafka yet.
outbox:
	docker compose exec db-transfer psql -U transfer -d transfer -c \
		"select id, aggregate_id, event_type, created_at, published_at from outbox order by created_at desc limit 20"

# Rewinds the notification consumer group to the first event, so every event is
# delivered again. Kafka only resets a group without active members: stop the
# notification service first.
replay:
	docker compose exec kafka $(KAFKA_BIN)/kafka-consumer-groups.sh --bootstrap-server localhost:19092 \
		--group notification --topic $(KAFKA_TOPIC) --reset-offsets --to-earliest --execute
```

Baris `.PHONY` di atas menggantikan baris `.PHONY` yang lama. Target `events`, `outbox`, dan `replay` diletakkan di akhir _file_.

== Verifikasi

Jalankan seluruh _test_ terlebih dahulu:

#perintah[```bash
make test
```]

Semua _package_ di `proto`, `account`, `transfer`, dan `notification` harus berakhir `ok`.

Jalankan infrastruktur, lalu ketiga service di tiga terminal terpisah (semuanya dari folder `studi-kasus`):

#perintah[```bash
make infra-up
make -C account run        # terminal 1
make -C transfer run       # terminal 2
make -C notification run   # terminal 3
```]

Log `transfer` menampilkan `msg="outbox relay started" interval=500ms`. Log `notification` menampilkan `msg="consuming events"` dengan `group=notification`.

Database sudah dikosongkan di awal lab, sehingga kedua rekening contoh perlu dibuat lagi:

#perintah[```bash
curl -sS -X POST localhost:28081/accounts -H 'Content-Type: application/json' \
  -d '{"number":"1111111111","owner_name":"Budi","initial_balance":500000}'
curl -sS -X POST localhost:28081/accounts -H 'Content-Type: application/json' \
  -d '{"number":"2222222222","owner_name":"Siti","initial_balance":100000}'
```]

=== Transfer Berhasil

#perintah[```bash
curl -sS -X POST localhost:28082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":100000}'
```]

Respons HTTP `201` dengan `"status":"COMPLETED"`. Catat nilai `id` dari respons tersebut. Dalam waktu kurang dari satu detik, log `transfer` menampilkan `msg="outbox events published" count=1`, dan log `notification` menampilkan baris seperti berikut:

#perintah[```
level=INFO msg="notification sent" event_type=TransferCompleted partition=1 offset=0
  event_id=... transfer_id=<id> notification_id=1
  message="Transfer 100000.00 dari 1111111111 ke 2222222222 berhasil."
```]

Nomor _partition_ dan _offset_ dapat berbeda karena _partition_ ditentukan oleh _hash_ ID transfer. Periksa notifikasi lewat API `notification`, dengan `<id>` diganti ID transfer:

#perintah[```bash
curl -sS "localhost:28083/notifications?transfer_id=<id>"
make outbox
make events
```]

API `notification` mengembalikan satu notifikasi dengan `event_type` `TransferCompleted`. `make outbox` menampilkan baris `TransferCompleted` dengan `published_at` terisi. `make events` mencetak setiap _event_ dalam satu baris: nomor _partition_, _header_ `event_type` dan `event_id`, _key_ berupa ID transfer, lalu _payload_ JSON. Perintah tersebut berhenti setelah 5 detik tanpa _event_ baru dan mencatat `TimeoutException`. Log tersebut menandai _console consumer_ berhenti secara normal.

=== Saldo Kurang

#perintah[```bash
curl -sS -X POST localhost:28082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"2222222222","to_account":"1111111111","amount":99000000}'
```]

Respons HTTP `422` dengan `"status":"FAILED"` dan `failure_reason` berisi `debit failed: debit 2222222222: insufficient funds`. `notification` mencatat `event_type=TransferFailed` dengan pesan `... gagal. Saldo tidak berubah.`

=== Kompensasi

Rekening tujuan yang tidak terdaftar membuat _credit_ gagal setelah _debit_ berhasil:

#perintah[```bash
curl -sS -X POST localhost:28082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"9999999999","amount":50000}'
```]

Respons HTTP `422` dengan `"status":"COMPENSATED"` dan `failure_reason` berisi `credit failed: credit 9999999999: account not found`. Kode `422` digunakan karena penyebabnya rekening yang tidak ada, dan _debit_ sudah dikembalikan. Log `transfer` menampilkan `msg="credit failed after debit, reversing the debit"`, dan log `account` menampilkan `msg="account mutated"` dengan `type=CREDIT` dan `reference` berakhiran `:reversal`. Saldo `1111111111` tidak berubah dibandingkan sebelum transfer ini. Mutasi di `db-account` menunjukkan dua baris untuk transfer tersebut, yaitu _debit_ dengan `reference` berisi ID transfer dan _credit_ dengan `reference` berakhiran `:reversal`:

#perintah[```bash
docker compose exec db-account psql -U account -d account -c \
  "select type, amount, reference from mutation where reference like '<id>%' order by id"
```]

`notification` mencatat `event_type=TransferCompensated` dengan pesan `... dibatalkan. Dana sudah dikembalikan ke 1111111111.`

=== Kafka Mati

Skenario ini menunjukkan manfaat _outbox_: transfer tetap berjalan meskipun Kafka mati, dan _event_ tersimpan di database sampai Kafka kembali aktif.

#perintah[```bash
docker compose stop kafka
curl -sS -X POST localhost:28082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":10000}'
make outbox
```]

Transfer tetap `COMPLETED` dengan HTTP `201`. Log `transfer` berulang kali menampilkan `msg="outbox publish failed, will retry"`, dan `make outbox` menampilkan baris terbaru dengan `published_at` kosong. Log `notification` menampilkan `msg="fetching event failed, retrying"`. Jalankan kembali Kafka:

#perintah[```bash
docker compose start kafka
make outbox
```]

Setelah Kafka berstatus `healthy`, log `transfer` menampilkan `outbox events published` dan `published_at` terisi. `notification` membutuhkan waktu lebih lama, sekitar 15–20 detik, karena _consumer group_ harus bergabung ulang terlebih dahulu. Setelah itu notifikasi untuk transfer tersebut muncul di log.

=== _Replay_ dan Notifikasi Ganda

Skenario ini memperlihatkan celah yang ditutup di Lab 6. Hentikan `notification` dengan `Ctrl+C` di terminal 3, tunggu 10–30 detik hingga Kafka mencatat _group_ tersebut tidak aktif, lalu kembalikan _offset_ _group_ ke awal:

#perintah[```bash
make replay
```]

_Output_ `make replay` berupa tabel dengan kolom `GROUP`, `TOPIC`, `PARTITION`, dan `NEW-OFFSET`, dengan `NEW-OFFSET` bernilai `0` untuk ketiga _partition_. Jalankan kembali `notification`:

#perintah[```bash
make -C notification run
```]

Log menampilkan `notification sent` untuk setiap _event_ yang pernah dikirim ke Kafka. Periksa isi `db-notification`:

#perintah[```bash
docker compose exec db-notification psql -U notification -d notification -c \
  "select count(*) as baris, count(distinct event_id) as event_unik from notification"
```]

Nilai `baris` sekarang dua kali `event_unik`: setiap _event_ tersimpan dua kali. `GET /notifications` untuk transfer pertama juga mengembalikan dua notifikasi dengan `event_id` yang sama.

=== _Poison Message_

_Event_ yang tidak mungkin diproses tidak boleh menahan _partition_. Kirim satu _event_ rusak langsung ke _topic_ dengan _console producer_ Kafka. _Key_ dan _payload_ dipisahkan karakter `|`, dan `event_id` maupun `transfer_id`-nya bukan UUID:

#perintah[```bash
echo 'k1|{"event_id":"abc","transfer_id":"def"}' | docker compose exec -T kafka \
  /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:19092 \
  --topic transfer-events --reader-property parse.key=true --reader-property key.separator='|'
docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:19092 --describe --group notification
```]

Log `notification` menampilkan `level=ERROR msg="skipping event with invalid event_id or transfer_id"` beserta _payload_-nya. _Output_ `--describe` menampilkan kolom `LAG` bernilai `0` untuk ketiga _partition_: _offset_ _event_ rusak tersebut sudah di-_commit_, dan _event_ berikutnya di _partition_ yang sama tetap diproses.

=== _Reversal_ Menunggu `account` Aktif Kembali

Dua skenario terakhir membutuhkan pengaturan waktu, karena _debit_ harus berhasil dan _credit_ harus gagal. _Delay_ 1,5 detik masih di bawah _timeout_ 2 detik, sehingga _debit_ berhasil. Satu detik kemudian, selagi _debit_ masih menunggu, `account` diubah agar menolak semua panggilan berikutnya. Lima detik setelahnya _fault injection_ dihapus (`make fault-clear`) dan `account` kembali normal, selagi _reversal_ masih di-_retry_:

#perintah[```bash
curl -sS -X PUT localhost:28081/admin/fault -d '{"delay_ms":1500,"error_rate":0}'
curl -sS -X POST localhost:28082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":10000}' &
sleep 1
curl -sS -X PUT localhost:28081/admin/fault -d '{"delay_ms":0,"error_rate":1}'
sleep 5
make fault-clear
wait
```]

Sekitar delapan detik setelah dikirim, transfer dijawab dengan `"status":"COMPENSATED"`. Log `transfer` menampilkan `msg="credit failed after debit, reversing the debit"`, beberapa baris `msg="retrying reversal"` dengan `next_attempt` dan `elapsed` yang bertambah, lalu `msg="transfer not completed" status=COMPENSATED`. Kode HTTP-nya bergantung pada _circuit breaker_ saat _credit_ gagal:

- `502` dengan `failure_reason` `credit failed: credit 2222222222: rpc error: code = Unavailable desc = injected fault`, bila _breaker_ tetap tertutup selama empat percobaan _credit_;
- `503` dengan `failure_reason` `credit failed: credit 2222222222: account service unavailable`, bila _breaker_ terbuka di tengah percobaan _credit_, misalnya karena masih ada kegagalan lain di antara 10 panggilan terakhir.

Pada kedua kode tersebut tidak ada uang yang berpindah: saldo `1111111111` dan `2222222222` sama dengan sebelum transfer ini. Seandainya _reversal_ melewati _breaker_ yang sama, kasus `503` di atas akan langsung berakhir `COMPENSATION_FAILED`.

Sebelum skenario berikutnya, jalankan `make breaker`. Bila hasilnya `open`, tunggu 10 detik agar _debit_ tidak langsung ditolak _circuit breaker_.

=== Kompensasi yang Gagal

Skenario terakhir sama dengan sebelumnya, tetapi _fault injection_ baru dihapus setelah transfer selesai, sehingga _reversal_ tidak pernah berhasil:

#perintah[```bash
curl -sS -X PUT localhost:28081/admin/fault -d '{"delay_ms":1500,"error_rate":0}'
curl -sS -X POST localhost:28082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":10000}' &
sleep 1
curl -sS -X PUT localhost:28081/admin/fault -d '{"delay_ms":0,"error_rate":1}'
wait
make fault-clear
```]

Jawaban datang setelah sekitar 32 detik: 2 detik untuk _debit_ dan _credit_, lalu 30 detik _retry_ _reversal_. Transfer dijawab HTTP `500` dengan `"status":"COMPENSATION_FAILED"`, dan `failure_reason` diakhiri `; reversal failed: reverse 1111111111: rpc error: code = Unavailable desc = injected fault`. Log `transfer` menampilkan sekitar sepuluh baris `retrying reversal`, lalu `level=ERROR msg="compensation failed, source account needs manual reversal"`. Tidak ada _event_ yang dikirim ke Kafka untuk transfer ini, sehingga `notification` tidak mencatat apa pun. Saldo `1111111111` berkurang 10000 tanpa ada uang yang masuk ke `2222222222`.

_Reversal_ tidak dihitung oleh _circuit breaker_, sehingga status _breaker_ hanya ditentukan oleh percobaan _debit_ dan _credit_. Periksa dengan `make breaker`. Bila hasilnya `open`, status tersebut tidak berubah tanpa panggilan. Tunggu 10 detik, lalu kirim tiga transfer kecil yang sah (misalnya 1000 dari `2222222222` ke `1111111111`). Ketiga panggilan tersebut menjadi panggilan uji pada status _half-open_. Setelah itu `make breaker` menampilkan `closed`.

== Masalah Umum

*`account` berhenti saat _startup_ dengan `apply schema: ... could not create unique index "mutation_idempotency" (SQLSTATE 23505)`.* Database masih berisi data Lab 1–4 dengan `reference` ganda di tabel `mutation`. Hentikan semua service, jalankan `make infra-reset` lalu `make infra-up`, dan buat ulang kedua rekening contoh.

*`missing required environment variables: KAFKA_BROKERS, KAFKA_TOPIC`.* `transfer` dijalankan dengan perintah lama. Jalankan dengan `make -C transfer run`, yang sudah memuat kedua variabel tersebut.

*Log `transfer` terus menampilkan `outbox publish failed` dengan `Unknown Topic Or Partition`.* _Topic_ belum dibuat, misalnya karena Kafka dijalankan dengan `docker compose up` tanpa `make infra-up`. Buat _topic_ dengan `docker compose run --rm kafka-init`. Pembuatan _topic_ otomatis memang dimatikan, sehingga Kafka tidak membuatnya sendiri.

*`make infra-up` gagal karena port 19092 sudah digunakan.* Ada program lain di laptop yang menggunakan port tersebut. Pada Linux dan macOS, `lsof -i :19092` menampilkan proses yang menggunakan port. Hentikan program tersebut selama lab berlangsung.

*`make replay` gagal dengan pesan bahwa _group_ `notification` masih aktif (`Assignments can only be reset if the group 'notification' is inactive, but the current state is Stable`).* `notification` masih berjalan, atau baru saja dihentikan dan Kafka belum mencatat bahwa anggotanya sudah keluar dari _group_. Pastikan `notification` sudah berhenti (`Ctrl+C`), tunggu 10–30 detik, lalu ulangi `make replay`.

*`notification` tidak menerima _event_ baru setelah Kafka dijalankan ulang.* _Consumer group_ kafka-go membutuhkan sekitar 15–20 detik untuk bergabung ulang. Selama itu log menampilkan `fetching event failed, retrying`. Tunggu hingga log `notification sent` muncul.

*Transfer pertama setelah `transfer` dijalankan terasa lambat, dan log menunjukkan _retry_.* Di macOS, resolusi nama `localhost` untuk koneksi gRPC pertama dapat memakan waktu lebih dari 2 detik saat _cold start_, sehingga percobaan pertama terkena _timeout_. Di lab ini _timeout_ di-_retry_, sehingga transfer tetap berhasil. Bila gejala ini mengganggu, ganti `ACCOUNT_GRPC_ADDR=localhost:29091` menjadi `ACCOUNT_GRPC_ADDR=127.0.0.1:29091` di `transfer/Makefile`.

*`make fault-slow` sekarang membuat transfer gagal jauh lebih lama dibandingkan Lab 4.* Perilaku ini memang diharapkan. _Timeout_ kini di-_retry_ hingga tiga kali, sehingga satu transfer menunggu sekitar empat kali 2 detik ditambah _backoff_ sebelum berakhir `FAILED`. Setelah beberapa transfer, _circuit breaker_ terbuka dan transfer berikutnya langsung ditolak dengan HTTP `503`.

*Transfer berakhir di `COMPENSATION_FAILED` dan tidak bisa diperbaiki.* Lab ini tidak menyediakan _tools_ untuk mengulang pengembalian. Pengembalian dapat dilakukan dengan aman lewat _credit_ ke rekening asal dengan `reference` `<transfer_id>:reversal`, karena `reference` yang sama menjamin _credit_ tersebut hanya diterapkan sekali. Untuk keperluan lab, data dapat dibersihkan dengan `make infra-reset` (seluruh data lab terhapus).

*`make infra-down` menampilkan peringatan bahwa jaringan masih digunakan.* Ada sisa _container_ `kafka-init` dari versi `Makefile` yang lama. Pastikan target `infra-down` sudah menggunakan `docker compose --profile init down`.

== Eksplorasi Mandiri

+ Jalankan dua _instance_ `notification` dengan `HTTP_ADDR` berbeda (misalnya `:28083` dan `:28084`), lalu kirim beberapa transfer. Amati nilai `partition` di log setiap _instance_: Kafka membagi tiga _partition_ di antara kedua _instance_. Hentikan salah satunya dan perhatikan _partition_ berpindah ke _instance_ yang tersisa.
+ Jalankan dua _instance_ `transfer` pada port berbeda, lalu kirim transfer bergantian ke keduanya selama Kafka mati. Setelah Kafka dijalankan kembali, periksa dengan `make events` bahwa setiap `event_id` hanya dikirim sekali ke Kafka. Hubungkan hasilnya dengan `for update skip locked` di _relay_.
+ Aturan _idempotency_ di `account` hanya membandingkan `reference`. Ubah `PostgresStore.Mutate` agar panggilan ulang dengan `reference` yang sama tetapi nominal berbeda ditolak dengan `codes.InvalidArgument`. Tentukan bagaimana `transfer` sebaiknya memperlakukan jawaban tersebut.
+ Rancang _reconciliation job_ untuk transfer yang tertahan di `PENDING`, `DEBITED`, atau `COMPENSATION_FAILED`: query apa yang menemukan transfer tersebut, panggilan apa yang diulang dengan `reference` yang sama, dan status apa yang dituju setelahnya.

== Checkpoint

Kondisi kode di akhir lab ini tersedia di tag `lab-05`. Bandingkan hasil kerja dengan _checkpoint_, atau lanjutkan dari _checkpoint_ bila tertinggal:

#perintah[```bash
git diff lab-05 -- .
git checkout lab-05
```]
