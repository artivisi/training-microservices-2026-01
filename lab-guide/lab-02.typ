#import "../_template/panduan.typ": note, perintah

= Lab 2: Transfer Service dan Panggilan REST Antar-Service

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

- menambahkan operasi debit dan kredit pada account service, lengkap dengan catatan mutasi dan pemeriksaan saldo yang aman terhadap _concurrent request_;
- membuat service kedua, transfer service, sebagai modul Go terpisah dengan database sendiri (_database-per-service_);
- memanggil account service dari transfer service melalui REST dengan `net/http`;
- memetakan respons HTTP dari service lain menjadi _error_ bisnis yang dapat diperiksa dengan `errors.Is`;
- mengenali dua kelemahan yang sengaja dibiarkan pada lab ini: _HTTP client_ tanpa _timeout_ dan debit yang tidak dikembalikan ketika kredit gagal.

== Gambaran

Sampai akhir Lab 1, sistem hanya berisi account service dengan database `account`. Lab 2 menambahkan transfer service. Transfer memindahkan sejumlah uang dari rekening sumber ke rekening tujuan. Data rekening dan saldo tetap dimiliki account service, sehingga transfer service tidak boleh membaca atau mengubah tabel `account` secara langsung. Satu-satunya jalan adalah memanggil API milik account service.

```
                 POST /transfers
  klien ───────────────────────────▶ transfer service (:8082)
                                       │  1. simpan transfer (PENDING)
                                       │  2. POST /accounts/{sumber}/debit
                                       │  3. POST /accounts/{tujuan}/credit
                                       │  4. ubah status: COMPLETED / FAILED
                                       ▼
                                     account service (:8081)
                                       │
          ┌────────────────────┐       │       ┌────────────────────┐
          │ db-transfer :15433 │◀── transfer   │ db-account :15432  │
          │ tabel transfer     │       └──────▶│ account, mutation  │
          └────────────────────┘               └────────────────────┘
```

Setiap service memiliki database sendiri di _container_ PostgreSQL yang berbeda. Konsekuensinya, debit dan kredit tidak dapat dibungkus dalam satu transaksi database. Debit terjadi di account service, status transfer tersimpan di transfer service, dan di antara keduanya ada jaringan. Lab ini sengaja membangun versi paling sederhana dari alur tersebut supaya kelemahannya terlihat jelas:

- *Tanpa _timeout_.* Jika account service lambat, setiap transfer ikut menunggu tanpa batas. Lab 3 menambahkan _timeout_, _retry_, dan _circuit breaker_.
- *Tanpa kompensasi.* Jika debit berhasil lalu kredit gagal, uang sudah keluar dari rekening sumber tetapi tidak masuk ke rekening tujuan. Transfer ditandai `FAILED` dan dicatat di _log_ untuk dikoreksi manual. Lab 5 menyelesaikan masalah ini dengan pola _saga_.

Perubahan pada lab ini terbagi dua bagian. Bagian pertama melengkapi account service dengan _endpoint_ debit dan kredit. Bagian kedua membangun transfer service dari awal.

== Titik Awal

Lab ini dimulai dari _checkpoint_ `lab-01`. Peserta yang sudah menyelesaikan Lab 1 dapat melanjutkan dari kode sendiri. Peserta yang tertinggal atau ingin memulai dari kondisi yang bersih dapat membuat _branch_ kerja dari tag `lab-01`:

#perintah[```bash
cd training-microservices-2026-01
git switch -c kerja-lab-02 lab-01
cd studi-kasus
make infra-up
```]

Seluruh perintah pada lab ini dijalankan dari folder `studi-kasus/`, kecuali disebutkan lain. Pastikan account service dari Lab 1 masih dapat dijalankan dengan `make -C account run` sebelum melanjutkan.

== Langkah

=== Tabel mutasi pada account service

Saldo rekening disimpan pada kolom `balance` di tabel `account`. Jika debit dan kredit hanya mengubah angka tersebut, tidak ada jejak tentang asal perubahan saldo. Sistem perbankan selalu menyimpan setiap mutasi sebagai baris tersendiri, sehingga saldo dapat ditelusuri kembali ke transaksi yang menyebabkannya. Kolom `reference` mengaitkan mutasi dengan transaksi bisnis pemicunya, dalam hal ini ID transfer.

Tambahkan definisi tabel berikut di akhir `account/internal/account/schema.sql`, setelah tabel `account`:

```sql
-- Every balance change is recorded; the balance column is the running total.
create table if not exists mutation (
    id             bigint generated always as identity primary key,
    account_number varchar(10)    not null references account (number),
    type           varchar(6)     not null check (type in ('DEBIT', 'CREDIT')),
    amount         numeric(19, 2) not null check (amount > 0),
    reference      varchar(64)    not null,
    created_at     timestamptz    not null default now()
);
```

Schema diterapkan otomatis ketika account service dijalankan (Lab 1 menggunakan `create table if not exists`), sehingga tabel baru langsung terbentuk pada _startup_ berikutnya tanpa menghapus data lama.

=== Model mutasi dan kontrak `Store`

Debit dan kredit memiliki bentuk _request_ yang sama: jumlah uang dan referensi. Perbedaannya hanya arah perubahan saldo, sehingga cukup satu tipe _request_ dan satu tipe `MutationType`.

Pada `account/internal/account/account.go`, tambahkan kode berikut tepat setelah definisi `CreateRequest`:

```go
// MutationRequest is the body of a debit or credit. Reference ties the mutation to
// the business transaction that caused it, e.g. a transfer ID.
type MutationRequest struct {
	Amount    decimal.Decimal `json:"amount"`
	Reference string          `json:"reference"`
}

type MutationType string

const (
	Debit  MutationType = "DEBIT"
	Credit MutationType = "CREDIT"
)
```

Saldo yang tidak mencukupi adalah penolakan bisnis, bukan kegagalan teknis. Penolakan ini perlu _error_ tersendiri supaya _handler_ dapat menjawab dengan status yang tepat. Ubah blok `var` yang berisi _error_ menjadi:

```go
var (
	ErrNotFound          = errors.New("account not found")
	ErrAlreadyExists     = errors.New("account already exists")
	ErrInsufficientFunds = errors.New("insufficient funds")
)
```

Validasi _request_ mutasi diletakkan setelah method `CreateRequest.Validate`. Jumlah harus positif, dan referensi wajib diisi dengan panjang maksimal 64 karakter sesuai kolom `reference`:

```go
func (r MutationRequest) Validate() error {
	v := ValidationError{}
	if !r.Amount.IsPositive() {
		v["amount"] = "must be greater than zero"
	}
	if strings.TrimSpace(r.Reference) == "" || len(r.Reference) > 64 {
		v["reference"] = "must be 1 to 64 characters"
	}
	if len(v) > 0 {
		return v
	}
	return nil
}
```

Terakhir, tambahkan method `Mutate` ke _interface_ `Store`, di antara `List` dan `Ping`:

```go
	// Mutate debits or credits the account and records the mutation, atomically.
	// It returns the account with its new balance.
	Mutate(ctx context.Context, number string, t MutationType, req MutationRequest) (Account, error)
