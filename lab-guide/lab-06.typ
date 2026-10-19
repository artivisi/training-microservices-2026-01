#import "../_template/panduan.typ": note, perintah

= Lab 6: _Idempotent Consumer_ dan _Header_ `Idempotency-Key`

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

+ menjelaskan mengapa _at-least-once delivery_ selalu menghasilkan duplikat, dan mengapa duplikat tersebut harus ditangani di sisi penerima;
+ membuat `notification` service menjadi _idempotent consumer_: _event_ yang dikirim ulang dilewati, sehingga notifikasi hanya tersimpan sekali;
+ menulis penanda "_event_ sudah diproses" dan hasil pemrosesannya dalam satu transaksi database;
+ menerima _header_ `Idempotency-Key` di `POST /transfers`, sehingga klien yang mengulang _request_ mendapatkan transfer yang sama, dan rekening asal tidak terdebit dua kali;
+ membuktikan kedua perilaku tersebut dengan _replay_ Kafka dan dengan _request_ paralel.

== Gambaran

Di Lab 5, sistem sudah memiliki tiga service. `transfer` menjalankan _saga_, menulis _event_ ke tabel `outbox`, lalu _relay_ mengirimnya ke Kafka. `notification` membaca _event_ tersebut dan menyimpan satu notifikasi untuk setiap _event_.

Pengiriman _event_ di Lab 5 bersifat _at-least-once_: setiap _event_ pasti sampai, tetapi bisa sampai lebih dari sekali. Ada tiga situasi yang mengirim ulang _event_ yang sama:

- _Relay_ berhenti setelah Kafka menerima _event_ tetapi sebelum kolom `published_at` terisi. Setelah _restart_, _relay_ mengirim _event_ tersebut lagi.
- `notification` berhenti setelah notifikasi tersimpan tetapi sebelum _offset_ di-_commit_. Kafka mengirim _event_ tersebut lagi ke anggota _consumer group_ berikutnya.
- Operator sengaja memutar ulang _topic_ dari awal (_replay_), misalnya setelah memperbaiki _bug_ di _consumer_.

Ketiga situasi tersebut wajar dan tidak dapat dihilangkan sepenuhnya. Jalan keluarnya ada di penerima: pemrosesan dibuat _idempotent_, artinya memproses _event_ yang sama berkali-kali menghasilkan keadaan yang sama dengan memprosesnya sekali. Rumus yang menjadi pegangan lab ini:

#align(center)[_at-least-once delivery_ + pemrosesan _idempotent_ = setiap efek terjadi tepat sekali]

Masalah yang sama muncul di sisi _channel_. Aplikasi _mobile banking_ mengirim `POST /transfers`, lalu koneksinya putus sebelum jawaban diterima. Aplikasi tidak tahu apakah transfer sudah dijalankan. Bila aplikasi mengirim ulang _request_ yang sama, tanpa perlindungan apa pun rekening asal terdebit dua kali. _Header_ `Idempotency-Key` menyelesaikan masalah tersebut: aplikasi membuat satu _key_ (biasanya UUID) untuk setiap transfer yang ingin dilakukan nasabah, lalu mengirim _key_ yang sama pada setiap pengulangan.

#perintah[```
  aplikasi channel                 transfer                  account
  ----------------                 --------                  -------
  POST /transfers  ------------->  tabel transfer
  Idempotency-Key: K               unique(idempotency_key)
  (diulang dengan K yang sama)     K sudah ada? kembalikan
                                   transfer asli, HTTP 200
                                        |
                                        | gRPC Debit/Credit, reference = transfer_id
                                        +--------------------->  unique(account_number,
                                        |                               type, reference)
                                        | outbox -> Kafka            (Lab 5)
                                        v
                                   topic transfer-events
                                        |
                                        v
                                   notification
                                   tabel processed_event (event_id primary key)
                                   + tabel notification, satu transaksi
```]

Dengan lab ini, sistem memiliki tiga titik _idempotency_ dengan pola yang sama: penerima menyimpan sebuah identitas unik, lalu menolak memproses identitas yang sama untuk kedua kalinya.

#table(
  columns: (auto, 1fr, 1fr, 1fr),
  [Titik], [Pengirim dan Penerima], [Identitas Unik], [Lab],
  [Mutasi saldo], [`transfer` ke `account` (gRPC)], [`reference` = ID transfer, unik per rekening dan jenis mutasi], [Lab 5],
  [_Consumer_ Kafka], [Kafka ke `notification`], [`event_id` di tabel `processed_event`], [Lab 6],
  [API transfer], [Aplikasi _channel_ ke `transfer` (REST)], [Nilai _header_ `Idempotency-Key`], [Lab 6],
)

Di Lab 5, _idempotency_ sudah diterapkan antarservice pada mutasi saldo. _Header_ `Idempotency-Key` menerapkan gagasan yang sama antara _channel_ dan service.

== Titik Awal

Lab ini dimulai dari kondisi akhir Lab 5. Peserta yang belum menyelesaikan Lab 5 dapat memulai dari tag `lab-05` dengan _branch_ kerja baru:

#perintah[```bash
cd studi-kasus
git switch -c lab-06-kerja lab-05
```]

Jalankan infrastruktur dan ketiga service, masing-masing di terminal tersendiri:

#perintah[```bash
make infra-up
make -C account run
make -C transfer run
make -C notification run
```]

Database dari Lab 5 tidak perlu di-_reset_. Setiap service menjalankan `schema.sql` miliknya saat _startup_, dan semua perubahan _schema_ di lab ini ditulis dengan `if not exists`, sehingga aman dijalankan pada database lama.

Contoh di lab ini menggunakan rekening `1111111111` dan `2222222222` dari lab sebelumnya. Bila rekening tersebut belum ada, buat terlebih dahulu:

#perintah[```bash
curl -X POST localhost:8081/accounts \
  -d '{"number":"1111111111","owner_name":"Budi","initial_balance":"10000000"}'
