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
                                   transfer asli, kode HTTP
                                   sama dengan request pertama
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
--
-- A separate table, not a unique index on notification.event_id: the dedup rule
-- is "this event was handled", which also covers events that produce no row
-- or several rows. It also keeps the duplicate notifications of Lab 5 as they
-- are instead of failing the index creation on them.
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

Di `notification/internal/notification/consumer.go`, fungsi `handle` memanggil `Insert`. Sesuaikan isi perulangan `for` di bagian akhir `handle` dengan tiga nilai kembalian yang baru. Cabang `permanentDBError` dari Lab 5 tetap ada di antara jalur berhasil dan jalur _retry_:

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

`fakeStore` di `notification/internal/notification/consumer_test.go` mengimplementasikan `Store`, sehingga harus mengikuti kontrak baru. Ganti `fakeStore` dan fungsi `Insert`-nya dengan versi yang mengingat `event_id`. _Field_ `reject` dan `inserts` dari Lab 5 tetap dipertahankan karena digunakan oleh _test_ _poison message_:

```go
// fakeStore fails the first failures inserts, then stores each event once. An
// insert for an event ID in reject fails with that error on every try.
type fakeStore struct {
	rows      []Notification
	processed map[string]bool
	failures  int
	reject    map[string]error
	inserts   int
}

func (f *fakeStore) Insert(_ context.Context, n Notification) (Notification, bool, error) {
	f.inserts++
	if err := f.reject[n.EventID]; err != nil {
		return Notification{}, false, err
	}
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

_Test_ `TestConsumerIsNotIdempotentYet` dari Lab 5 mendokumentasikan celah yang sekarang sudah ditutup. Ganti _test_ tersebut dengan _test_ yang membuktikan perilaku baru: empat _event_ masuk, dua di antaranya duplikat, hasilnya dua notifikasi dan keempat _offset_ tetap di-_commit_. _Test_ ini menggunakan konstanta `eventID1` dan `eventID2` yang sudah ada sejak Lab 5. ID seperti `e-1` tidak dapat digunakan karena `handle` melewati _event_ dengan `event_id` yang bukan UUID.

```go
// The same event delivered twice (relay duplicate or replay) becomes one
// notification, and both deliveries are committed.
func TestConsumerSkipsDuplicates(t *testing.T) {
	store := &fakeStore{}
	reader := runConsumer(t, store,
		event(0, "TransferCompensated", eventID1),
		event(1, "TransferCompleted", eventID2),
		event(0, "TransferCompensated", eventID1), // replay from the start
		event(1, "TransferCompleted", eventID2),
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

Tiga hal ditambahkan di `transfer/internal/transfer/transfer.go`: dua _error_ baru, fungsi pembanding _request_, dan validasi format _key_.

Tambahkan `ErrIdempotencyKeyReused` dan `ErrInProgress` di dalam blok `var (...)`, tepat setelah `ErrStaleState`:

```go
	// ErrIdempotencyKeyReused: the Idempotency-Key was used before for a
	// different transfer. Most likely a client bug (a key reused for a new
	// request); executing it would silently drop one of the two.
	ErrIdempotencyKeyReused = errors.New("idempotency key already used for a different request")
	// ErrInProgress: an Idempotency-Key replay found the original transfer still
	// PENDING or DEBITED.
	ErrInProgress = errors.New("transfer still in progress")
```

`ErrIdempotencyKeyReused` dikembalikan ketika _key_ yang sama datang dengan isi berbeda. `ErrInProgress` dikembalikan ketika pengulangan menemukan transfer asli yang belum selesai; _handler_ menerjemahkannya menjadi `202 Accepted`.

Setelah blok `var (...)` tersebut, tambahkan `SameRequest`. Ketika _key_ yang sama datang lagi, `transfer` harus memastikan bahwa _request_ tersebut memang pengulangan, bukan transfer baru yang secara keliru menggunakan _key_ lama. Nominal dibandingkan sebagai desimal dengan `Equal`, sehingga `"100000"` dan `"100000.00"` dianggap sama.

```go
// SameRequest reports whether t was created from req: the check behind an
// Idempotency-Key that comes again. Decimal comparison, so "100000" and
// "100000.00" are the same amount.
func (t Transfer) SameRequest(req CreateRequest) bool {
	return t.FromAccount == req.FromAccount && t.ToAccount == req.ToAccount && t.Amount.Equal(req.Amount)
}
```

Setelah deklarasi `maxAmount` (di bawah `numberPattern`), tambahkan validasi _key_. Batas 100 karakter mengikuti ukuran kolom, dan karakter yang diizinkan hanya ASCII yang dapat dicetak tanpa spasi (`\x21`–`\x7e`):

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

Fungsi `Execute` di `transfer/internal/transfer/service.go` sekarang menerima _key_ dan mengembalikan nilai tambahan `replayed`. Bagian _saga_ (_debit_, _credit_, kompensasi) tidak berubah, hanya dipindahkan ke fungsi baru `run`. Tambahkan `"strings"` ke daftar _import_, lalu ganti _signature_ dan bagian awal `Execute`, hingga dan termasuk baris `if err := s.accounts.Debit(...)`, menjadi:

```go
//
// idempotencyKey (optional, from the Idempotency-Key header) makes a retried
// request safe: when the key was seen before, the saga does not run again and
// the original transfer is returned in whatever state it is now, with the
// second result (replayed) true. The error is then the one the original request
// ended with (see replayOutcome), so the HTTP layer answers the replay with the
// same status code. A request still in progress comes back as PENDING or
// DEBITED with ErrInProgress; the client polls GET /transfers/{id}.
//
// A row left PENDING or DEBITED by a crash (SIGKILL between two steps) is never
// resumed: nothing in this lab picks it up again (see the gap in the Lab 5
// README). A replay of its key keeps returning that state with ErrInProgress.
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
		return t, true, replayOutcome(t)
	}
	t, err = s.run(ctx, t)
	return t, false, err
}

// replayOutcome rebuilds, from the stored transfer, the error the original
// request ended with: nil for COMPLETED, ErrReversalFailed for
// COMPENSATION_FAILED, ErrInProgress for PENDING and DEBITED. For FAILED and
// COMPENSATED the cause is only kept as text in failure_reason ("debit failed:
// debit 1111111111: insufficient funds"); the account client wraps the
// sentinels last, so the reason ends with the sentinel's message. Anything else
// was a dependency failure, the 502 of the original request.
func replayOutcome(t Transfer) error {
	switch t.Status {
	case Completed:
		return nil
	case Pending, Debited:
		return ErrInProgress
	case CompensationFailed:
		return fmt.Errorf("%w: %s", ErrReversalFailed, t.FailureReason)
	}
	for _, cause := range []error{ErrAccountNotFound, ErrInsufficientFunds, ErrAccountUnavailable} {
		if strings.HasSuffix(t.FailureReason, ": "+cause.Error()) {
			return fmt.Errorf("%s: %w", t.Status, cause)
		}
	}
	return fmt.Errorf("%s: %s", t.Status, t.FailureReason)
}

// run executes the saga steps on a freshly recorded transfer.
func (s *Service) run(ctx context.Context, t Transfer) (Transfer, error) {

	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
```

Sisa isi fungsi lama, mulai dari penanganan _error_ `Debit` hingga akhir, tetap seperti semula dan sekarang menjadi isi `run`. Komentar di atas fungsi yang menjelaskan langkah _saga_ tetap dipertahankan; paragraf `idempotencyKey` di atas ditambahkan di bawahnya.

Perhatikan bahwa jawaban untuk pengulangan berisi transfer asli dengan status saat ini, ditambah _error_ yang sama dengan hasil _request_ pertama. _Error_ tersebut disusun ulang oleh `replayOutcome` dari data yang tersimpan, sehingga _handler_ dapat menjawab pengulangan dengan kode HTTP yang sama, kecuali bila status akhir _request_ pertama gagal disimpan. Klien yang kehilangan jawaban pertama lalu mengulang _request_ mengambil keputusan yang sama seperti bila jawaban pertama sampai.

Untuk status `FAILED` dan `COMPENSATED`, satu-satunya catatan penyebab kegagalan adalah teks di kolom `failure_reason`. `replayOutcome` memeriksa apakah teks tersebut diakhiri pesan salah satu _sentinel error_, misalnya `: insufficient funds`. Cara ini bergantung pada format teks dan cukup untuk lab. Rancangan di _production_ menyimpan kode kegagalan di kolom tersendiri.

Bila _request_ pertama masih berjalan, misalnya sedang menunggu `account`, _request_ kedua menerima status `PENDING` atau `DEBITED` bersama `ErrInProgress`. _Saga_ tidak dijalankan untuk kedua kalinya; klien cukup memeriksa `GET /transfers/{id}` hingga statusnya final. Celah dari Lab 5 tetap berlaku: transfer yang tertinggal di `PENDING` atau `DEBITED` karena proses `transfer` mati di antara dua langkah tidak pernah dilanjutkan, sehingga pengulangan dengan _key_ tersebut terus menerima status yang sama.

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

Pemilihan kode HTTP dari Lab 5 sekarang digunakan oleh dua jalur: _request_ pertama dan pengulangan. Karena itu, blok `switch` lama dipindahkan dari `create` ke fungsi baru `createStatus`. Ganti bagian `create` mulai dari komentar `WithoutCancel` di atas pemanggilan `Execute` hingga akhir fungsi, lalu tambahkan `createStatus` di bawahnya:

```go
	// WithoutCancel: a client that disconnects must not abort a transfer halfway,
	// e.g. between the debit and the credit.
	t, replayed, err := h.svc.Execute(context.WithoutCancel(r.Context()), req, key)
	switch {
	case errors.Is(err, ErrIdempotencyKeyReused):
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	case t.ID == "":
		h.internalError(w, r, err)
		return
	}
	if replayed {
		// A replay answers with the status code the original request got for the
		// stored state, so a client whose first response was lost decides the same
		// way. The header tells it nothing was executed this time.
		w.Header().Set("Idempotent-Replayed", "true")
	}
	status := createStatus(err)
	if status == http.StatusCreated || status == http.StatusAccepted {
		w.Header().Set("Location", "/transfers/"+t.ID)
	}
	writeJSON(w, status, t)
}

// createStatus maps the outcome of a recorded transfer to the HTTP status of
// POST /transfers, for a first request and a replay alike.
func createStatus(err error) int {
	switch {
	case err == nil:
		return http.StatusCreated
	case errors.Is(err, ErrInProgress):
		// Replay only: the original request is still running (or was cut off by a
		// crash, see Service.Execute).
		return http.StatusAccepted
	case errors.Is(err, ErrReversalFailed):
		// Checked first: the source account is debited and the reversal did not go
		// through (COMPENSATION_FAILED, also when that state itself could not be
		// stored). Money is stuck on our side, whatever the account service
		// answered: this is our failure, not the caller's, and never a 503 or 422
		// that would invite a retry.
		return http.StatusInternalServerError
	case errors.Is(err, ErrAccountNotFound), errors.Is(err, ErrInsufficientFunds):
		// Includes COMPENSATED when the destination account does not exist.
		return http.StatusUnprocessableEntity
	case errors.Is(err, ErrAccountUnavailable):
		// The open breaker refused the debit (FAILED), or refused the credit and the
		// debit was reversed (COMPENSATED). Either way no money moved: 503 tells the
		// caller it is safe to come back later.
		return http.StatusServiceUnavailable
	default:
		// Recorded but not completed because a dependency failed (FAILED or
		// COMPENSATED).
		return http.StatusBadGateway
	}
}
```

Isi `createStatus` sama dengan `switch` dari Lab 5; perbedaannya, setiap `case` mengembalikan kode HTTP alih-alih menulis jawaban, dan ada satu `case` baru untuk `ErrInProgress`. Dua kondisi tetap ditangani langsung di `create` karena tidak memiliki transfer untuk dikembalikan: _key_ yang digunakan ulang dengan _body_ berbeda, dan kegagalan sebelum transfer tersimpan (`t.ID == ""`).

Kode HTTP untuk pengulangan dengan _key_ yang sama:

#table(
  columns: (auto, 1fr),
  [Status Transfer yang Tersimpan], [Kode HTTP Pengulangan],
  [`COMPLETED`], [201 Created, sama dengan _request_ pertama],
  [`FAILED` atau `COMPENSATED`], [422, 503, atau 502, sesuai penyebab kegagalan di `failure_reason`],
  [`COMPENSATION_FAILED`], [500 Internal Server Error],
  [`PENDING` atau `DEBITED`], [202 Accepted: _request_ pertama masih berjalan (atau terhenti oleh _crash_ atau oleh kegagalan menyimpan status)],
)

Setiap jawaban pengulangan membawa _header_ `Idempotent-Replayed: true`, yang memberi tahu klien bahwa kali ini tidak ada yang dijalankan. _Header_ `Location` hanya diisi pada jawaban 201 dan 202. Kondisi lain di luar tabel:

- *422 Unprocessable Entity* ketika _key_ yang sama datang dengan _body_ berbeda. Kemungkinan besar kondisi ini adalah _bug_ di klien yang menggunakan _key_ lama untuk transfer baru. Menjalankannya berarti salah satu dari dua transfer tersebut hilang tanpa diketahui klien.
- *400 Bad Request* ketika format _key_ tidak valid.

Pengulangan sengaja tidak dijawab dengan kode tersendiri seperti `200 OK`. Klien yang tidak menerima jawaban pertama harus dapat mengambil keputusan dari jawaban kedua dengan aturan yang sama: 201 berarti transfer selesai, 503 berarti tidak ada dana yang berpindah, 500 berarti dana tertahan dan perlu penanganan manual. Transfer yang tersimpan dengan status `FAILED` atau `COMPENSATED` sudah final. Pengulangan dengan _key_ yang sama selalu mengembalikan hasil yang sama, sehingga klien yang ingin mencoba lagi setelah 503 mengirim transfer baru dengan _key_ baru.

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

Tambahkan juga _test_ untuk `replayOutcome`. _Test_ ini memeriksa bahwa setiap kombinasi status dan `failure_reason` menghasilkan _sentinel error_ yang sama dengan _request_ pertama, dan bahwa kegagalan jaringan tidak cocok dengan `ErrAccountNotFound`, `ErrInsufficientFunds`, maupun `ErrAccountUnavailable`, sehingga tetap dijawab 502:

```go
// TestReplayOutcome: a replay gets back the error class of the original
// request, rebuilt from the stored status and failure_reason.
func TestReplayOutcome(t *testing.T) {
	tests := []struct {
		status Status
		reason string
		want   error
	}{
		{Completed, "", nil},
		{Pending, "", ErrInProgress},
		{Debited, "", ErrInProgress},
		{Failed, "debit failed: debit 1111111111: insufficient funds", ErrInsufficientFunds},
		{Failed, "debit failed: debit 1111111111: account service unavailable", ErrAccountUnavailable},
		{Compensated, "credit failed: credit 9999999999: account not found", ErrAccountNotFound},
		{Compensated, "credit failed: credit 2222222222: account service unavailable", ErrAccountUnavailable},
		{CompensationFailed, "credit failed: x; reversal failed: y", ErrReversalFailed},
	}
	for _, tc := range tests {
		err := replayOutcome(Transfer{Status: tc.status, FailureReason: tc.reason})
		if !errors.Is(err, tc.want) || (tc.want == nil && err != nil) {
			t.Errorf("%s %q: err = %v, want %v", tc.status, tc.reason, err, tc.want)
		}
	}
	// A transport failure maps to none of the sentinels: the 502 of the original.
	err := replayOutcome(Transfer{Status: Failed, FailureReason: "debit failed: debit 1111111111: rpc error: code = Unavailable"})
	for _, s := range []error{ErrAccountNotFound, ErrInsufficientFunds, ErrAccountUnavailable, ErrReversalFailed, ErrInProgress} {
		if err == nil || errors.Is(err, s) {
			t.Fatalf("transport failure: err = %v, want a plain error", err)
		}
	}
}
```

_Test_ kode HTTP sudah ada sejak Lab 3 di `transfer/internal/transfer/http_test.go` (`TestCreateStatus`). Di Lab 6, file tersebut mendapat tiga perubahan.

Pertama, tambahkan `"github.com/shopspring/decimal"` ke daftar _import_, lalu tambahkan fungsi bantu `post` di bawah `fails`. Fungsi ini mengirim `POST /transfers` dengan _header_ `Idempotency-Key`:

```go
func post(t *testing.T, url, key string) *http.Response {
	t.Helper()
	body := `{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}`
	req, err := http.NewRequest(http.MethodPost, url+"/transfers", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Idempotency-Key", key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp
}
```

Kedua, `TestCreateStatus` menjalankan setiap kasus dua kali dengan _key_ yang sama. Pengulangan harus menghasilkan kode HTTP yang sama, membawa `Idempotent-Replayed: true`, dan tidak memanggil `account` lagi. Tambahkan paragraf berikut di akhir komentar di atas `TestCreateStatus`:

```go
//
// The same cases run twice with an Idempotency-Key: the replay must answer with
// the status of the first request, plus Idempotent-Replayed: true, without
// calling the account service again.
```

Lalu ganti isi `t.Run` di dalam perulangan kasus:

```go
		t.Run(tc.name, func(t *testing.T) {
			log := slog.New(slog.NewTextHandler(io.Discard, nil))
			svc := NewService(newFakeStore(), tc.accounts, log)
			srv := httptest.NewServer(NewHandler(svc, log).Routes())
			defer srv.Close()

			first := post(t, srv.URL, "k-1")
			if first.StatusCode != tc.want || first.Header.Get("Idempotent-Replayed") != "" {
				t.Fatalf("first: status = %d, replayed = %q, want %d", first.StatusCode, first.Header.Get("Idempotent-Replayed"), tc.want)
			}
			calls := len(tc.accounts.calls)
			replay := post(t, srv.URL, "k-1")
			if replay.StatusCode != tc.want || replay.Header.Get("Idempotent-Replayed") != "true" {
				t.Fatalf("replay: status = %d, replayed = %q, want %d, true", replay.StatusCode, replay.Header.Get("Idempotent-Replayed"), tc.want)
			}
			if len(tc.accounts.calls) != calls {
				t.Fatalf("account calls = %q, want none for the replay", tc.accounts.calls[calls:])
			}
		})
```

Dengan perubahan ini, setiap baris tabel `TestCreateStatus` (201, 422, 503, 502, 500) sekaligus membuktikan bahwa `replayOutcome` menyusun ulang penyebab kegagalan dengan benar.

Ketiga, tambahkan _test_ baru di akhir file untuk perilaku khusus _header_:

```go
func TestCreateIdempotencyKeyHTTP(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	store := newFakeStore()
	h := NewHandler(NewService(store, &fakeAccounts{}, log), log).Routes()
	body := `{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}`

	// A transfer whose first request is still running (or was cut off by a crash).
	store.transfers["99"] = Transfer{ID: "99", FromAccount: "1111111111", ToAccount: "2222222222",
		Amount: decimal.RequireFromString("100000"), Status: Debited}
	store.keys["k-running"] = "99"

	tests := []struct {
		name         string
		key          string
		body         string
		wantStatus   int
		wantBody     string
		wantReplayed string
	}{
		{"new transfer", "k-1", body, http.StatusCreated, `"status":"COMPLETED"`, ""},
		{"same key again", "k-1", body, http.StatusCreated, `"id":"1"`, "true"},
		{"same key, still in progress", "k-running", body, http.StatusAccepted, `"status":"DEBITED"`, "true"},
		{"same key, different body", "k-1", strings.Replace(body, "100000", "1", 1),
			http.StatusUnprocessableEntity, "idempotency key", ""},
		{"invalid key", "has space", body, http.StatusBadRequest, "Idempotency-Key", ""},
		{"no key", "", body, http.StatusCreated, `"id":"2"`, ""},
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
			if got := rec.Header().Get("Idempotent-Replayed"); got != tc.wantReplayed {
				t.Fatalf("Idempotent-Replayed = %q, want %q", got, tc.wantReplayed)
			}
		})
	}
}
```

Transfer `99` berstatus `DEBITED` dimasukkan langsung ke _store_ untuk meniru _request_ pertama yang belum selesai, sehingga jalur 202 dapat diuji tanpa _goroutine_ paralel. Kasus-kasus lain di tabel berjalan berurutan dan berbagi satu _store_, sehingga kasus kedua dapat memeriksa bahwa _key_ `k-1` mengembalikan transfer `1` dari kasus pertama dengan kode 201. Jalankan seluruh _test_ dari direktori `studi-kasus`:

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

Ulangi perintah yang sama persis. Kode HTTP-nya tetap `201 Created`, karena transfer asli berstatus `COMPLETED`, tetapi jawabannya membawa _header_ tambahan dan `id` yang sama:

#perintah[```
HTTP/1.1 201 Created
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

Nominal `"100000.00"` dengan _key_ yang sama tetap dianggap pengulangan (`201` dengan `Idempotent-Replayed: true`), karena nominal dibandingkan sebagai desimal. _Key_ yang mengandung spasi, misalnya `-H 'Idempotency-Key: ada spasi'`, dijawab `400` dengan `fields` yang menyebut `Idempotency-Key`.

Pengulangan juga mempertahankan kode HTTP untuk transfer yang gagal. Kirim transfer ke rekening tujuan yang tidak ada dengan _key_ baru, dua kali:

#perintah[```bash
for i in 1 2; do
  curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8082/transfers \
    -H 'Idempotency-Key: gagal-001' \
    -d '{"from_account":"1111111111","to_account":"9999999999","amount":"100000"}'
done
```]

Kedua jawaban adalah `422`. _Request_ pertama menjalankan _debit_, gagal di _credit_, lalu membalikkan _debit_ (status `COMPENSATED`, `failure_reason` diakhiri `account not found`). _Request_ kedua tidak menjalankan apa pun; `replayOutcome` membaca `failure_reason` tersebut dan menghasilkan kode yang sama.

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

Bila `uuidgen` tidak tersedia, isi `KEY` dengan teks unik apa saja, misalnya `KEY=paralel-001`. Setiap jawaban berupa `201` atau `202`, dengan urutan dan jumlah yang berbeda pada setiap percobaan, misalnya:

#perintah[```
202
201
202
202
201
202
```]

Saldo rekening asal berkurang tepat 100000. _Unique index_ pada `idempotency_key` menjamin hanya satu `insert` yang berhasil; kelima _request_ lain mengambil transfer yang sudah tersimpan. `202 Accepted` adalah jawaban pengulangan yang tiba ketika _saga_ dari _request_ pertama belum selesai, sehingga transfer masih berstatus `PENDING` atau `DEBITED`. Pengulangan yang tiba setelah _saga_ selesai menerima `201`, sama dengan _request_ pertama. Dari kode HTTP saja, _request_ pertama tidak dapat dibedakan dari pengulangan; pembedanya adalah _header_ `Idempotent-Replayed: true` yang hanya ada pada pengulangan.

== Masalah Umum

*`make replay` gagal dengan `Assignments can only be reset if the group 'notification' is inactive, but the current state is Stable`.* `notification` masih berjalan, atau baru saja dihentikan dan Kafka belum mencatat bahwa anggota tersebut keluar dari _group_. Dengan `Ctrl+C`, `reader.Close()` langsung mengeluarkan `notification` dari _consumer group_. Bila proses mati tanpa sempat menutup _reader_ (misalnya `kill -9` atau terminal ditutup), Kafka baru mengeluarkan anggota tersebut setelah _session timeout_ habis, sekitar 30 detik. Pastikan `notification` sudah berhenti di terminalnya, tunggu hingga _session timeout_ lewat bila perlu, lalu ulangi `make replay`.

*Kompilasi gagal dengan `does not implement Store (wrong type for method Insert)` atau `wrong type for method Create`.* Kontrak `Store` sudah diubah, tetapi `fakeStore` di _test_ belum. Perbarui `fakeStore` di `consumer_test.go` (untuk `notification`) atau `service_test.go` (untuk `transfer`) sesuai bagian _test_ di atas.

*Kompilasi gagal dengan `assignment mismatch: 2 variables but h.svc.Execute returns 3 values`.* Ada pemanggilan `Execute` yang belum diubah. Cari semua pemanggilan dengan `grep -rn "Execute(" transfer/` lalu tambahkan variabel `replayed` (atau `_`) dan argumen _key_.

*Pengulangan dengan _key_ yang sama menghasilkan transfer baru dengan `id` berbeda, tanpa _header_ `Idempotent-Replayed`.* `transfer` yang berjalan masih versi lama, karena service belum dijalankan ulang setelah kode diubah. Periksa juga penulisan nama _header_ di perintah `curl`: `Idempotency-Key`, dengan tanda hubung.

*`make duplicates` masih menampilkan baris setelah semua langkah selesai.* Baris tersebut berasal dari _replay_ di Lab 5 atau di langkah pertama lab ini, sebelum `processed_event` ada. Selama jumlahnya tidak bertambah setelah _replay_ berikutnya, _consumer_ sudah _idempotent_. Untuk memulai dari database bersih, jalankan `make infra-reset` lalu `make infra-up`; perintah tersebut menghapus semua data lab, termasuk rekening, sehingga rekening contoh perlu dibuat ulang.

*Pengulangan dijawab `202 Accepted` dengan status `PENDING` atau `DEBITED`.* Kondisi ini benar. _Request_ pertama dengan _key_ tersebut masih berjalan, dan _request_ pengulangan tidak menunggunya. Periksa `GET /transfers/{id}` (alamatnya ada di _header_ `Location`) beberapa saat kemudian. Bila statusnya tidak pernah berubah, proses `transfer` mati di tengah _saga_, atau status berikutnya gagal disimpan (log `debit applied but not recorded` atau `saga end state not recorded`). Transfer tersebut tidak dilanjutkan oleh siapa pun di lab ini, sehingga pengulangan terus dijawab `202`, walaupun _request_ pertama mungkin menerima kode lain.

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