```

=== Implementasi `Mutate` di PostgreSQL

Perubahan saldo dan pencatatan mutasi harus terjadi bersama-sama: keduanya berhasil atau keduanya batal. Karena itu `Mutate` menggunakan satu transaksi database.

Bagian yang paling penting adalah pemeriksaan saldo. Cara yang sekilas tampak wajar adalah membaca saldo dengan `select`, membandingkannya di Go, lalu menjalankan `update`. Cara tersebut rawan _race condition_: dua debit yang datang bersamaan dapat sama-sama membaca saldo lama, sama-sama lolos pemeriksaan, lalu sama-sama mengurangi saldo. Solusinya adalah meletakkan pemeriksaan saldo di klausa `where` pada perintah `update`. PostgreSQL mengunci baris yang sedang diubah. Debit kedua menunggu kunci tersebut dilepas, lalu mengevaluasi ulang kondisi `where` terhadap saldo terbaru.

Jika `update` tidak mengubah satu baris pun, ada dua kemungkinan: nomor rekening tidak ada, atau saldo tidak mencukupi. Kode membedakan keduanya dengan membaca rekening melalui `Get`.

Tambahkan method berikut ke `account/internal/account/store.go`, setelah method `Get`:

```go
func (s *PostgresStore) Mutate(ctx context.Context, number string, t MutationType, req MutationRequest) (Account, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Account{}, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

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
		return Account{}, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
	if errors.Is(err, pgx.ErrNoRows) {
		// Nothing updated: either the account does not exist or the balance is too low.
		if _, getErr := s.Get(ctx, number); getErr != nil {
			return Account{}, getErr
		}
		return Account{}, ErrInsufficientFunds
	}
	if err != nil {
		return Account{}, err
	}

	if _, err := tx.Exec(ctx, `
		insert into mutation (account_number, type, amount, reference)
		values (@number, @type, @amount, @reference)`,
		pgx.NamedArgs{"number": number, "type": string(t), "amount": req.Amount, "reference": req.Reference}); err != nil {
		return Account{}, err
	}
	return a, tx.Commit(ctx)
}
```

`defer tx.Rollback(ctx)` menjamin transaksi dibatalkan pada setiap jalur `return` yang membawa _error_. Setelah `Commit` berhasil, pemanggilan `Rollback` tidak berpengaruh apa-apa.

=== Endpoint debit dan kredit

Account service kini membutuhkan dua _endpoint_ baru: `POST /accounts/{number}/debit` dan `POST /accounts/{number}/credit`. Logika keduanya identik kecuali `MutationType`, sehingga satu fungsi pembuat _handler_ cukup untuk keduanya.

Kode pembacaan JSON dari Lab 1 juga akan dibutuhkan oleh _handler_ baru. Pindahkan kode tersebut ke fungsi `decode` supaya tidak ditulis dua kali. Tambahkan fungsi berikut di `account/internal/account/http.go`, tepat sebelum `writeError`:

```go
// decode reads a JSON body into dst and answers 400 itself when the body is invalid.
func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	return true
}
```

Lalu ganti awal method `create` sehingga menggunakan `decode`:

```go
func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req CreateRequest
	if !decode(w, r, &req) {
		return
	}
	// ... validasi dan penyimpanan tetap seperti Lab 1
```

Tambahkan _handler_ mutasi setelah method `get`. Pemetaan _error_ ke status HTTP menjadi kontrak bagi pemanggil: `404` berarti rekening tidak ada, `422 Unprocessable Entity` berarti saldo tidak mencukupi, dan `500` berarti kegagalan teknis.

```go
func (h *Handler) mutate(t MutationType) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req MutationRequest
		if !decode(w, r, &req) {
			return
		}
		if err := req.Validate(); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "fields": err})
			return
		}
		a, err := h.store.Mutate(r.Context(), r.PathValue("number"), t, req)
		switch {
		case errors.Is(err, ErrNotFound):
			writeError(w, http.StatusNotFound, err.Error())
		case errors.Is(err, ErrInsufficientFunds):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		case err != nil:
			h.internalError(w, r, err)
		default:
			h.log.Info("account mutated", "number", a.Number, "type", t, "amount", req.Amount, "reference", req.Reference)
			writeJSON(w, http.StatusOK, a)
		}
	}
}
```

Daftarkan kedua _route_ di method `Routes`, setelah `GET /accounts/{number}`:

```go
	mux.HandleFunc("POST /accounts/{number}/debit", h.mutate(Debit))
	mux.HandleFunc("POST /accounts/{number}/credit", h.mutate(Credit))
```

=== Pengujian account service

Test _handler_ dari Lab 1 menggunakan `fakeStore`, implementasi `Store` di memori. Karena _interface_ `Store` kini memiliki method `Mutate`, `fakeStore` tidak lagi memenuhi _interface_ tersebut dan test gagal dikompilasi. Tambahkan method berikut di `account/internal/account/http_test.go`, sebelum method `Ping` milik `fakeStore`:

```go
func (f *fakeStore) Mutate(_ context.Context, number string, t MutationType, req MutationRequest) (Account, error) {
	a, ok := f.accounts[number]
	if !ok {
		return Account{}, ErrNotFound
	}
	if t == Debit {
		if a.Balance.LessThan(req.Amount) {
			return Account{}, ErrInsufficientFunds
		}
		a.Balance = a.Balance.Sub(req.Amount)
	} else {
		a.Balance = a.Balance.Add(req.Amount)
	}
	f.accounts[number] = a
	return a, nil
}
```

Kemudian tambahkan kasus uji berikut ke tabel test `TestAccountAPI`, setelah kasus `"wrong method"`. Kasus-kasus ini berjalan berurutan pada rekening yang sama: saldo 500000 didebit 200000, dikredit 50000, lalu debit sebesar 350000.01 harus ditolak.

```go
		{"debit", "POST", "/accounts/1234567890/debit", `{"amount":"200000","reference":"T-1"}`, 200, `"balance":"300000"`},
		{"credit", "POST", "/accounts/1234567890/credit", `{"amount":"50000","reference":"T-2"}`, 200, `"balance":"350000"`},
		{"insufficient funds", "POST", "/accounts/1234567890/debit", `{"amount":"350000.01","reference":"T-3"}`, 422, "insufficient funds"},
		{"debit unknown account", "POST", "/accounts/0000000000/debit", `{"amount":"1","reference":"T-4"}`, 404, "not found"},
		{"invalid mutation", "POST", "/accounts/1234567890/credit", `{"amount":"0","reference":""}`, 400, `"amount":"must be greater than zero"`},