curl -X POST localhost:8081/accounts \
  -d '{"number":"2222222222","owner_name":"Sari","initial_balance":"0"}'
```]

== Langkah

=== Mengamati notifikasi ganda di Lab 5

Sebelum mengubah kode, buktikan dulu masalahnya. Buat satu transfer, lalu catat nilai `id` dari jawabannya:

#perintah[```bash
curl -X POST localhost:8082/transfers \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

Hentikan `notification` dengan `Ctrl+C`. Kafka hanya mengizinkan _offset_ sebuah _consumer group_ diubah ketika group tersebut tidak memiliki anggota aktif. Setelah itu, kembalikan _offset_ group `notification` ke awal _topic_, lalu jalankan `notification` lagi:

#perintah[```bash
make replay
make -C notification run
```]

Log `notification` menampilkan `notification sent` untuk setiap _event_ yang pernah ada di _topic_, termasuk _event_ yang sudah diproses sebelumnya. Periksa notifikasi untuk transfer tadi (ganti `<id>` dengan ID transfer):

#perintah[```bash
curl "localhost:8083/notifications?transfer_id=<id>"
```]

Hasilnya berisi dua notifikasi dengan `event_id` yang sama. Di sistem sungguhan, nasabah menerima SMS "Transfer berhasil" dua kali untuk satu transfer. _Replay_ sengaja dipilih untuk demonstrasi karena mudah diulang; jalur kodenya sama dengan pengiriman ulang akibat _crash_ atau _rebalance_.

=== Tabel `processed_event` di `notification`

Cara paling langsung untuk mengenali duplikat adalah mencatat setiap `event_id` yang sudah diproses. `event_id` dibuat oleh `transfer` saat menulis _outbox_ (Lab 5) dan ikut dikirim di _payload_ maupun _header_ Kafka, sehingga nilainya sama pada setiap pengiriman ulang.

Pencatatan ini menggunakan tabel tersendiri, `processed_event`, dengan `event_id` sebagai _primary key_. Alternatifnya adalah _unique index_ pada `notification.event_id`, tetapi tabel tersendiri lebih tepat karena dua alasan:

- Aturan yang dijaga adalah "_event_ ini sudah ditangani". Ada _event_ yang tidak menghasilkan baris notifikasi, dan ada _event_ yang mungkin menghasilkan beberapa baris. Tabel `processed_event` berlaku untuk semua kasus tersebut.
- Tabel `notification` dari Lab 5 sudah berisi baris ganda. Pembuatan _unique index_ di atas data tersebut akan gagal, sedangkan tabel baru dapat dibuat tanpa menyentuh data lama.

Tambahkan bagian berikut di akhir `notification/internal/notification/schema.sql`. Hapus juga komentar lama di atas `create table notification` yang menyatakan `event_id` sengaja belum unik.

```sql
-- Idempotent consumer (Lab 6): one row per event already handled. It is
-- inserted in the same transaction as the notification, so "handled" and
-- "notification stored" are always both true or both false. A redelivered event
-- (relay duplicate, rebalance, replay) hits the primary key and is skipped.
create table if not exists processed_event (
    event_id     uuid        primary key,
    processed_at timestamptz not null default now()
);