```

#perintah[```bash
make -C account test
```]

Seluruh test harus lulus sebelum melanjutkan ke transfer service.

=== Database untuk transfer service

Transfer service mendapat _container_ PostgreSQL sendiri. Port host `15433` dipilih supaya tidak bertabrakan dengan `db-account` (15432) maupun PostgreSQL lokal di port 5432. Tambahkan blok berikut di `compose.yaml`, di bawah _service_ `db-account`:

```yaml
  db-transfer:
    image: postgres:18.6-alpine
    environment:
      POSTGRES_DB: transfer
      POSTGRES_USER: transfer
      POSTGRES_PASSWORD: transfer123
    ports:
      - "15433:5432"
    volumes:
      - db-transfer:/var/lib/postgresql
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "transfer", "-d", "transfer"]
      interval: 2s
      retries: 30
```

Tambahkan juga _volume_-nya pada bagian `volumes` di akhir file:

```yaml
volumes:
  db-account:
  db-transfer:
```

Jalankan ulang infrastruktur. `docker compose up` hanya membuat _container_ yang belum ada, sehingga `db-account` beserta datanya tidak terganggu.

#perintah[```bash
make infra-up
docker compose ps
```]

Keluaran `docker compose ps` harus menampilkan `db-account` dan `db-transfer` dengan status `healthy`.

=== Modul Go untuk transfer service

Setiap service adalah modul Go tersendiri dengan `go.mod` sendiri. Pemisahan ini membuat setiap service dapat dibangun, diuji, dan di-_deploy_ secara terpisah. File `go.work` menyatukan modul-modul tersebut selama pengembangan di laptop, sehingga perintah `go` dapat dijalankan dari folder mana pun di dalam `studi-kasus/`.

#perintah[```bash
mkdir -p transfer/internal/transfer transfer/internal/accountclient
cd transfer
go mod init github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer
go mod edit -go=1.26.0
cd ..
go work use ./transfer
```]

Seperti pada Lab 1, `go mod init` menuliskan versi Go yang terpasang di laptop, sehingga `go mod edit -go=1.26.0` menurunkan versi minimal modul `transfer` ke 1.26.0, sama dengan _checkpoint_. Jika baris `go` di `go.work` ikut naik setelah `go work use`, kembalikan dengan `go work edit -go=1.26.0`.

Setelah perintah di atas, `go.work` berisi dua modul:

```
go 1.26.0

use (
	./account
	./transfer
)
```

Daftarkan juga transfer service di `Makefile` level atas supaya `make test` menguji kedua service. Ubah baris pertama menjadi:

```make
SERVICES := account transfer
```

=== Domain transfer

Paket `transfer` berisi model, validasi, dan dua _interface_ yang dibutuhkan logika transfer: `Store` untuk database milik sendiri, dan `AccountClient` untuk account service. Logika transfer hanya bergantung pada kedua _interface_ ini. Implementasi konkretnya (PostgreSQL dan _HTTP client_) disambungkan di `main.go`, sehingga logika transfer dapat diuji dengan implementasi palsu tanpa database dan tanpa jaringan.

Transfer memiliki tiga status. `PENDING` berarti transfer sudah dicatat tetapi belum selesai diproses. `COMPLETED` berarti debit dan kredit berhasil. `FAILED` berarti salah satu langkah gagal, dengan alasan tersimpan di `failure_reason`.

Dua _error_ bisnis, `ErrAccountNotFound` dan `ErrInsufficientFunds`, didefinisikan di sini, bukan di paket _HTTP client_. Dengan begitu logika transfer dan _handler_ HTTP dapat mengenali penolakan bisnis tanpa mengetahui bahwa account service diakses melalui REST. Pada Lab 4, REST diganti gRPC dan kedua _error_ ini tetap sama.

Buat `transfer/internal/transfer/transfer.go`:

```go
// Package transfer moves money between two accounts by calling the account service.
package transfer

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/shopspring/decimal"
)

type Status string

const (
	Pending   Status = "PENDING"
	Completed Status = "COMPLETED"
	Failed    Status = "FAILED"
)

type Transfer struct {
	ID            string          `json:"id"`
	FromAccount   string          `json:"from_account"`
	ToAccount     string          `json:"to_account"`
	Amount        decimal.Decimal `json:"amount"`
	Status        Status          `json:"status"`
	FailureReason string          `json:"failure_reason,omitempty"`
	CreatedAt     time.Time       `json:"created_at"`
	UpdatedAt     time.Time       `json:"updated_at"`
}

type CreateRequest struct {
	FromAccount string          `json:"from_account"`
	ToAccount   string          `json:"to_account"`
	Amount      decimal.Decimal `json:"amount"`
}

var (
	ErrNotFound = errors.New("transfer not found")
	// Business rejections from the account service: the request itself cannot succeed.
	ErrAccountNotFound   = errors.New("account not found")
	ErrInsufficientFunds = errors.New("insufficient funds")
)

type ValidationError map[string]string

func (v ValidationError) Error() string { return "validation failed" }

var numberPattern = regexp.MustCompile(`^[0-9]{10}$`)

func (r CreateRequest) Validate() error {
	v := ValidationError{}
	if !numberPattern.MatchString(r.FromAccount) {
		v["from_account"] = "must be exactly 10 digits"
	}
	if !numberPattern.MatchString(r.ToAccount) {
		v["to_account"] = "must be exactly 10 digits"
	}
	if r.FromAccount == r.ToAccount {
		v["to_account"] = "must differ from from_account"
	}
	if !r.Amount.IsPositive() {
		v["amount"] = "must be greater than zero"
	}
	if len(v) > 0 {
		return v
	}
	return nil
}

type Store interface {
	// Create records a new transfer in status PENDING.
	Create(ctx context.Context, req CreateRequest) (Transfer, error)
	Finish(ctx context.Context, id string, status Status, reason string) (Transfer, error)
	Get(ctx context.Context, id string) (Transfer, error)
	Ping(ctx context.Context) error
}

// AccountClient is what the transfer needs from the account service. The reference
// passed to the account service is the transfer ID.
type AccountClient interface {
	Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error
	Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error
}
```

=== Penyimpanan transfer

Tabel `transfer` menggunakan UUID sebagai _primary key_. ID ini juga dikirim ke account service sebagai `reference` mutasi, sehingga setiap mutasi di database `account` dapat ditelusuri ke transfer pemicunya. Buat `transfer/internal/transfer/schema.sql`:

```sql
create table if not exists transfer (
    id             uuid           primary key default gen_random_uuid(),
    from_account   varchar(10)    not null,
    to_account     varchar(10)    not null,
    amount         numeric(19, 2) not null check (amount > 0),
    status         varchar(10)    not null check (status in ('PENDING', 'COMPLETED', 'FAILED')),
    failure_reason text,
    created_at     timestamptz    not null default now(),
    updated_at     timestamptz    not null default now()
);
```

Perhatikan bahwa kolom `from_account` dan `to_account` tidak memiliki _foreign key_. Tabel `account` berada di database lain, sehingga keberadaan rekening hanya dapat diperiksa melalui account service.

Implementasi `Store` mengikuti pola account service dari Lab 1: _connection pool_ pgx, registrasi tipe `decimal`, dan schema yang di-_embed_ ke dalam _binary_. Semua _query_ mengembalikan kolom yang sama dalam urutan yang sama, sehingga cukup satu konstanta `columns` dan satu fungsi pembantu `one`. Ada satu kasus khusus: `GET /transfers/abc` mengirim teks yang bukan UUID, dan PostgreSQL menolaknya dengan kode `22P02`. Bagi pemanggil API, kasus ini sama saja dengan transfer yang tidak ditemukan.

Buat `transfer/internal/transfer/store.go`:

```go
package transfer

import (
	"context"
	_ "embed"
	"errors"
	"fmt"

	pgxdecimal "github.com/jackc/pgx-shopspring-decimal"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schema string

// columns is shared by every query so RowToStructByPos maps them onto Transfer in order.
const columns = `id::text, from_account, to_account, amount, status, coalesce(failure_reason, ''), created_at, updated_at`

type PostgresStore struct {
	pool *pgxpool.Pool
}

// NewPostgresStore connects, verifies the connection, and applies the schema.
func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	cfg.AfterConnect = func(_ context.Context, conn *pgx.Conn) error {
		pgxdecimal.Register(conn.TypeMap())
		return nil
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
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

func (s *PostgresStore) Create(ctx context.Context, req CreateRequest) (Transfer, error) {
	return s.one(ctx, `
		insert into transfer (from_account, to_account, amount, status)
		values (@from, @to, @amount, 'PENDING')
		returning `+columns,
		pgx.NamedArgs{"from": req.FromAccount, "to": req.ToAccount, "amount": req.Amount})
}

func (s *PostgresStore) Finish(ctx context.Context, id string, status Status, reason string) (Transfer, error) {
	return s.one(ctx, `
		update transfer set status = @status, failure_reason = nullif(@reason, ''), updated_at = now()
		where id = @id
		returning `+columns,
		pgx.NamedArgs{"id": id, "status": string(status), "reason": reason})
}

func (s *PostgresStore) Get(ctx context.Context, id string) (Transfer, error) {
	return s.one(ctx, `select `+columns+` from transfer where id = @id`, pgx.NamedArgs{"id": id})
}

func (s *PostgresStore) one(ctx context.Context, sql string, args pgx.NamedArgs) (Transfer, error) {
	rows, err := s.pool.Query(ctx, sql, args)
	if err != nil {
		return Transfer{}, err
	}
	t, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Transfer])
	var pgErr *pgconn.PgError
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return Transfer{}, ErrNotFound
	case errors.As(err, &pgErr) && pgErr.Code == "22P02": // invalid_text_representation: not a UUID
		return Transfer{}, ErrNotFound
	}
	return t, err
}
```

=== Logika transfer

`Service.Execute` menjalankan empat langkah secara berurutan: catat transfer dengan status `PENDING`, debit rekening sumber, kredit rekening tujuan, lalu ubah status menjadi `COMPLETED`. Jika debit atau kredit gagal, status menjadi `FAILED` dan alasannya disimpan.

Transfer dicatat lebih dahulu, sebelum memanggil account service. Urutan ini memastikan setiap mutasi di account service selalu memiliki pasangan transfer yang dapat ditelusuri, termasuk ketika proses berhenti di tengah jalan.

Komentar _known gap_ pada kode di bawah menjelaskan kelemahan utama lab ini. Debit dan kredit adalah dua panggilan terpisah ke service lain, tanpa transaksi database bersama. Ketika kredit gagal setelah debit berhasil, transfer ditandai `FAILED`, tetapi saldo rekening sumber tetap berkurang. Satu-satunya penanganan pada lab ini adalah _log_ level `ERROR` sebagai penanda bahwa rekening sumber perlu dikoreksi manual.

Buat `transfer/internal/transfer/service.go`:

```go
package transfer

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
)

type Service struct {
	store    Store
	accounts AccountClient
	log      *slog.Logger
}

func NewService(store Store, accounts AccountClient, log *slog.Logger) *Service {
	return &Service{store: store, accounts: accounts, log: log}
}

// Execute records the transfer, debits the source, then credits the destination.
// The returned error is the reason the transfer FAILED; the transfer itself is
// returned whenever it was recorded.
//
// Known gap: debit and credit are two calls to another service, with no shared
// database transaction. When the credit fails after a successful debit, the money
// has left the source account and arrived nowhere. The transfer is marked FAILED
// and logged for manual reversal.
func (s *Service) Execute(ctx context.Context, req CreateRequest) (Transfer, error) {
	t, err := s.store.Create(ctx, req)
	if err != nil {
		return Transfer{}, fmt.Errorf("record transfer: %w", err)
	}

	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
		return s.fail(ctx, t, "debit failed", err)
	}
	if err := s.accounts.Credit(ctx, t.ToAccount, t.Amount, t.ID); err != nil {
		s.log.Error("credit failed after debit, source account needs manual reversal",
			"transfer_id", t.ID, "from_account", t.FromAccount, "amount", t.Amount, "error", err)
		return s.fail(ctx, t, "credit failed after debit", err)
	}

	done, err := s.store.Finish(ctx, t.ID, Completed, "")
	if err != nil {
		return t, fmt.Errorf("mark transfer completed: %w", err)
	}
	s.log.Info("transfer completed", "transfer_id", t.ID, "amount", t.Amount)
	return done, nil
}

func (s *Service) fail(ctx context.Context, t Transfer, step string, cause error) (Transfer, error) {
	reason := fmt.Sprintf("%s: %v", step, cause)
	failed, err := s.store.Finish(ctx, t.ID, Failed, reason)
	if err != nil {
		return t, errors.Join(cause, fmt.Errorf("mark transfer failed: %w", err))
	}
	s.log.Warn("transfer failed", "transfer_id", t.ID, "reason", reason)
	return failed, cause
}

func (s *Service) Get(ctx context.Context, id string) (Transfer, error) {
	return s.store.Get(ctx, id)
}