-- Events handled in Lab 5, before this table existed, count as processed: a
-- replay after the upgrade must not notify about them once more. Re-running it
-- on every start changes nothing.
insert into processed_event (event_id)
select distinct event_id from notification
on conflict (event_id) do nothing;
```

Perintah `insert ... select` di bagian akhir menangani database yang sudah terisi di Lab 5. Tanpa perintah tersebut, `processed_event` kosong saat pertama kali dibuat, dan _replay_ berikutnya akan mengirim ulang notifikasi untuk semua transfer lama. Karena menggunakan `on conflict do nothing`, perintah tersebut aman dijalankan pada setiap _startup_.

=== `Store.Insert` dalam satu transaksi

Penanda "sudah diproses" dan notifikasinya harus disimpan bersama. Bila keduanya disimpan terpisah, ada dua kemungkinan kegagalan:

- Penanda tersimpan, notifikasi gagal: _event_ dianggap selesai padahal notifikasi tidak pernah ada.
- Notifikasi tersimpan, penanda gagal: pengiriman ulang menghasilkan notifikasi ganda lagi.

Dengan satu transaksi, keduanya selalu sama-sama ada atau sama-sama tidak ada.

Ubah kontrak `Store` di `notification/internal/notification/notification.go`. `Insert` sekarang mengembalikan nilai `inserted` yang bernilai `false` ketika _event_ sudah pernah diproses:

```go
type Store interface {
	// Insert stores the notification and marks its event as processed, in one
	// transaction. inserted is false, and nothing is stored, when the event was
	// processed before.
	Insert(ctx context.Context, n Notification) (stored Notification, inserted bool, err error)
	ListByTransfer(ctx context.Context, transferID string) ([]Notification, error)
	Ping(ctx context.Context) error
}
```

Lalu ganti seluruh fungsi `Insert` di `notification/internal/notification/store.go`:

```go
func (s *PostgresStore) Insert(ctx context.Context, n Notification) (Notification, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Notification{}, false, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

	// The processed_event row goes in first, as the duplicate check. A second
	// delivery of the same event being handled concurrently (another instance
	// after a rebalance) waits on the primary key until this transaction ends,
	// then sees the conflict: the notification is stored once.
	tag, err := tx.Exec(ctx,
		`insert into processed_event (event_id) values (@event_id) on conflict (event_id) do nothing`,
		pgx.NamedArgs{"event_id": n.EventID})
	if err != nil {
		return Notification{}, false, err
	}
	if tag.RowsAffected() == 0 {
		return Notification{}, false, nil
	}

	rows, err := tx.Query(ctx, `
		insert into notification (event_id, transfer_id, event_type, message)
		values (@event_id, @transfer_id, @event_type, @message)
		returning `+columns,
		pgx.NamedArgs{"event_id": n.EventID, "transfer_id": n.TransferID, "event_type": n.EventType, "message": n.Message})
	if err != nil {
		return Notification{}, false, err
	}
	stored, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Notification])
	if err != nil {
		return Notification{}, false, err
	}
	return stored, true, tx.Commit(ctx)
}
```

Beberapa hal yang perlu diperhatikan dari kode tersebut:

- Baris `processed_event` ditulis lebih dahulu dan berfungsi sebagai pemeriksaan duplikat. `on conflict do nothing` tidak menghasilkan _error_; `RowsAffected() == 0` berarti `event_id` tersebut sudah ada.
- Pemeriksaan dan penulisan terjadi dalam satu perintah SQL. Pola "`select` dulu, lalu `insert` bila belum ada" tidak aman, karena dua proses dapat sama-sama melihat tabel kosong lalu sama-sama menyimpan notifikasi.
- Bila dua instance `notification` memproses _event_ yang sama secara bersamaan (misalnya saat _rebalance_), transaksi kedua tertahan oleh _lock_ pada _primary key_ hingga transaksi pertama selesai, lalu mendapatkan konflik.
- `defer tx.Rollback(ctx)` membatalkan transaksi pada setiap jalur keluar sebelum `Commit`. Setelah `Commit` berhasil, `Rollback` tidak melakukan apa pun.

=== _Consumer_ melewati duplikat

Di `notification/internal/notification/consumer.go`, fungsi `handle` memanggil `Insert`. Sesuaikan isi perulangan `for` di bagian akhir `handle` dengan tiga nilai kembalian yang baru:

```go
	n := Notification{EventID: e.EventID, TransferID: e.TransferID, EventType: eventType, Message: msg}
	for {
		stored, inserted, err := c.store.Insert(ctx, n)
		if err == nil && !inserted {
			// The offset is still committed by Run: the event is done, its
			// redelivery must not block the partition.
			log.Info("duplicate event skipped", "event_id", e.EventID, "transfer_id", e.TransferID)
			return nil
		}
		if err == nil {
			// Stand-in for the real channel (SMS, push, e-mail). A real channel call
			// is outside the database transaction: send after commit and a crash in
			// between loses the message; send before commit and it may go twice. With
			// a provider that accepts an idempotency key (the event_id), sending
			// before the commit is safe.
			log.Info("notification sent", "event_id", e.EventID, "transfer_id", e.TransferID,
				"notification_id", stored.ID, "message", msg)
			return nil
		}
		log.Warn("storing notification failed, retrying", "event_id", e.EventID, "error", err)
		if !c.pause(ctx) {
			return errors.Join(ctx.Err(), err)
		}
	}
```

Duplikat dikembalikan sebagai `nil`, sama seperti _event_ yang berhasil diproses. Akibatnya, `Run` tetap melakukan _commit offset_ untuk _event_ duplikat. Langkah ini penting: bila _offset_ tidak di-_commit_, Kafka terus mengirim _event_ yang sama, dan semua _event_ berikutnya di _partition_ tersebut tertahan di belakangnya.

Komentar di jalur `notification sent` membahas batas dari solusi ini. Di lab ini, "mengirim notifikasi" hanya berupa baris log. Pengiriman sungguhan melalui SMS atau _push notification_ memanggil sistem lain yang berada di luar transaksi database, sehingga transaksi tidak dapat menjaminnya:

- Bila dikirim setelah _commit_ dan proses berhenti di antaranya, notifikasi tidak pernah terkirim.
- Bila dikirim sebelum _commit_ dan transaksi gagal, pengiriman ulang _event_ mengirim notifikasi kedua.

Solusinya ada di penyedia layanan: banyak _provider_ SMS dan _push_ menerima _idempotency key_ di _request_-nya. Dengan `event_id` sebagai _key_ tersebut, pengiriman sebelum _commit_ menjadi aman.

Perbarui juga komentar di atas fungsi `Run` agar sesuai dengan perilaku baru. Ganti dua baris terakhir komentar tersebut (mulai `It is deliberately NOT idempotent yet`) dengan:

```go
// sometimes. It is idempotent (Lab 6): the store remembers every processed
// event_id, and a redelivered event is skipped instead of notifying twice.
// at-least-once delivery + idempotent processing = each effect exactly once.
```

Dua komentar lain juga berubah: komentar di jalur gagal `CommitMessages` di dalam `Run`, dan komentar _shutdown_ di `notification/main.go`. Keduanya sekarang menyebut bahwa _event_ yang datang lagi dilewati sebagai duplikat. Perubahan komentar tersebut dan bagian _Idempotency_ baru di `studi-kasus/README.md` tersedia di tag `lab-06` dan tidak memengaruhi perilaku program.

=== Memperbarui _test_ `notification`

`fakeStore` di `notification/internal/notification/consumer_test.go` mengimplementasikan `Store`, sehingga harus mengikuti kontrak baru. Ganti `fakeStore` dan fungsi `Insert`-nya dengan versi yang mengingat `event_id`:

```go
// fakeStore fails the first failures inserts, then stores each event once.
type fakeStore struct {
	rows      []Notification
	processed map[string]bool
	failures  int
}