func (s *Service) Ping(ctx context.Context) error { return s.store.Ping(ctx) }
```

Fungsi `fail` mengembalikan `cause` apa adanya, yaitu _error_ dari account client. Pemanggil `Execute` dapat memeriksa _error_ ini dengan `errors.Is(err, ErrInsufficientFunds)` untuk menentukan status HTTP.

=== REST client ke account service

Paket `accountclient` mengimplementasikan _interface_ `AccountClient` dengan memanggil _endpoint_ debit dan kredit milik account service. Tugas utamanya adalah menerjemahkan respons HTTP menjadi _error_ yang dipahami paket `transfer`:

#table(
  columns: (auto, 1fr),
  [Status dari Account Service], [Error yang Dikembalikan],
  [`200 OK`], [Tidak ada _error_],
  [`404 Not Found`], [`transfer.ErrAccountNotFound`, dibungkus dengan `%w`],
  [`422 Unprocessable Entity`], [`transfer.ErrInsufficientFunds`, dibungkus dengan `%w`],
  [Status lain], [_Error_ biasa berisi status dan isi respons],
  [Gagal terhubung], [_Error_ dari `http.Client.Do`, misalnya _connection refused_],
)

Pembungkusan dengan `%w` menambahkan konteks (operasi dan nomor rekening) ke pesan _error_, sementara `errors.Is` tetap dapat mengenali _error_ aslinya.

Perhatikan konstruktor `New`. `http.Client{}` tanpa nilai `Timeout` akan menunggu respons tanpa batas waktu. Kelemahan ini sengaja dibiarkan dan dicatat di komentar, karena Lab 3 membahasnya secara khusus.

Buat `transfer/internal/accountclient/client.go`:

```go
// Package accountclient calls the account service REST API.
package accountclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/shopspring/decimal"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

type Client struct {
	baseURL string
	http    *http.Client
}

// New uses an http.Client without a timeout: a slow account service makes every
// transfer wait as long as it takes.
func New(baseURL string) *Client {
	return &Client{baseURL: baseURL, http: &http.Client{}}
}

func (c *Client) Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	return c.mutate(ctx, number, "debit", amount, reference)
}

func (c *Client) Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	return c.mutate(ctx, number, "credit", amount, reference)
}

func (c *Client) mutate(ctx context.Context, number, kind string, amount decimal.Decimal, reference string) error {
	body, err := json.Marshal(map[string]any{"amount": amount, "reference": reference})
	if err != nil {
		return err
	}
	url := fmt.Sprintf("%s/accounts/%s/%s", c.baseURL, number, kind)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", kind, number, err)
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch resp.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusNotFound:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountNotFound)
	case http.StatusUnprocessableEntity:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrInsufficientFunds)
	default:
		return fmt.Errorf("%s %s: account service answered %s: %s", kind, number, resp.Status, bytes.TrimSpace(msg))
	}
}
```

`io.LimitReader` membatasi isi respons yang dibaca hingga 4096 byte. Isi respons hanya dibutuhkan untuk pesan _error_, dan pembatasan ini mencegah respons yang sangat besar menghabiskan memori.

=== HTTP API transfer service

_Handler_ transfer mengikuti pola account service: `decode`, validasi, panggil logika, lalu petakan hasilnya ke status HTTP. Pemetaan untuk `POST /transfers`:

#table(
  columns: (auto, 1fr),
  [Status HTTP], [Kondisi],
  [`201 Created`], [Debit dan kredit berhasil, transfer `COMPLETED`],
  [`400 Bad Request`], [JSON tidak valid atau validasi gagal; transfer tidak dicatat],
  [`422 Unprocessable Entity`], [Penolakan bisnis (rekening tidak ada, saldo kurang); transfer `FAILED`],
  [`502 Bad Gateway`], [Account service gagal atau tidak dapat dihubungi; transfer `FAILED`],
  [`500 Internal Server Error`], [Transfer bahkan tidak sempat dicatat, misalnya database transfer bermasalah],
)

Pada respons `422` dan `502`, isi respons tetap berupa data transfer lengkap dengan `id`, `status`, dan `failure_reason`, sehingga klien dapat menelusuri transfer tersebut melalui `GET /transfers/{id}`.

Dua keputusan desain pada _handler_ ini perlu diperhatikan.

*`context.WithoutCancel`.* Secara bawaan, _context_ dari `r.Context()` dibatalkan ketika klien memutus koneksi. Jika _context_ tersebut diteruskan ke `Execute`, klien yang memutus koneksi di tengah proses dapat menghentikan transfer tepat di antara debit dan kredit. `context.WithoutCancel` mempertahankan nilai-nilai di dalam _context_ tetapi melepas sinyal pembatalannya, sehingga transfer yang sudah dimulai tetap berjalan hingga selesai.

*`readyz` hanya memeriksa database sendiri.* Account service memiliki _probe_ sendiri. Jika `readyz` milik transfer service ikut gagal ketika account service mati, transfer service akan dikeluarkan dari _load balancer_ karena gangguan yang tidak dapat diperbaikinya sendiri, dan `GET /transfers/{id}` yang tidak membutuhkan account service ikut tidak dapat diakses.

Buat `transfer/internal/transfer/http.go`:

```go
package transfer

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"
)

type Handler struct {
	svc *Service
	log *slog.Logger
}

func NewHandler(svc *Service, log *slog.Logger) *Handler {
	return &Handler{svc: svc, log: log}
}

func (h *Handler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /transfers", h.create)
	mux.HandleFunc("GET /transfers/{id}", h.get)
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	return mux
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req CreateRequest
	if !decode(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "fields": err})
		return
	}
	// WithoutCancel: a client that disconnects must not abort a transfer halfway,
	// e.g. between the debit and the credit.
	t, err := h.svc.Execute(context.WithoutCancel(r.Context()), req)
	switch {
	case err == nil:
		w.Header().Set("Location", "/transfers/"+t.ID)
		writeJSON(w, http.StatusCreated, t)
	case t.ID == "":
		h.internalError(w, r, err)
	case errors.Is(err, ErrAccountNotFound), errors.Is(err, ErrInsufficientFunds):
		writeJSON(w, http.StatusUnprocessableEntity, t)
	default:
		// Recorded but not completed because a dependency failed.
		writeJSON(w, http.StatusBadGateway, t)
	}
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	t, err := h.svc.Get(r.Context(), r.PathValue("id"))
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case err != nil:
		h.internalError(w, r, err)
	default:
		writeJSON(w, http.StatusOK, t)
	}
}

func (h *Handler) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
}