func (f *fakeStore) Insert(_ context.Context, n Notification) (Notification, bool, error) {
	if f.failures > 0 {
		f.failures--
		return Notification{}, false, errors.New("database down")
	}
	if f.processed[n.EventID] {
		return Notification{}, false, nil
	}
	if f.processed == nil {
		f.processed = map[string]bool{}
	}
	f.processed[n.EventID] = true
	n.ID = int64(len(f.rows) + 1)
	f.rows = append(f.rows, n)
	return n, true, nil
}
```

_Test_ `TestConsumerIsNotIdempotentYet` dari Lab 5 mendokumentasikan celah yang sekarang sudah ditutup. Ganti _test_ tersebut dengan _test_ yang membuktikan perilaku baru: empat _event_ masuk, dua di antaranya duplikat, hasilnya dua notifikasi dan keempat _offset_ tetap di-_commit_.

```go
// The same event delivered twice (relay duplicate or replay) becomes one
// notification, and both deliveries are committed.
func TestConsumerSkipsDuplicates(t *testing.T) {
	store := &fakeStore{}
	reader := runConsumer(t, store,
		event(0, "TransferCompensated", "e-1"),
		event(1, "TransferCompleted", "e-2"),
		event(0, "TransferCompensated", "e-1"), // replay from the start
		event(1, "TransferCompleted", "e-2"),
	)
	if len(store.rows) != 2 {
		t.Fatalf("rows = %d, want 2 (duplicates skipped)", len(store.rows))
	}
	if fmt.Sprint(reader.committed) != "[0 1 0 1]" {
		t.Fatalf("committed = %v, want [0 1 0 1]", reader.committed)
	}
}
```

Jalankan _test_ `notification`:

#perintah[```bash
make -C notification test
```]

=== _Make target_ `duplicates`

Untuk memeriksa hasil _replay_ tanpa membuka `psql` secara manual, tambahkan _target_ berikut di akhir `Makefile` di direktori `studi-kasus`, lalu tambahkan `duplicates` ke daftar `.PHONY`:

```make
# Lab 6: events with more than one notification. Empty after a replay = the
# consumer is idempotent. Rows from Lab 5 (before processed_event) stay listed.
duplicates:
	docker compose exec db-notification psql -U notification -d notification -c \
		"select event_id, event_type, count(*) as notifications from notification group by event_id, event_type having count(*) > 1"
```

Baris perintah di dalam _target_ `Makefile` wajib diawali karakter _tab_. Baris yang diawali spasi menghasilkan _error_ `missing separator`.

=== Kolom `idempotency_key` di `transfer`

Sekarang beralih ke sisi _channel_. `transfer` menyimpan nilai _header_ `Idempotency-Key` di tabel `transfer` dengan _unique index_. Tambahkan bagian berikut di akhir `transfer/internal/transfer/schema.sql`:

```sql
-- Idempotency key (Lab 6): the value of the Idempotency-Key header of POST
-- /transfers. A channel that retries a request whose answer it never got
-- (timeout, dropped connection) sends the same key again and gets the original
-- transfer back instead of a second debit. NULL for requests without the
-- header; PostgreSQL treats NULLs as distinct, so they never collide on the
-- unique index.
alter table transfer add column if not exists idempotency_key varchar(100);
create unique index if not exists transfer_idempotency_key on transfer (idempotency_key);
```

Kolom tersebut boleh `NULL`. _Request_ tanpa _header_ menyimpan `NULL`, dan PostgreSQL menganggap setiap `NULL` berbeda satu sama lain, sehingga transfer dari Lab 2–5 dan transfer baru tanpa _header_ tidak melanggar _unique index_.

=== Validasi dan pembanding _request_ di `transfer.go`

Tiga hal ditambahkan di `transfer/internal/transfer/transfer.go`: _error_ untuk _key_ yang digunakan ulang dengan isi berbeda, fungsi pembanding _request_, dan validasi format _key_.

Tambahkan `ErrIdempotencyKeyReused` di dalam blok `var (...)` yang berisi `ErrStaleState`:

```go
	// ErrIdempotencyKeyReused: the Idempotency-Key was used before for a
	// different transfer. Most likely a client bug (a key reused for a new
	// request); executing it would silently drop one of the two.
	ErrIdempotencyKeyReused = errors.New("idempotency key already used for a different request")
```

Setelah blok `var (...)` tersebut, tambahkan `SameRequest`. Ketika _key_ yang sama datang lagi, `transfer` harus memastikan bahwa _request_ tersebut memang pengulangan, bukan transfer baru yang secara keliru menggunakan _key_ lama. Nominal dibandingkan sebagai desimal dengan `Equal`, sehingga `"100000"` dan `"100000.00"` dianggap sama.

```go
// SameRequest reports whether t was created from req: the check behind an
// Idempotency-Key that comes again. Decimal comparison, so "100000" and
// "100000.00" are the same amount.
func (t Transfer) SameRequest(req CreateRequest) bool {
	return t.FromAccount == req.FromAccount && t.ToAccount == req.ToAccount && t.Amount.Equal(req.Amount)
}
```

Setelah deklarasi `numberPattern`, tambahkan validasi _key_. Batas 100 karakter mengikuti ukuran kolom, dan karakter yang diizinkan hanya ASCII yang dapat dicetak tanpa spasi (`\x21`–`\x7e`):

```go
// keyPattern bounds the Idempotency-Key: printable ASCII, up to the column
// size. A UUID generated by the client is the usual choice.
var keyPattern = regexp.MustCompile(`^[\x21-\x7e]{1,100}$`)