// readyz checks only this service's own database. The account service is a
// dependency with its own probes; failing here when it is down would take the
// transfer service out of rotation for an outage it cannot fix.
func (h *Handler) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.svc.Ping(ctx); err != nil {
		h.log.Warn("readiness check failed", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "DOWN", "database": "DOWN"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP", "database": "UP"})
}

func (h *Handler) internalError(w http.ResponseWriter, r *http.Request, err error) {
	h.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}

// decode reads a JSON body into dst and answers 400 itself when the body is invalid.
func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	return true
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

Fungsi `decode`, `writeError`, dan `writeJSON` memang sama persis dengan milik account service. Duplikasi kecil seperti ini disengaja: berbagi kode lewat modul bersama akan membuat kedua service saling terikat pada setiap perubahan modul tersebut.

=== Konfigurasi dan `main.go`

Transfer service membutuhkan tiga variabel _environment_: alamat HTTP, URL database, dan URL account service. Ketiganya wajib diisi. Jika salah satu kosong, service berhenti pada _startup_ dengan pesan yang menyebutkan nama variabelnya, bukan berjalan dengan nilai tebakan yang mungkin mengarah ke database atau service yang salah.

Buat `transfer/config.go`:

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
	HTTPAddr          string
	DatabaseURL       string
	AccountServiceURL string
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
		HTTPAddr:          get("HTTP_ADDR"),
		DatabaseURL:       get("DATABASE_URL"),
		AccountServiceURL: get("ACCOUNT_SERVICE_URL"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	return cfg, nil
}
```

`main.go` menyambungkan semua bagian: konfigurasi, `PostgresStore`, `accountclient`, `Service`, lalu `Handler`. Strukturnya sama dengan account service pada Lab 1, termasuk _graceful shutdown_ ketika menerima `SIGINT` atau `SIGTERM`. Buat `transfer/main.go`:

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

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/accountclient"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("transfer service stopped", "error", err)
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

	store, err := transfer.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	svc := transfer.NewService(store, accountclient.New(cfg.AccountServiceURL), log)
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           transfer.NewHandler(svc, log).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("transfer service listening", "addr", cfg.HTTPAddr, "account_service", cfg.AccountServiceURL)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
```

=== Makefile dan _dependency_

Setiap langkah _pipeline_ CI pada Lab 10 memanggil _target_ `make`, sehingga perintah di laptop dan di _runner_ CI selalu sama. Buat `transfer/Makefile`. Ingat bahwa baris perintah di dalam _target_ harus diawali karakter _tab_, bukan spasi.

```make
# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := transfer

.PHONY: run test build clean

run:
	HTTP_ADDR=:8082 \
	DATABASE_URL=postgres://transfer:transfer123@localhost:15433/transfer \
	ACCOUNT_SERVICE_URL=http://localhost:8081 \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
```

Setelah semua kode ditulis, unduh _dependency_ dengan versi yang sama dengan account service, lalu rapikan `go.mod`:

#perintah[```bash
cd transfer
go get github.com/jackc/pgx/v5@v5.11.0 \
  github.com/shopspring/decimal@v1.6.0 \
  github.com/jackc/pgx-shopspring-decimal@v0.0.0-20220624020537-1d36b5a1853e
go mod tidy
cd ..
```]

=== Pengujian transfer service

Test logika transfer tidak membutuhkan database maupun account service. Keduanya diganti implementasi palsu: `fakeStore` menyimpan transfer di _map_, dan `fakeAccounts` mengembalikan _error_ yang sudah ditentukan sambil mencatat setiap panggilan. Tiga skenario diuji:

- transfer berhasil: status `COMPLETED`, dua panggilan (debit lalu kredit);
- saldo tidak cukup: status `FAILED`, hanya satu panggilan, karena kredit tidak boleh dijalankan setelah debit ditolak;
- kredit gagal setelah debit: status `FAILED`, dua panggilan. Skenario ini mendokumentasikan _known gap_: tidak ada panggilan ketiga untuk mengembalikan debit.

Buat `transfer/internal/transfer/service_test.go`:

```go
package transfer

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"testing"

	"github.com/shopspring/decimal"
)

type fakeStore struct {
	transfers map[string]Transfer
	seq       int
}

func (f *fakeStore) Create(_ context.Context, req CreateRequest) (Transfer, error) {
	f.seq++
	t := Transfer{ID: fmt.Sprint(f.seq), FromAccount: req.FromAccount, ToAccount: req.ToAccount, Amount: req.Amount, Status: Pending}
	f.transfers[t.ID] = t
	return t, nil
}

func (f *fakeStore) Finish(_ context.Context, id string, status Status, reason string) (Transfer, error) {
	t := f.transfers[id]
	t.Status, t.FailureReason = status, reason
	f.transfers[id] = t
	return t, nil
}

func (f *fakeStore) Get(_ context.Context, id string) (Transfer, error) {
	t, ok := f.transfers[id]
	if !ok {
		return Transfer{}, ErrNotFound
	}
	return t, nil
}

func (f *fakeStore) Ping(context.Context) error { return nil }

// fakeAccounts returns the configured error for each operation and records the calls.
type fakeAccounts struct {
	debitErr, creditErr error
	calls               []string
}

func (f *fakeAccounts) Debit(_ context.Context, number string, amount decimal.Decimal, ref string) error {
	f.calls = append(f.calls, "debit "+number)
	return f.debitErr
}

func (f *fakeAccounts) Credit(_ context.Context, number string, amount decimal.Decimal, ref string) error {
	f.calls = append(f.calls, "credit "+number)
	return f.creditErr
}

func TestExecute(t *testing.T) {
	req := CreateRequest{FromAccount: "1111111111", ToAccount: "2222222222", Amount: decimal.RequireFromString("100000")}
	unavailable := errors.New("connection refused")

	tests := []struct {
		name       string
		accounts   *fakeAccounts
		wantStatus Status
		wantErr    error
		wantCalls  int
	}{
		{"success", &fakeAccounts{}, Completed, nil, 2},
		{"insufficient funds stops before credit", &fakeAccounts{debitErr: ErrInsufficientFunds}, Failed, ErrInsufficientFunds, 1},
		{"credit fails after debit", &fakeAccounts{creditErr: unavailable}, Failed, unavailable, 2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeStore{transfers: map[string]Transfer{}}
			svc := NewService(store, tc.accounts, slog.New(slog.NewTextHandler(io.Discard, nil)))

			got, err := svc.Execute(context.Background(), req)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
			if got.Status != tc.wantStatus {
				t.Fatalf("status = %s, want %s", got.Status, tc.wantStatus)
			}
			if stored := store.transfers[got.ID]; stored.Status != tc.wantStatus {
				t.Fatalf("stored status = %s, want %s", stored.Status, tc.wantStatus)
			}
			if len(tc.accounts.calls) != tc.wantCalls {
				t.Fatalf("account calls = %v, want %d calls", tc.accounts.calls, tc.wantCalls)
			}
		})
	}
}