// ValidateIdempotencyKey checks a non-empty Idempotency-Key header value.
func ValidateIdempotencyKey(key string) error {
	if !keyPattern.MatchString(key) {
		return ValidationError{"Idempotency-Key": "must be 1-100 printable ASCII characters without spaces"}
	}
	return nil
}
```

Terakhir, ubah deklarasi `Create` di _interface_ `Store`:

```go
	// Create records a new transfer in status PENDING. With a non-empty
	// idempotencyKey that is already stored, nothing is inserted: it returns the
	// transfer stored under that key and created = false.
	Create(ctx context.Context, req CreateRequest, idempotencyKey string) (t Transfer, created bool, err error)
```

=== `Create` di `store.go`

Pemeriksaan _key_ dan penyimpanan transfer baru harus terjadi dalam satu perintah SQL, dengan alasan yang sama seperti di `notification`: pola "cari dulu, simpan bila belum ada" membuka celah bagi dua _request_ paralel. Ganti fungsi `Create` di `transfer/internal/transfer/store.go`:

```go
func (s *PostgresStore) Create(ctx context.Context, req CreateRequest, idempotencyKey string) (Transfer, bool, error) {
	// "on conflict do nothing" + no row returned = the key exists. A concurrent
	// request with the same key waits on the unique index until the first insert
	// commits, then takes this path too: one transfer per key, even under a race.
	t, err := one(ctx, s.pool, `
		insert into transfer (from_account, to_account, amount, status, idempotency_key)
		values (@from, @to, @amount, 'PENDING', nullif(@key, ''))
		on conflict (idempotency_key) do nothing
		returning `+columns,
		pgx.NamedArgs{"from": req.FromAccount, "to": req.ToAccount, "amount": req.Amount, "key": idempotencyKey})
	if errors.Is(err, ErrNotFound) && idempotencyKey != "" {
		existing, err := one(ctx, s.pool, `select `+columns+` from transfer where idempotency_key = @key`,
			pgx.NamedArgs{"key": idempotencyKey})
		return existing, false, err
	}
	return t, err == nil, err
}
```

Cara kerjanya:

- `nullif(@key, '')` mengubah _key_ kosong menjadi `NULL`, sehingga _request_ tanpa _header_ selalu menghasilkan transfer baru.
- Bila _key_ sudah ada, `on conflict do nothing` membuat `returning` tidak menghasilkan baris. Fungsi `one` menerjemahkan kondisi tanpa baris tersebut menjadi `ErrNotFound`, lalu `Create` mengambil transfer yang tersimpan dengan _key_ tersebut dan mengembalikan `created = false`.

=== `Execute` di `service.go`

Fungsi `Execute` di `transfer/internal/transfer/service.go` sekarang menerima _key_ dan mengembalikan nilai tambahan `replayed`. Bagian _saga_ (_debit_, _credit_, kompensasi) tidak berubah, hanya dipindahkan ke fungsi baru `run`. Ganti _signature_ dan bagian awal `Execute`, hingga dan termasuk baris `if err := s.accounts.Debit(...)`, menjadi:

```go
//
// idempotencyKey (optional, from the Idempotency-Key header) makes a retried
// request safe: when the key was seen before, the saga does not run again and
// the original transfer is returned in whatever state it is now, with the
// second result (replayed) true. A request still in progress comes back as
// PENDING or DEBITED; the client polls GET /transfers/{id}.
func (s *Service) Execute(ctx context.Context, req CreateRequest, idempotencyKey string) (Transfer, bool, error) {
	t, created, err := s.store.Create(ctx, req, idempotencyKey)
	if err != nil {
		return Transfer{}, false, fmt.Errorf("record transfer: %w", err)
	}
	if !created {
		if !t.SameRequest(req) {
			s.log.Warn("idempotency key reused with a different request",
				"idempotency_key", idempotencyKey, "transfer_id", t.ID)
			return Transfer{}, false, ErrIdempotencyKeyReused
		}
		s.log.Info("idempotent replay, returning the original transfer",
			"idempotency_key", idempotencyKey, "transfer_id", t.ID, "status", t.Status)
		return t, true, nil
	}
	t, err = s.run(ctx, t)
	return t, false, err
}

// run executes the saga steps on a freshly recorded transfer.
func (s *Service) run(ctx context.Context, t Transfer) (Transfer, error) {

	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
```

Sisa isi fungsi lama, mulai dari penanganan _error_ `Debit` hingga akhir, tetap seperti semula dan sekarang menjadi isi `run`. Komentar di atas fungsi yang menjelaskan langkah _saga_ tetap dipertahankan; paragraf `idempotencyKey` di atas ditambahkan di bawahnya.

Perhatikan bahwa jawaban untuk pengulangan berisi transfer asli dengan status saat ini. Bila _request_ pertama masih berjalan, misalnya sedang menunggu `account`, _request_ kedua menerima status `PENDING` atau `DEBITED`. _Saga_ tidak dijalankan untuk kedua kalinya; klien cukup memeriksa `GET /transfers/{id}` hingga statusnya final.

=== _Handler_ `POST /transfers`

Di `transfer/internal/transfer/http.go`, fungsi `create` membaca _header_, memvalidasinya, lalu memilih kode HTTP. Tambahkan pembacaan _header_ setelah validasi `req.Validate()` dan sebelum pemanggilan `Execute`:

```go
	// Optional here so the requests of Labs 2-5 keep working. A channel-facing
	// payment API in production makes it required: without it, a client that
	// retries after a lost response cannot tell whether it pays twice.
	key := r.Header.Get("Idempotency-Key")
	if key != "" {
		if err := ValidateIdempotencyKey(key); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "fields": err})
			return
		}
	}