func TestValidate(t *testing.T) {
	err := CreateRequest{FromAccount: "1111111111", ToAccount: "1111111111", Amount: decimal.Zero}.Validate()
	v, ok := err.(ValidationError)
	if !ok || v["to_account"] == "" || v["amount"] == "" {
		t.Fatalf("got %v, want errors on to_account and amount", err)
	}
}
```

Account client diuji terhadap server palsu dari `net/http/httptest`. `httptest.NewServer` menjalankan server HTTP sungguhan di port acak pada `localhost`, sehingga pemetaan status HTTP ke _error_ dapat diperiksa tanpa menjalankan account service. Buat `transfer/internal/accountclient/client_test.go`:

```go
package accountclient

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/shopspring/decimal"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

func TestStatusMapping(t *testing.T) {
	tests := []struct {
		status  int
		wantErr error
	}{
		{http.StatusOK, nil},
		{http.StatusNotFound, transfer.ErrAccountNotFound},
		{http.StatusUnprocessableEntity, transfer.ErrInsufficientFunds},
	}
	for _, tc := range tests {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost || r.URL.Path != "/accounts/1111111111/debit" {
				t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			}
			w.WriteHeader(tc.status)
		}))
		err := New(srv.URL).Debit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
		srv.Close()
		if !errors.Is(err, tc.wantErr) {
			t.Errorf("status %d: err = %v, want %v", tc.status, err, tc.wantErr)
		}
	}
}

func TestServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()
	err := New(srv.URL).Credit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
	if err == nil || errors.Is(err, transfer.ErrAccountNotFound) || errors.Is(err, transfer.ErrInsufficientFunds) {
		t.Fatalf("err = %v, want a non-business error", err)
	}
}
```

== Verifikasi

=== Test otomatis

Jalankan test kedua service dari folder `studi-kasus/`:

#perintah[```bash
make test
```]

Keluaran berisi baris `ok` untuk paket `account/internal/account`, `transfer/internal/accountclient`, dan `transfer/internal/transfer`, tanpa satu pun `FAIL`.

=== Konfigurasi wajib

Jalankan transfer service tanpa variabel _environment_. Service harus langsung berhenti dan menyebutkan variabel yang belum diisi:

#perintah[```bash
cd transfer && go run . ; cd ..
```]

Service langsung berhenti dengan _exit code_ 1 dan menulis _log_ seperti berikut:

```
level=ERROR msg="transfer service stopped" error="missing required environment variables: HTTP_ADDR, DATABASE_URL, ACCOUNT_SERVICE_URL"
```

=== Menjalankan kedua service

Buka dua terminal, keduanya di folder `studi-kasus/`. Account service berjalan di port 8081 dan transfer service di port 8082.

#perintah[```bash
# terminal 1
make -C account run

# terminal 2
make -C transfer run
```]

Terminal 2 menampilkan baris `msg="transfer service listening" addr=:8082 account_service=http://localhost:8081`. Buka terminal ketiga untuk perintah-perintah berikutnya, lalu buat dua rekening uji. Jika nomor rekening ini sudah dibuat pada Lab 1, account service menjawab `409` dan rekening yang lama dapat langsung digunakan; sesuaikan angka saldo pada langkah berikutnya.

#perintah[```bash
curl -s -X POST localhost:8081/accounts -H 'Content-Type: application/json' \
  -d '{"number":"1111111111","owner_name":"Budi","initial_balance":"500000"}'
curl -s -X POST localhost:8081/accounts -H 'Content-Type: application/json' \
  -d '{"number":"2222222222","owner_name":"Sari","initial_balance":"100000"}'
```]

=== Transfer berhasil

#perintah[```bash
curl -s -i -X POST localhost:8082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

Respons berstatus `201 Created` dengan _header_ `Location: /transfers/<id>` dan isi seperti berikut (ID dan waktu akan berbeda):

```
{"id":"3f0c...","from_account":"1111111111","to_account":"2222222222","amount":"100000","status":"COMPLETED","created_at":"...","updated_at":"..."}
```

Terminal account service menampilkan dua baris `msg="account mutated"`, satu dengan `type=DEBIT` untuk `1111111111` dan satu dengan `type=CREDIT` untuk `2222222222`. Keduanya membawa `reference` yang sama dengan `id` transfer. Periksa saldo kedua rekening:

#perintah[```bash
curl -s localhost:8081/accounts/1111111111
curl -s localhost:8081/accounts/2222222222
```]

Saldo `1111111111` menjadi `"400000"` dan saldo `2222222222` menjadi `"200000"`. Catatan mutasi dapat dilihat langsung di database account:

#perintah[```bash
docker compose exec db-account psql -U account -d account \
  -c "select account_number, type, amount, reference from mutation order by id"
```]

=== Saldo tidak mencukupi

#perintah[```bash
curl -s -i -X POST localhost:8082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"2222222222","to_account":"1111111111","amount":"999999"}'
```]

Respons berstatus `422 Unprocessable Entity`, dengan `"status":"FAILED"` dan `"failure_reason":"debit failed: debit 2222222222: insufficient funds"`. Saldo kedua rekening tidak berubah, dan tidak ada baris baru di tabel `mutation`.

=== Validasi dan transfer yang tidak ada

#perintah[```bash
curl -s -X POST localhost:8082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"1111111111","amount":"0"}'
curl -s -i localhost:8082/transfers/bukan-uuid
```]

Perintah pertama menghasilkan `400` dengan `"fields":{"amount":"must be greater than zero","to_account":"must differ from from_account"}`. Perintah kedua menghasilkan `404` dengan `{"error":"transfer not found"}`.

=== Kredit gagal setelah debit

Skenario ini memperlihatkan _known gap_ secara langsung. Rekening tujuan `9999999999` tidak ada, sehingga debit berhasil tetapi kredit ditolak.

#perintah[```bash
curl -s -i -X POST localhost:8082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"9999999999","amount":"50000"}'
curl -s localhost:8081/accounts/1111111111
```]

Respons transfer berstatus `422` dengan `"status":"FAILED"` dan `"failure_reason":"credit failed after debit: credit 9999999999: account not found"`. Terminal transfer service menampilkan _log_ `level=ERROR msg="credit failed after debit, source account needs manual reversal"`. Namun saldo `1111111111` turun dari `"400000"` menjadi `"350000"`: uang Rp50.000 sudah keluar dan tidak masuk ke mana pun. Tabel `mutation` mencatat satu `DEBIT` dengan `reference` transfer tersebut, tanpa pasangan `CREDIT`.

#note[
  Validasi nomor rekening tujuan sebelum debit memang dapat mencegah kasus ini secara khusus. Namun kredit tetap dapat gagal karena sebab lain, misalnya account service mati tepat setelah debit. Masalah intinya adalah tidak adanya transaksi bersama antara dua panggilan, dan Lab 5 menyelesaikannya dengan kompensasi pada pola _saga_.
]

=== Account service mati

Hentikan account service di terminal 1 dengan `Ctrl+C`, lalu kirim transfer:

#perintah[```bash
curl -s -i -X POST localhost:8082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"10000"}'
curl -s localhost:8082/readyz
```]

Transfer menghasilkan `502 Bad Gateway` dengan `"status":"FAILED"` dan `failure_reason` yang berisi `debit failed: debit 1111111111: Post "http://localhost:8081/accounts/1111111111/debit": dial tcp ...: connect: connection refused`. Sementara itu `readyz` tetap menjawab `{"database":"UP","status":"UP"}`, karena _readiness_ transfer service hanya bergantung pada database miliknya sendiri. Jalankan kembali account service sebelum lanjut ke lab berikutnya.

== Masalah Umum

*`current directory is contained in a module that is not one of the workspace modules listed in go.work` atau `directory prefix . does not contain modules listed in go.work`.* Modul `transfer` belum terdaftar di `go.work`. Pesan pertama muncul dari `go run .`, pesan kedua dari `go test ./...` di folder `transfer/`. Jalankan `go work use ./transfer` dari folder `studi-kasus/`, lalu periksa isi `go.work`.

*`missing go.sum entry` atau `no required module provides package`.* _Dependency_ belum diunduh. Jalankan `go get` dan `go mod tidy` di folder `transfer/` seperti pada langkah Makefile dan _dependency_.

*Test account gagal dikompilasi dengan pesan `*fakeStore does not implement Store (missing method Mutate)`.* Method `Mutate` sudah ditambahkan ke _interface_ `Store` tetapi belum ke `fakeStore` di `http_test.go`.

*`make: *** missing separator. Stop.`* Baris perintah di `transfer/Makefile` diawali spasi. Ganti dengan karakter _tab_. Sebagian editor mengubah _tab_ menjadi spasi secara otomatis.

*Transfer service gagal _startup_ dengan `connect to database: ... connection refused` pada port 15433.* _Container_ `db-transfer` belum berjalan. Periksa `compose.yaml`, lalu jalankan `make infra-up` dan `docker compose ps`.

*`relation "mutation" does not exist` di _log_ account service.* Account service yang sedang berjalan masih versi lama. Hentikan dengan `Ctrl+C` dan jalankan ulang `make -C account run` supaya schema baru diterapkan.

*Semua transfer gagal dengan `422` dan `failure_reason` `debit failed: debit ...: account not found`, termasuk untuk rekening yang ada.* Nilai `ACCOUNT_SERVICE_URL` diakhiri `/accounts`, sehingga path permintaan menjadi `/accounts/accounts/{number}/debit` dan account service menjawab `404`. Paket `accountclient` menerjemahkan setiap `404` menjadi `ErrAccountNotFound`, sehingga kesalahan konfigurasi ini terlihat seperti penolakan bisnis. Hapus `/accounts` dari nilai tersebut.

*`bind: address already in use` pada port 8081 atau 8082.* Masih ada proses lama yang berjalan, misalnya dari terminal lain. Hentikan proses tersebut, atau cari dengan `lsof -i :8082`.

== Eksplorasi Mandiri

+ *Account service yang lambat.* Lab ini menyebut _HTTP client_ tanpa _timeout_ sebagai kelemahan. Buktikan dengan menghentikan sementara proses account service. Cari PID _binary_ hasil `go run` dengan `pgrep -f 'exe/account'`, hentikan sementara dengan `kill -STOP <pid>`, lalu kirim transfer. Amati bahwa `curl` menunggu tanpa batas. Lanjutkan kembali proses tersebut dengan `kill -CONT <pid>` dan perhatikan bahwa transfer yang tertunda langsung selesai. Bayangkan dampaknya jika ratusan transfer menunggu bersamaan.
+ *Debit bersamaan.* Buat rekening dengan saldo 100000, lalu kirim sepuluh transfer masing-masing 20000 secara paralel, misalnya dengan `for i in $(seq 10); do curl ... & done; wait`. Hitung jumlah transfer `COMPLETED` dan periksa bahwa saldo tidak pernah negatif. Jelaskan peran klausa `where balance + @delta >= 0` dalam hasil tersebut.
+ *Rekonsiliasi.* Tulis _query_ SQL di database `account` yang menampilkan referensi transfer dengan `DEBIT` tetapi tanpa `CREDIT`. _Query_ ini adalah bentuk paling sederhana dari laporan rekonsiliasi untuk koreksi manual pada _known gap_.
+ *Jumlah dengan tiga angka desimal.* Kirim transfer dengan `"amount":"100.005"`. Transfer tetap `COMPLETED`, tetapi jumlah yang tercatat adalah `"100.01"`. Kolom `numeric(19, 2)` di database transfer membulatkan nilai tersebut tanpa pesan apa pun, lalu debit dan kredit ke account service menggunakan nilai hasil pembulatan. Rumuskan aturan validasi `amount` yang menolak _request_ ini dengan `400`, bukan diam-diam membulatkannya. Lab 4 menambahkan aturan tersebut pada kedua service.
+ *Context yang dibatalkan.* Ganti sementara `context.WithoutCancel(r.Context())` dengan `r.Context()`, gabungkan dengan percobaan nomor 1, lalu hentikan `curl` dengan `Ctrl+C` sebelum proses account service dilanjutkan dengan `kill -CONT`. Amati status akhir transfer tersebut, lalu kembalikan kodenya.

== Checkpoint

Kondisi akhir lab ini tersedia sebagai tag `lab-02`. Bandingkan hasil kerja dengan _checkpoint_ untuk menemukan bagian yang terlewat. Jalankan perintah berikut dari folder `studi-kasus/`:

#perintah[```bash
git diff lab-02 -- .
```]

Tag `lab-02` juga sudah berisi _fault injector_ yang dibutuhkan Lab 3, yaitu paket `account/internal/fault` dan perubahan `account/main.go` yang memasangnya. Perbedaan pada kedua bagian tersebut, serta pada `go.work.sum`, dapat diabaikan karena tidak ditulis pada langkah lab ini. Karena paket tersebut ada di _checkpoint_, `make test` pada tag `lab-02` juga menampilkan baris `ok` untuk `account/internal/fault`.

Peserta yang ingin langsung melanjutkan ke Lab 3 dari kondisi _checkpoint_ dapat menjalankan:

#perintah[```bash
git switch -c kerja-lab-03 lab-02
```]