```

Lalu ubah pemanggilan `Execute` dan tambahkan dua `case` pertama di awal blok `switch`. Urutan ini penting: pengulangan dan _key_ yang digunakan ulang harus ditangani sebelum `case err == nil`.

```go
	t, replayed, err := h.svc.Execute(context.WithoutCancel(r.Context()), req, key)
	switch {
	case replayed:
		// 200, not 201: nothing was created by this request. The body is the
		// original transfer in its current state, whatever its outcome was.
		w.Header().Set("Location", "/transfers/"+t.ID)
		w.Header().Set("Idempotent-Replayed", "true")
		writeJSON(w, http.StatusOK, t)
	case errors.Is(err, ErrIdempotencyKeyReused):
		writeError(w, http.StatusUnprocessableEntity, err.Error())
	case err == nil:
		// ... case lama dari Lab 5 berlanjut di sini, tanpa perubahan
```

Pilihan kode HTTP-nya:

- *201 Created* hanya untuk _request_ yang benar-benar membuat transfer.
- *200 OK* untuk pengulangan, karena _request_ tersebut tidak membuat apa pun. _Header_ `Idempotent-Replayed: true` memberi tahu klien bahwa jawaban tersebut berasal dari transfer yang sudah ada. Transfer asli dikembalikan apa pun hasilnya, termasuk `FAILED` atau `COMPENSATED`.
- *422 Unprocessable Entity* ketika _key_ yang sama datang dengan _body_ berbeda. Kemungkinan besar kondisi ini adalah _bug_ di klien yang menggunakan _key_ lama untuk transfer baru. Menjalankannya berarti salah satu dari dua transfer tersebut hilang tanpa diketahui klien.
- *400 Bad Request* ketika format _key_ tidak valid.

_Header_ ini sengaja dibuat opsional agar perintah `curl` dari Lab 2–5 tetap berjalan. API pembayaran yang diakses _channel_ di _production_ mewajibkannya.

=== Memperbarui _test_ `transfer`

Di `transfer/internal/transfer/service_test.go`, `fakeStore` harus mengikuti kontrak `Create` yang baru. Tambahkan _field_ `keys` dan fungsi `newFakeStore`, lalu ganti `Create`:

```go
type fakeStore struct {
	transfers map[string]Transfer
	keys      map[string]string // idempotency key -> transfer ID
	events    []EventType
	seq       int
}

func newFakeStore() *fakeStore {
	return &fakeStore{transfers: map[string]Transfer{}, keys: map[string]string{}}
}

func (f *fakeStore) Create(_ context.Context, req CreateRequest, key string) (Transfer, bool, error) {
	if id, ok := f.keys[key]; ok && key != "" {
		return f.transfers[id], false, nil
	}
	f.seq++
	t := Transfer{ID: fmt.Sprint(f.seq), FromAccount: req.FromAccount, ToAccount: req.ToAccount, Amount: req.Amount, Status: Pending}
	f.transfers[t.ID] = t
	if key != "" {
		f.keys[key] = t.ID
	}
	return t, true, nil
}
```

Di `TestExecuteSaga`, ganti pembuatan _store_ dan pemanggilan `Execute`:

```go
			store := newFakeStore()
			// ...
			got, _, err := svc.Execute(context.Background(), req, "")
```

Tambahkan _test_ baru di file yang sama. _Test_ ini memeriksa empat perilaku: transfer pertama berjalan, pengulangan dengan nominal yang ditulis berbeda tidak memanggil `account` lagi, _body_ berbeda ditolak, dan _request_ tanpa _key_ selalu menjadi transfer baru.

```go
func TestExecuteIdempotencyKey(t *testing.T) {
	req := CreateRequest{FromAccount: "1111111111", ToAccount: "2222222222", Amount: decimal.RequireFromString("100000")}
	store := newFakeStore()
	accounts := &fakeAccounts{}
	svc := NewService(store, accounts, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx := context.Background()

	first, replayed, err := svc.Execute(ctx, req, "key-1")
	if err != nil || replayed || first.Status != Completed {
		t.Fatalf("first: %+v replayed=%v err=%v, want COMPLETED", first, replayed, err)
	}

	// Same key, same body written differently: the original, no new account calls.
	same := req
	same.Amount = decimal.RequireFromString("100000.00")
	again, replayed, err := svc.Execute(ctx, same, "key-1")
	if err != nil || !replayed || again.ID != first.ID {
		t.Fatalf("replay: %+v replayed=%v err=%v, want transfer %s replayed", again, replayed, err, first.ID)
	}
	if len(accounts.calls) != 2 {
		t.Fatalf("account calls = %q, want only the first transfer's debit and credit", accounts.calls)
	}

	// Same key, different body.
	other := req
	other.Amount = decimal.RequireFromString("5")
	if _, _, err := svc.Execute(ctx, other, "key-1"); !errors.Is(err, ErrIdempotencyKeyReused) {
		t.Fatalf("err = %v, want ErrIdempotencyKeyReused", err)
	}

	// Without a key every request is a new transfer.
	a, _, _ := svc.Execute(ctx, req, "")
	b, _, _ := svc.Execute(ctx, req, "")
	if a.ID == b.ID || a.ID == first.ID {
		t.Fatalf("ids %s, %s, %s: want three different transfers", first.ID, a.ID, b.ID)
	}
}
```

Buat juga file baru `transfer/internal/transfer/http_test.go` untuk menguji kode HTTP dari _handler_ dengan `httptest`:

```go
package transfer

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCreateIdempotencyKeyHTTP(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := NewHandler(NewService(newFakeStore(), &fakeAccounts{}, log), log).Routes()
	body := `{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}`

	tests := []struct {
		name       string
		key        string
		body       string
		wantStatus int
		wantBody   string
	}{
		{"new transfer", "k-1", body, http.StatusCreated, `"status":"COMPLETED"`},
		{"same key again", "k-1", body, http.StatusOK, `"id":"1"`},
		{"same key, different body", "k-1", strings.Replace(body, "100000", "1", 1),
			http.StatusUnprocessableEntity, "idempotency key"},
		{"invalid key", "has space", body, http.StatusBadRequest, "Idempotency-Key"},
		{"no key", "", body, http.StatusCreated, `"id":"2"`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/transfers", strings.NewReader(tc.body))
			if tc.key != "" {
				req.Header.Set("Idempotency-Key", tc.key)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus || !strings.Contains(rec.Body.String(), tc.wantBody) {
				t.Fatalf("%d %s, want %d containing %q", rec.Code, rec.Body, tc.wantStatus, tc.wantBody)
			}
		})
	}
}
```

Kasus-kasus di tabel tersebut berjalan berurutan dan berbagi satu _store_, sehingga kasus kedua dapat memeriksa bahwa _key_ `k-1` mengembalikan transfer `1` dari kasus pertama. Jalankan seluruh _test_ dari direktori `studi-kasus`:

#perintah[```bash
make test
```]

== Verifikasi

Hentikan `transfer` dan `notification` dengan `Ctrl+C`, lalu jalankan lagi agar kode dan _schema_ baru berlaku:

#perintah[```bash
make -C transfer run
make -C notification run
```]

=== _Replay_ tanpa notifikasi ganda

Hentikan `notification`, kembalikan _offset_ ke awal, lalu jalankan `notification` lagi:

#perintah[```bash
make replay
make -C notification run
```]

Log `notification` sekarang berisi `duplicate event skipped` untuk setiap _event_ lama, tanpa `notification sent`. Contoh satu baris log (waktu, _offset_, dan ID akan berbeda):

#perintah[```
time=2026-10-28T10:15:02.118+07:00 level=INFO msg="duplicate event skipped" event_type=TransferCompleted partition=1 offset=0 event_id=5b0d... transfer_id=0e2c...
```]

Periksa _event_ yang memiliki lebih dari satu notifikasi:

#perintah[```bash
make duplicates
```]

Pada database yang dibuat dari awal di Lab 6 (misalnya setelah `make infra-reset`), hasilnya kosong:

#perintah[```
 event_id | event_type | notifications
----------+------------+---------------
(0 rows)
```]

Pada database dari Lab 5, daftar tersebut masih berisi duplikat hasil _replay_ di langkah pertama lab ini. Baris-baris tersebut tersimpan sebelum `processed_event` ada; yang perlu dibuktikan adalah jumlah notifikasinya tidak bertambah. Jalankan `make replay` sekali lagi (dengan `notification` dihentikan lebih dahulu), lalu `make duplicates`: angka di kolom `notifications` tetap sama.

=== `Idempotency-Key` di `POST /transfers`

Gunakan `curl -i` agar kode status dan _header_ jawaban terlihat. Kirim transfer dengan sebuah _key_:

#perintah[```bash
curl -i -X POST localhost:8082/transfers \
  -H 'Idempotency-Key: 7f9c2b1e-0d4a-4c1e-9b8f-1a2b3c4d5e6f' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

Jawaban pertama adalah `201 Created` dengan transfer berstatus `COMPLETED` (potongan jawaban; ID dan waktu akan berbeda):

#perintah[```
HTTP/1.1 201 Created
Content-Type: application/json
Location: /transfers/3f1e...
...

{"id":"3f1e...","from_account":"1111111111","to_account":"2222222222","amount":"100000","status":"COMPLETED",...}
```]

Ulangi perintah yang sama persis. Jawabannya sekarang `200 OK` dengan `id` yang sama dan _header_ tambahan:

#perintah[```
HTTP/1.1 200 OK
Content-Type: application/json
Idempotent-Replayed: true
Location: /transfers/3f1e...
...
```]

Log `transfer` mencatat `idempotent replay, returning the original transfer`, dan log `account` tidak mencatat _debit_ baru. Periksa saldo rekening asal: saldo hanya berkurang sekali.

#perintah[```bash
curl localhost:8081/accounts/1111111111
```]

Kirim _key_ yang sama dengan nominal berbeda:

#perintah[```bash
curl -i -X POST localhost:8082/transfers \
  -H 'Idempotency-Key: 7f9c2b1e-0d4a-4c1e-9b8f-1a2b3c4d5e6f' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"5000"}'
```]

Jawabannya `422 Unprocessable Entity`:

#perintah[```
{"error":"idempotency key already used for a different request"}
```]

Nominal `"100000.00"` dengan _key_ yang sama tetap dijawab `200`, karena nominal dibandingkan sebagai desimal. _Key_ yang mengandung spasi, misalnya `-H 'Idempotency-Key: ada spasi'`, dijawab `400` dengan `fields` yang menyebut `Idempotency-Key`.

=== _Request_ paralel dengan _key_ yang sama

Pengujian terakhir mensimulasikan aplikasi yang mengirim ulang _request_ berkali-kali dalam waktu hampir bersamaan. Catat saldo rekening asal, lalu kirim enam _request_ paralel dengan satu _key_ baru:

#perintah[```bash
curl localhost:8081/accounts/1111111111
KEY=$(uuidgen)
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8082/transfers \
    -H "Idempotency-Key: $KEY" \
    -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}' &
done; wait
curl localhost:8081/accounts/1111111111
```]

Bila `uuidgen` tidak tersedia, isi `KEY` dengan teks unik apa saja, misalnya `KEY=paralel-001`. Hasilnya satu `201` dan lima `200`, dengan urutan acak:

#perintah[```
200
201
200
200
200
200
```]

Saldo rekening asal berkurang tepat 100000. _Unique index_ pada `idempotency_key` menjamin hanya satu `insert` yang berhasil; kelima _request_ lain mengambil transfer yang sudah tersimpan. Sebagian dari jawaban `200` tersebut dapat berisi status `PENDING` atau `DEBITED` karena _saga_ dari _request_ pertama belum selesai.

== Masalah Umum

*`make replay` gagal dengan `Assignments can only be reset if the group 'notification' is inactive`.* `notification` masih berjalan, atau baru saja dihentikan dan Kafka belum mencatat bahwa anggota tersebut keluar dari group. Pastikan `notification` sudah berhenti di terminalnya, tunggu beberapa detik, lalu ulangi `make replay`.

*Kompilasi gagal dengan `does not implement Store (wrong type for method Insert)` atau `wrong type for method Create`.* Kontrak `Store` sudah diubah, tetapi `fakeStore` di _test_ belum. Perbarui `fakeStore` di `consumer_test.go` (untuk `notification`) atau `service_test.go` (untuk `transfer`) sesuai bagian _test_ di atas.

*Kompilasi gagal dengan `assignment mismatch: 2 variables but h.svc.Execute returns 3 values`.* Ada pemanggilan `Execute` yang belum diubah. Cari semua pemanggilan dengan `grep -rn "Execute(" transfer/` lalu tambahkan variabel `replayed` (atau `_`) dan argumen _key_.

*Pengulangan dengan _key_ yang sama tetap menghasilkan `201` dan transfer baru.* `transfer` yang berjalan masih versi lama, karena service belum dijalankan ulang setelah kode diubah. Periksa juga penulisan nama _header_ di perintah `curl`: `Idempotency-Key`, dengan tanda hubung.

*`make duplicates` masih menampilkan baris setelah semua langkah selesai.* Baris tersebut berasal dari _replay_ di Lab 5 atau di langkah pertama lab ini, sebelum `processed_event` ada. Selama jumlahnya tidak bertambah setelah _replay_ berikutnya, _consumer_ sudah _idempotent_. Untuk memulai dari database bersih, jalankan `make infra-reset` lalu `make infra-up`; perintah tersebut menghapus semua data lab, termasuk rekening, sehingga rekening contoh perlu dibuat ulang.

*Jawaban `200` berisi status `PENDING`.* Kondisi ini benar. _Request_ pertama dengan _key_ tersebut masih berjalan, dan _request_ pengulangan tidak menunggunya. Periksa `GET /transfers/{id}` beberapa saat kemudian.

*Aplikasi klien mendapat `422` padahal hanya mengulang _request_.* Klien membuat _body_ yang berbeda pada pengulangan, atau menggunakan ulang _key_ untuk transfer baru. Setiap transfer baru harus memiliki _key_ sendiri, dan pengulangan harus mengirim _body_ yang sama.

== Eksplorasi Mandiri

+ *_Crash_ di antara _commit_ database dan _commit offset_.* Tambahkan `time.Sleep(10 * time.Second)` sementara di `Run` (`consumer.go`), tepat sebelum `c.reader.CommitMessages`. Buat satu transfer, tunggu hingga log `notification sent` muncul, lalu hentikan proses `notification` secara paksa sebelum 10 detik berlalu. `go run` menjalankan _binary_ hasil kompilasi sebagai proses anak, sehingga yang dihentikan adalah proses tersebut: `pkill -9 -f exe/notification`. Jalankan lagi `notification` dan amati bahwa _event_ yang sama datang lagi lalu dilewati sebagai duplikat. Hapus kembali `time.Sleep` setelah selesai.
+ *Dua instance `notification`.* Jalankan instance kedua dari direktori `notification` dengan port HTTP lain: salin _environment variable_ dari target `run` di `notification/Makefile`, ganti `HTTP_ADDR=:8093`, lalu jalankan `go run .`. Amati di log bagaimana tiga _partition_ dibagi ke dua anggota group. Hentikan keduanya, jalankan `make replay`, lalu jalankan keduanya lagi. Periksa dengan `make duplicates` bahwa tidak ada notifikasi baru yang ganda.
+ *Lingkup _key_ per klien.* Di lab ini, _key_ berlaku global untuk semua klien. Di _production_, dua klien berbeda boleh secara kebetulan membuat _key_ yang sama, sehingga _unique index_ biasanya dibuat pada pasangan (klien, _key_). Rancang perubahan _schema_ dan kode untuk lingkup tersebut, misalnya dengan _header_ `X-Client-ID` sementara. Di Lab 7, identitas klien akan tersedia dari _token_ OAuth2.
+ *Masa berlaku _key_.* _Key_ di lab ini tidak pernah kedaluwarsa. Sistem pembayaran umumnya menghapus _key_ setelah periode tertentu, misalnya 24 jam. Tulis perintah SQL yang mengosongkan `idempotency_key` untuk transfer yang lebih tua dari 24 jam, lalu jelaskan apa yang terjadi bila klien mengulang _request_ setelah _key_-nya dihapus.

== Checkpoint

Kondisi kode di akhir lab ini tersedia di tag `lab-06`. Bandingkan hasil kerja dengan tag tersebut, atau lanjutkan langsung dari tag tersebut bila tertinggal:

#perintah[```bash
git diff lab-06 -- .
git switch -c lab-07-kerja lab-06
```]
