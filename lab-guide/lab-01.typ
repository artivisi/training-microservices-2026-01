#import "../_template/panduan.typ": note, perintah

= Lab 1: Account Service dengan REST dan PostgreSQL

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

- menyusun Go _workspace_ (`go.work`) yang menampung beberapa Go _module_, satu _module_ untuk setiap _service_;
- menjalankan PostgreSQL sebagai infrastruktur lab dengan Docker Compose;
- membuat REST API dengan `net/http` bawaan Go, menggunakan _routing_ berdasarkan _method_ dan _path_ (`ServeMux` sejak Go 1.22);
- menyimpan data ke PostgreSQL dengan pgx tanpa ORM, termasuk nilai uang bertipe `numeric`;
- membaca konfigurasi hanya dari _environment variable_ dan menghentikan _service_ saat _startup_ bila ada variabel yang kosong;
- membedakan _liveness probe_ (`/healthz`) dan _readiness probe_ (`/readyz`);
- menguji _handler_ HTTP tanpa database menggunakan `httptest` dan _fake store_.

== Gambaran

Studi kasus pelatihan ini adalah sistem simulasi perbankan yang terdiri atas tiga _service_: `account`, `transfer`, dan `notification`. Lab 1 mengerjakan _service_ pertama, yaitu `account`, yang menyimpan data rekening beserta saldonya. _Service_ lain yang membutuhkan data rekening, misalnya `transfer` pada Lab 2, wajib mengaksesnya melalui API milik `account` dan tidak boleh membaca tabel `account` secara langsung.

Prinsip tersebut disebut _database-per-service_. Setiap _service_ memiliki database sendiri, sehingga struktur tabel dapat diubah tanpa merusak _service_ lain. Karena itu `compose.yaml` pada lab ini menjalankan satu _container_ PostgreSQL khusus untuk `account`. Lab berikutnya menambahkan _container_ PostgreSQL lain untuk `transfer` dan `notification`.

#perintah[```
  curl / aplikasi lain
        |
        |  HTTP :28081  POST /accounts, GET /accounts, GET /accounts/{number}
        v                GET /healthz, GET /readyz
  +--------------------+
  |  account service   |   go run . di laptop
  |  (Go, net/http)    |
  +--------------------+
        |
        |  pgx, localhost:15432
        v
  +--------------------+
  |  db-account        |   container postgres:18.6-alpine
  |  (PostgreSQL)      |   dijalankan Docker Compose
  +--------------------+
```]

Selama Lab 1 hingga Lab 8, _service_ Go dijalankan langsung di laptop dengan `go run`, sedangkan infrastruktur (database, Kafka, dan lain-lain) berjalan di _container_. Dengan pembagian ini, perubahan kode dapat langsung dicoba dengan menjalankan ulang `go run`, tanpa mem-_build_ _image_ baru. Port database sengaja dimulai dari 15432 agar tidak bentrok dengan PostgreSQL yang mungkin sudah terpasang di laptop pada port 5432.

Struktur kode di akhir lab ini:

#perintah[```
studi-kasus/
├── go.work                     daftar module dalam workspace
├── compose.yaml                infrastruktur lab (PostgreSQL)
├── Makefile                    infra-up, infra-down, infra-reset, test
├── .gitignore
├── README.md                   disediakan oleh checkpoint
└── account/
    ├── go.mod
    ├── go.sum
    ├── Makefile                run, test, build
    ├── main.go                 run(): config, database, HTTP server, shutdown
    ├── config.go               LoadConfig() dari environment variable
    └── internal/account/
        ├── account.go          model, validasi, error, interface Store
        ├── schema.sql          tabel account
        ├── store.go            implementasi Store dengan pgx
        ├── http.go             handler dan routing
        └── http_test.go        unit test handler dengan fake store
```]

Kode di dalam `internal/account` disusun dengan pola _package by feature_ (pengelompokan menurut fitur): seluruh kode yang berkaitan dengan rekening berada di satu _package_. Direktori `internal` juga mencegah _module_ lain mengimpor _package_ tersebut, sehingga _service_ lain tidak dapat bergantung pada detail implementasi `account`.

== Titik Awal

Lab 1 dimulai dari _checkpoint_ `lab-00`, yaitu repositori yang baru berisi materi dan `studi-kasus/README.md`. Bila repositori belum ada di laptop, lakukan _clone_ terlebih dahulu. Peserta Windows menjalankan perintah berikut di terminal Ubuntu (WSL2), dengan repositori di _home_ Ubuntu. Repositori yang di-_clone_ dengan Git for Windows ke folder Windows dapat berisi akhir baris CRLF yang membuat skrip _shell_ dan `Makefile` gagal:

// TODO(endy): create tag lab-00 on the commit before "Add Lab 1" when the wip tags are renamed.
#perintah[```bash
git clone https://github.com/artivisi/training-microservices-2026-01.git
cd training-microservices-2026-01
git checkout -b lab-saya lab-00
cd studi-kasus
```]

Perintah `git checkout -b lab-saya lab-00` membuat _branch_ kerja baru bernama `lab-saya` dari tag `lab-00`. Seluruh pekerjaan lab disimpan di _branch_ tersebut, sehingga tag _checkpoint_ tetap utuh sebagai pembanding.

Pastikan Go dan Docker sudah siap. Versi Go minimal 1.26.

#perintah[```bash
go version
docker compose version
```]

Seluruh perintah pada lab ini dijalankan dari direktori `studi-kasus`, kecuali bila disebutkan lain.

== Langkah

=== Membuat Go Module dan Go Workspace

Setiap _service_ dibuat sebagai Go _module_ tersendiri dengan `go.mod` masing-masing. Pemisahan ini membuat dependensi setiap _service_ tercatat sendiri, dan setiap _service_ dapat di-_build_ menjadi _image_ terpisah pada Lab 9. Agar ketiga _module_ tetap dapat dikerjakan bersama dari satu direktori, Go menyediakan _workspace_ melalui file `go.work`. File tersebut mendaftarkan _module_ yang aktif, sehingga perintah `go` yang dijalankan dari `studi-kasus` mengenali seluruh _service_.

#note[
  *Mengapa _monorepo_?* Studi kasus menyimpan ketiga _service_ dan kontrak protobuf dalam satu repositori (_monorepo_). Pilihan ini mempermudah training: satu `git clone` sudah berisi semua _service_, satu _tag checkpoint_ mencatat kondisi seluruh sistem di akhir setiap lab, dan perubahan kontrak gRPC beserta kode di `account` dan `transfer` masuk dalam satu _commit_. Setiap _service_ tetap memiliki `go.mod`, `Dockerfile`, dan _pipeline_ sendiri. _Pipeline_ di Lab 10 hanya berjalan untuk _service_ yang berubah, berdasarkan _path filter_.

  Di organisasi dengan tim terpisah per _service_, satu repositori per _service_ (_polyrepo_) sering lebih cocok, karena hak akses, riwayat, dan jadwal rilis setiap _service_ terpisah dengan jelas. Konsekuensinya, kontrak bersama seperti modul `proto` harus dirilis sebagai modul berversi dan diimpor dengan versi tersebut, sedangkan di studi kasus modul ini cukup dirujuk dengan _directive_ `replace` ke `../proto` (Lab 4).
]

#perintah[```bash
mkdir -p account/internal/account
cd account
go mod init github.com/artivisi/training-microservices-2026-01/studi-kasus/account
go mod edit -go=1.26.0
cd ..
go work init ./account
go work edit -go=1.26.0
```]

Perintah `go mod init` dan `go work init` menuliskan versi Go yang terpasang di laptop. Perintah `go mod edit -go=1.26.0` dan `go work edit -go=1.26.0` menurunkan versi minimal tersebut ke 1.26.0, sama dengan _checkpoint_, agar kode tetap dapat dikompilasi oleh Go 1.26 maupun versi yang lebih baru. Versi pada `go.work` tidak boleh lebih rendah dibandingkan versi pada `go.mod`. Bila aturan ini dilanggar, setiap perintah `go` berhenti dengan pesan error yang menyebutkan kedua versi tersebut.

Isi `go.work` sekarang:

#perintah[```
go 1.26.0

use ./account
```]

Tambahkan juga `.gitignore` agar hasil _build_ tidak ikut masuk ke Git.

*File `studi-kasus/.gitignore`*

#perintah[```
bin/
```]

=== Menjalankan PostgreSQL dengan Docker Compose

Database `account` dijalankan sebagai _container_ dari _image_ `postgres:18.6-alpine`. _Service_ Compose untuk database ini diberi nama `db-account`. Nama database dan nama _user_ sama-sama `account`, dengan _password_ `account123`. Kredensial ini hanya berlaku untuk lab lokal.

*File `studi-kasus/compose.yaml`*

#perintah[```yaml
# Lab infrastructure. Services run on the host (go run) and connect to these
# containers through the published ports (15432+, away from a locally installed
# PostgreSQL on 5432). One PostgreSQL container per service:
# database-per-service.
services:
  db-account:
    image: postgres:18.6-alpine
    environment:
      POSTGRES_DB: account
      POSTGRES_USER: account
      POSTGRES_PASSWORD: account123
    ports:
      - "15432:5432"
    volumes:
      - db-account:/var/lib/postgresql
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "account", "-d", "account"]
      interval: 2s
      retries: 30

volumes:
  db-account:
```]

Beberapa bagian perlu diperhatikan:

- `ports: "15432:5432"` membuka port 5432 di dalam _container_ sebagai port 15432 di laptop. _Service_ Go yang berjalan di laptop terhubung ke `localhost:15432`.
- _Volume_ `db-account` menyimpan data di luar _container_. Data tetap ada walaupun _container_ dihentikan atau dibuat ulang. Mulai PostgreSQL 18, _image_ resmi menyimpan data di bawah `/var/lib/postgresql`, sehingga _volume_ di-_mount_ ke direktori tersebut.
- `healthcheck` menjalankan `pg_isready` setiap 2 detik. Compose baru menganggap _container_ siap setelah pemeriksaan ini berhasil.

Perintah Compose dibungkus dalam `Makefile` di direktori `studi-kasus`. Seluruh perintah lab, termasuk langkah _pipeline_ CI/CD pada Lab 10, memanggil _target_ `make`, sehingga perintah yang dijalankan di laptop sama dengan yang dijalankan di server.

*File `studi-kasus/Makefile`*

#perintah[```makefile
SERVICES := account

.PHONY: infra-up infra-down infra-reset test

infra-up:
	docker compose up -d --wait

infra-down:
	docker compose down

# Removes the database volumes too: all lab data is lost.
infra-reset:
	docker compose down -v

test:
	@for s in $(SERVICES); do $(MAKE) -C $$s test || exit 1; done
```]

#note[Baris perintah di dalam _target_ `Makefile` wajib diawali karakter _tab_, tidak boleh spasi. Bila `make` menampilkan `missing separator`, ganti spasi di awal baris tersebut dengan _tab_.]

Opsi `--wait` membuat `docker compose up` menunggu hingga `healthcheck` berhasil sebelum perintah selesai. Jalankan infrastruktur lab:

#perintah[```bash
make infra-up
docker compose ps
```]

Kolom `STATUS` untuk `db-account` harus menampilkan `healthy`.

=== Konfigurasi dari Environment Variable

_Service_ membutuhkan dua nilai konfigurasi: alamat _listen_ HTTP _server_ dan URL koneksi database. Nilai tersebut berbeda di setiap tempat _service_ dijalankan (laptop, _container_, Kubernetes), sehingga dibaca dari _environment variable_.

Cara ini mengikuti _twelve-factor app_ (12-factor), yaitu dua belas prinsip untuk aplikasi yang dijalankan sebagai _service_ di _cloud_. Faktor III (_Config_) menetapkan bahwa nilai yang berbeda per _environment_ disimpan di _environment variable_, terpisah dari kode. Dengan cara tersebut, _image_ yang sama dapat dijalankan di laptop, di server _testing_, dan di _production_ hanya dengan mengganti nilai variabelnya. Tabel berikut memuat faktor yang diterapkan di studi kasus beserta lab tempat penerapannya. Daftar lengkap kedua belas faktor ada di materi presentasi Hari 1.

#table(
  columns: (1.2fr, 2.6fr, 0.6fr),
  table.header([Faktor], [Penerapan di Studi Kasus], [Lab]),
  [III. _Config_], [Seluruh konfigurasi dibaca dari _environment variable_, tanpa nilai _default_. Di Kubernetes, nilainya berasal dari ConfigMap dan Secret], [1, 9],
  [IV. _Backing services_], [Database, account service, Kafka, Hydra, dan _collector_ OpenTelemetry dijangkau melalui alamat dari konfigurasi, sehingga dapat diganti tanpa mengubah kode], [1, 2, 5, 7, 8],
  [V. _Build, release, run_], [Satu _image_ hasil _build_ digabungkan dengan konfigurasi per _environment_ saat _deploy_], [9, 10],
  [VI. _Processes_], [_Service_ tidak menyimpan _state_ di memori. Seluruh data disimpan di database], [1, 9],
  [VII. _Port binding_], [_Service_ membuka port HTTP sendiri (`HTTP_ADDR`), tanpa _web server_ terpisah. Port gRPC (`GRPC_ADDR`) menyusul di Lab 4], [1, 4],
  [IX. _Disposability_], [_Startup_ cepat dan _graceful shutdown_ saat menerima `SIGTERM`], [1, 9, 10],
  [XI. _Logs_], [_Service_ menulis _log_ sebagai aliran _event_ ke `stdout` (dan ke OTLP di Lab 8), tanpa mengelola _file log_. Penyimpanan dan pencarian _log_ menjadi tugas platform], [1, 8],
)

Setiap variabel bersifat wajib. Bila salah satu kosong, _service_ berhenti saat _startup_ dengan pesan error yang menyebutkan nama variabelnya. Nilai _default_ seperti `localhost:5432` sengaja tidak disediakan. Bila _service_ menggunakan nilai _default_ tanpa pesan apa pun dan terhubung ke database yang salah, penyebab masalahnya sulit ditemukan. _Service_ yang langsung berhenti dengan pesan error jauh lebih mudah diperbaiki.

*File `studi-kasus/account/config.go`*

#perintah[```go
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
		HTTPAddr:    get("HTTP_ADDR"),
		DatabaseURL: get("DATABASE_URL"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	return cfg, nil
}
```]

Fungsi `get` merupakan _closure_ yang mencatat setiap variabel kosong ke _slice_ `missing` milik `LoadConfig`. Dengan cara ini, _startup_ yang gagal langsung menampilkan sekaligus seluruh variabel yang belum diisi.

=== Model Domain dan Validasi

File `account.go` berisi struktur data rekening, data _request_ pembuatan rekening, aturan validasi, dan _interface_ `Store` untuk penyimpanan.

Saldo menggunakan `decimal.Decimal` dari _library_ `shopspring/decimal`, tidak menggunakan `float64`. Tipe `float64` menyimpan bilangan dalam basis dua, sehingga nilai seperti 0,1 tidak dapat disimpan secara tepat dan selisih pembulatan menumpuk pada setiap operasi. Untuk nilai uang, selisih sekecil apa pun tidak dapat diterima. Di database, saldo disimpan sebagai `numeric(19,2)` yang juga bersifat desimal tepat.

_Interface_ `Store` mendefinisikan operasi penyimpanan yang dibutuhkan _handler_ HTTP. _Handler_ bergantung pada _interface_ tersebut dan tidak mengenal PostgreSQL secara langsung. Akibatnya, _handler_ dapat diuji dengan _fake store_ di memori (langkah pengujian di akhir lab).

*File `studi-kasus/account/internal/account/account.go`*

#perintah[```go
// Package account holds the account domain: model, validation, storage, and HTTP API.
package account

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/shopspring/decimal"
)

type Account struct {
	Number    string          `json:"number"`
	OwnerName string          `json:"owner_name"`
	Balance   decimal.Decimal `json:"balance"`
	CreatedAt time.Time       `json:"created_at"`
}

type CreateRequest struct {
	Number         string          `json:"number"`
	OwnerName      string          `json:"owner_name"`
	InitialBalance decimal.Decimal `json:"initial_balance"`
}

var (
	ErrNotFound      = errors.New("account not found")
	ErrAlreadyExists = errors.New("account already exists")
)

// ValidationError maps field name to the problem found in that field.
type ValidationError map[string]string

func (v ValidationError) Error() string { return "validation failed" }

var numberPattern = regexp.MustCompile(`^[0-9]{10}$`)

func (r CreateRequest) Validate() error {
	v := ValidationError{}
	if !numberPattern.MatchString(r.Number) {
		v["number"] = "must be exactly 10 digits"
	}
	if strings.TrimSpace(r.OwnerName) == "" {
		v["owner_name"] = "must not be empty"
	}
	if r.InitialBalance.IsNegative() {
		v["initial_balance"] = "must not be negative"
	}
	if len(v) > 0 {
		return v
	}
	return nil
}

// Store is the persistence contract; the HTTP handler depends on this, not on PostgreSQL.
type Store interface {
	Create(ctx context.Context, req CreateRequest) (Account, error)
	Get(ctx context.Context, number string) (Account, error)
	List(ctx context.Context) ([]Account, error)
	Ping(ctx context.Context) error
}
```]

Hal yang perlu dicermati pada file ini:

- _Struct tag_ seperti `json:"owner_name"` menentukan nama _field_ di JSON. Nama _field_ di Go diawali huruf kapital agar dapat diakses _package_ `encoding/json`.
- `ErrNotFound` dan `ErrAlreadyExists` adalah _sentinel error_: nilai error tetap yang nanti diperiksa dengan `errors.Is` untuk menentukan kode status HTTP.
- `ValidationError` adalah `map[string]string` yang memiliki _method_ `Error()`, sehingga memenuhi _interface_ `error`. Saat dikirim sebagai JSON, nilai ini menjadi objek berisi nama _field_ dan masalahnya. Seluruh _field_ diperiksa sekaligus, sehingga klien menerima semua kesalahan dalam satu respons.
- `Validate` mengembalikan `nil` secara eksplisit bila tidak ada kesalahan. Mengembalikan `v` yang kosong akan menghasilkan _interface_ `error` yang tidak `nil`, karena _interface_ yang berisi nilai bertipe `ValidationError` dianggap tidak `nil` walaupun _map_-nya kosong.

=== Skema Tabel dan Store PostgreSQL

Skema tabel ditulis dalam file SQL terpisah lalu di-_embed_ ke dalam _binary_ dengan `go:embed`. _Service_ menjalankan skema tersebut pada setiap _startup_. Klausa `if not exists` membuat perintah aman dijalankan berulang kali. Cara ini cukup untuk lab, sedangkan sistem sungguhan umumnya menggunakan _tools_ migrasi skema yang mencatat versi skema.

*File `studi-kasus/account/internal/account/schema.sql`*

#perintah[```sql
create table if not exists account (
    number     varchar(10)    primary key,
    owner_name varchar(100)   not null,
    balance    numeric(19, 2) not null check (balance >= 0),
    created_at timestamptz    not null default now()
);
```]

_Constraint_ `check (balance >= 0)` menjaga saldo agar tidak pernah negatif, bahkan bila ada kode yang lupa memeriksanya. Aturan bisnis yang paling penting sebaiknya juga dijaga oleh database.

Implementasi `Store` menggunakan `pgxpool`, yaitu _connection pool_ dari pgx. _Pool_ menyimpan beberapa koneksi yang dapat digunakan bergantian oleh _request_ yang datang bersamaan. Kolom `numeric` PostgreSQL dibaca ke `decimal.Decimal`. Tanpa _codec_ tambahan, pgx sudah dapat membacanya melalui _interface_ `sql.Scanner`, tetapi nilainya dikonversi lewat teks terlebih dahulu. _Package_ `pgx-shopspring-decimal` mendaftarkan _codec_ khusus pada setiap koneksi baru melalui `AfterConnect`, sehingga konversi `numeric` dilakukan langsung tanpa melalui teks.

*File `studi-kasus/account/internal/account/store.go`*

#perintah[```go
package account

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

func (s *PostgresStore) Create(ctx context.Context, req CreateRequest) (Account, error) {
	rows, err := s.pool.Query(ctx, `
		insert into account (number, owner_name, balance)
		values (@number, @owner_name, @balance)
		returning number, owner_name, balance, created_at`,
		pgx.NamedArgs{"number": req.Number, "owner_name": req.OwnerName, "balance": req.InitialBalance})
	if err != nil {
		return Account{}, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
		return Account{}, ErrAlreadyExists
	}
	return a, err
}

func (s *PostgresStore) Get(ctx context.Context, number string) (Account, error) {
	rows, err := s.pool.Query(ctx,
		`select number, owner_name, balance, created_at from account where number = @number`,
		pgx.NamedArgs{"number": number})
	if err != nil {
		return Account{}, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
	if errors.Is(err, pgx.ErrNoRows) {
		return Account{}, ErrNotFound
	}
	return a, err
}

func (s *PostgresStore) List(ctx context.Context) ([]Account, error) {
	rows, err := s.pool.Query(ctx,
		`select number, owner_name, balance, created_at from account order by number limit 100`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Account])
}
```]

Penjelasan bagian penting:

- *_Named parameter_.* `pgx.NamedArgs` mengisi `@number`, `@owner_name`, dan `@balance`. Nilai dikirim terpisah dari teks SQL, sehingga kode aman dari _SQL injection_. Teks SQL tidak boleh disusun dengan menggabungkan _string_ dari input pengguna.
- *Pemetaan baris ke _struct_.* `pgx.RowToStructByPos[Account]` mengisi _field_ `Account` sesuai urutan kolom. Urutan kolom pada `select` dan `returning` harus sama dengan urutan _field_ di _struct_ `Account`.
- *Penanganan nomor rekening ganda.* Rekening dengan nomor yang sudah ada melanggar _primary key_, dan PostgreSQL mengembalikan kode error `23505` (`unique_violation`). Kode tersebut dipetakan menjadi `ErrAlreadyExists`, sehingga _handler_ tidak perlu mengenal kode error PostgreSQL.
- *Rekening yang tidak ditemukan.* `CollectExactlyOneRow` mengembalikan `pgx.ErrNoRows` bila hasil _query_ kosong, dan `Get` memetakannya menjadi `ErrNotFound`.
- *Batas jumlah data.* `List` dibatasi 100 baris agar satu _request_ tidak memuat seluruh tabel. Pada sistem sungguhan, batas ini digantikan _pagination_.

=== Handler HTTP dan Routing

Sejak Go 1.22, `http.ServeMux` bawaan Go mendukung pola yang memuat _method_ dan _path_ sekaligus, misalnya `"GET /accounts/{number}"`. Nilai `{number}` dibaca dengan `r.PathValue("number")`. Fitur ini sudah mencukupi untuk API pada studi kasus, sehingga _router_ pihak ketiga seperti chi atau gin tidak diperlukan. `ServeMux` juga otomatis mengembalikan status `405 Method Not Allowed` bila _path_ cocok tetapi _method_-nya tidak terdaftar.

Bagian ini juga menyediakan dua _endpoint_ _health check_, `/healthz` (_liveness_) dan `/readyz` (_readiness_). Perbedaan keduanya dibahas di bagian berikutnya, setelah kode _handler_.

*File `studi-kasus/account/internal/account/http.go`*

#perintah[```go
package account

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"
)

type Handler struct {
	store Store
	log   *slog.Logger
}

func NewHandler(store Store, log *slog.Logger) *Handler {
	return &Handler{store: store, log: log}
}

// Routes uses the Go 1.22+ ServeMux patterns: method + path, with {wildcards}.
func (h *Handler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /accounts", h.create)
	mux.HandleFunc("GET /accounts", h.list)
	mux.HandleFunc("GET /accounts/{number}", h.get)
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	return mux
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req CreateRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return
	}
	if err := req.Validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "fields": err})
		return
	}
	a, err := h.store.Create(r.Context(), req)
	switch {
	case errors.Is(err, ErrAlreadyExists):
		writeError(w, http.StatusConflict, err.Error())
	case err != nil:
		h.internalError(w, r, err)
	default:
		w.Header().Set("Location", "/accounts/"+a.Number)
		writeJSON(w, http.StatusCreated, a)
	}
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	a, err := h.store.Get(r.Context(), r.PathValue("number"))
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case err != nil:
		h.internalError(w, r, err)
	default:
		writeJSON(w, http.StatusOK, a)
	}
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	accounts, err := h.store.List(r.Context())
	if err != nil {
		h.internalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, accounts)
}

// healthz (liveness): the process is up and serving HTTP. No dependency checks here,
// otherwise a database outage makes Kubernetes restart every healthy pod.
func (h *Handler) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
}

// readyz (readiness): the service can do useful work, i.e. the database answers.
func (h *Handler) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.store.Ping(ctx); err != nil {
		// Connection details stay in the log; callers only learn that the database is down.
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

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
```]

Alur `create` mengikuti urutan yang umum pada _handler_ REST:

+ *Membaca _body_.* `http.MaxBytesReader` membatasi ukuran _body_ hingga 1 MiB, sehingga _request_ berukuran sangat besar tidak menghabiskan memori. `DisallowUnknownFields` menolak _field_ yang tidak dikenal, sehingga salah ketik seperti `"nomor"` langsung menghasilkan error dan tidak diabaikan begitu saja.
+ *Validasi.* Kesalahan input dijawab dengan status 400 beserta daftar _field_ yang bermasalah.
+ *Menyimpan.* Error dari `Store` dipetakan ke kode status HTTP: `ErrAlreadyExists` menjadi 409, error lain menjadi 500.
+ *Menjawab.* _Handler_ mengirim rekening baru dengan status 201 dan _header_ `Location` yang menunjuk ke alamat rekening tersebut.

Error yang tidak terduga ditangani `internalError`, yang menulis detail error ke _log_ dan hanya mengirim `"internal error"` ke klien. Detail seperti nama tabel atau alamat database tidak boleh terkirim ke klien. Prinsip yang sama berlaku pada `readyz`.

=== _Liveness_ dan _Readiness_ <lab01-liveness-readiness>

Kedua _endpoint_ sama-sama mengembalikan 200 saat _service_ sehat, tetapi menjawab pertanyaan yang berbeda, dan hasilnya memicu tindakan yang berbeda pula. Tindakan tersebut dijalankan oleh platform. Di lab ini belum ada platform yang membaca hasilnya, sehingga keduanya diperiksa manual dengan `curl` (bagian Verifikasi). Kubernetes mulai menggunakannya di Lab 9.

#table(
  columns: (1fr, 1.9fr, 1.9fr),
  table.header([Aspek], [`/healthz` (_liveness_)], [`/readyz` (_readiness_)]),
  [Pertanyaan], [Apakah proses ini masih berjalan normal, atau macet sehingga perlu dijalankan ulang?], [Apakah _instance_ ini boleh menerima _request_ saat ini?],
  [Yang diperiksa di studi kasus], [Tidak ada dependensi. Selama proses dapat menjawab HTTP, hasilnya 200], [`Ping` ke database milik _service_ itu sendiri dengan _timeout_ 2 detik. Hasilnya 503 bila database tidak menjawab],
  [Tindakan Kubernetes saat gagal], [kubelet me-_restart_ _container_ setelah beberapa kegagalan berturut-turut], [_Pod_ dikeluarkan dari daftar _endpoint_ Service sehingga tidak menerima _request_ baru. _Container_ tidak di-_restart_, dan _pod_ kembali menerima _request_ begitu `/readyz` kembali 200],
  [Kesalahan desain yang umum], [Ikut memeriksa database: saat database terganggu, semua _pod_ di-_restart_ bersamaan, padahal _restart_ tidak memperbaiki database], [Ikut memeriksa _service_ lain: gangguan di satu _service_ membuat semua pemanggilnya ikut keluar dari Service (kegagalan berantai)],
)

Tabel berikut menunjukkan hasil kedua _endpoint_ pada beberapa kondisi, beserta tindakan Kubernetes di Lab 9:

#{
  set text(size: 9pt)
  table(
    columns: (1.15fr, 1.05fr, 1.05fr, 1.45fr, 1.6fr),
    table.header([Kondisi], [`/healthz`], [`/readyz`], [Tindakan Kubernetes], [Alasan]),
    [_Startup_, _service_ sedang membuka koneksi ke database],
    [Belum menjawab, karena HTTP _server_ baru dibuka setelah koneksi database berhasil],
    [Belum menjawab],
    [_Pod_ belum _ready_ dan belum menerima _request_. Bila database tidak dapat dihubungi, _service_ berhenti dengan error, lalu kubelet menjalankan ulang _container_],
    [_Request_ tidak boleh sampai ke _instance_ yang belum siap],

    [Database mati sementara],
    [200],
    [503],
    [_Pod_ dikeluarkan dari Service, tidak di-_restart_],
    [_Restart_ tidak memperbaiki database. _Connection pool_ membuka koneksi baru setelah database kembali berjalan],

    [Proses macet dan tidak lagi menjawab HTTP],
    [Tidak menjawab dalam batas waktu _probe_],
    [Tidak menjawab],
    [kubelet me-_restart_ _container_],
    [Proses yang macet hanya dapat dipulihkan dengan menjalankannya ulang],

    [_Overload_, _request_ menumpuk],
    [200, tetapi bisa melewati batas waktu _probe_],
    [Lambat, atau 503 bila _ping_ ke database melewati 2 detik],
    [_Readiness_ yang gagal mengeluarkan _pod_ sementara dari Service. _Liveness_ baru memicu _restart_ setelah 3 kegagalan berturut-turut],
    [Ambang _liveness_ dibuat longgar. _Restart_ saat beban tinggi memindahkan beban ke _pod_ lain dan memperparah keadaan. _Overload_ diatasi dengan menambah _replica_ (Hari 4)],

    [`account` lambat atau mati, dilihat dari `transfer`],
    [200],
    [200, karena `/readyz` milik `transfer` tidak memeriksa `account`],
    [Tidak ada. _Pod_ `transfer` tetap menerima _request_],
    [Gangguan `account` ditangani _circuit breaker_ (Lab 3). _Request_ yang tidak membutuhkan `account`, misalnya membaca status transfer, tetap dilayani],
  )
}

Pertanyaan yang sering muncul: mengapa perlu dua _probe_, padahal _service_ yang hidup tetapi tidak siap juga tidak berguna? Jawabannya, gangguan terbagi dua jenis yang membutuhkan tindakan berbeda. Gangguan jenis pertama hilang dengan sendirinya, misalnya database yang sementara mati atau beban sesaat. _Pod_ cukup berhenti menerima _request_ sambil menunggu, dan _restart_ justru tidak membantu. Gangguan jenis kedua hanya hilang dengan _restart_, misalnya proses yang macet (baris ketiga tabel di atas). Tindakan untuk kedua jenis gangguan tersebut berlawanan, sehingga satu _probe_ tidak cukup. Bila satu _probe_ memicu _restart_, gangguan database membuat semua _pod_ di-_restart_. Bila _probe_ tersebut hanya menghentikan _request_, _pod_ yang macet tetap macet selamanya. Karena itu _readiness_ menangani jenis pertama dan _liveness_ menangani jenis kedua.

Kubernetes juga menyediakan _startup probe_ untuk _service_ yang membutuhkan waktu lama saat _startup_, misalnya karena memuat data dalam jumlah besar. Selama _startup probe_ belum berhasil, _liveness_ dan _readiness probe_ belum dijalankan, sehingga _service_ tersebut tidak di-_restart_ sebelum selesai _startup_. _Service_ di studi kasus selesai _startup_ dalam waktu kurang dari satu detik, sehingga tidak memerlukan _startup probe_.

=== Program Utama dan Graceful Shutdown

`main.go` merangkai seluruh bagian: membaca konfigurasi, membuka koneksi database, lalu menjalankan HTTP _server_. Logika tersebut ditempatkan di fungsi `run` yang mengembalikan `error`, sehingga `main` cukup mencatat error dan keluar dengan kode 1. Perintah `defer` di dalam `run`, misalnya `store.Close()`, tetap dijalankan sebelum program berakhir. Bila `os.Exit` dipanggil langsung di tengah logika, `defer` tidak sempat dijalankan.

_Graceful shutdown_ berarti _service_ yang menerima sinyal berhenti (Ctrl+C atau `SIGTERM` dari Docker dan Kubernetes) tidak langsung mati. _Server_ berhenti menerima koneksi baru, menyelesaikan _request_ yang sedang diproses (maksimal 10 detik), lalu menutup koneksi database.

*File `studi-kasus/account/main.go`*

#perintah[```go
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

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/account"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("account service stopped", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}

	// ctx is cancelled on Ctrl+C (SIGINT) or on SIGTERM from Docker/Kubernetes.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	store, err := account.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           account.NewHandler(store, log).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("account service listening", "addr", cfg.HTTPAddr)
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
```]

Beberapa konsep Go yang muncul di sini:

- `signal.NotifyContext` menghasilkan `context` yang dibatalkan ketika sinyal `SIGINT` atau `SIGTERM` diterima.
- `srv.ListenAndServe()` bersifat _blocking_, sehingga dijalankan di _goroutine_ tersendiri. Hasilnya dikirim ke _channel_ `errCh`.
- `select` menunggu salah satu dari dua kejadian: _server_ gagal (misalnya port sudah digunakan) atau sinyal berhenti diterima.
- `ReadHeaderTimeout` membatasi waktu klien mengirim _header_ HTTP. Tanpa batas ini, klien yang sangat lambat dapat menahan koneksi selamanya.
- _Logger_ `slog` menulis _log_ terstruktur berformat `key=value`. Pada Lab 8, format ini diganti menjadi JSON dan dilengkapi _correlation ID_.

=== Dependensi dan Makefile per Service

Tambahkan _library_ yang digunakan dengan `go get`, pada versi yang sama seperti _checkpoint_:

#perintah[```bash
cd account
go get github.com/jackc/pgx/v5@v5.11.0 \
  github.com/shopspring/decimal@v1.6.0 \
  github.com/jackc/pgx-shopspring-decimal@v0.0.0-20220624020537-1d36b5a1853e
go mod tidy
cd ..
```]

`go mod tidy` menyesuaikan `go.mod` dengan _import_ yang benar-benar ada di kode dan melengkapi `go.sum`. Kedua file tersebut di-_commit_ bersama kode.

Setiap _service_ memiliki `Makefile` sendiri dengan _target_ `run`, `test`, dan `build`. _Target_ `run` mengisi kedua _environment variable_ dengan nilai untuk laptop. Nilai ini hanya ada di `Makefile`, tidak di dalam kode Go.

*File `studi-kasus/account/Makefile`*

#perintah[```makefile
# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := account

.PHONY: run test build clean

run:
	HTTP_ADDR=:28081 \
	DATABASE_URL=postgres://account:account123@localhost:15432/account \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
```]

_Target_ `build` menggunakan `CGO_ENABLED=0` agar menghasilkan _static binary_ yang tidak bergantung pada _library_ C di sistem operasi. _Binary_ seperti ini dapat dijalankan di _image_ kosong (`FROM scratch`) pada Lab 9.

Semua _service_ studi kasus menggunakan port di rentang 2xxxx, misalnya 28081 untuk `account`, sedangkan infrastruktur lab menggunakan rentang 1xxxx, sehingga tidak bentrok dengan aplikasi lain di laptop yang biasanya menggunakan port 8xxx.

Jalankan _service_:

#perintah[```bash
make -C account run
```]

Baris terakhir _output_ yang diharapkan (waktu akan berbeda):

#perintah[```
time=2026-10-26T09:15:02.123+07:00 level=INFO msg="account service listening" addr=:28081
```]

Biarkan terminal ini tetap berjalan, lalu buka terminal kedua untuk langkah berikutnya (unit test dan verifikasi).

=== Unit Test untuk Handler dengan Fake Store

_Handler_ HTTP diuji tanpa PostgreSQL. `fakeStore` mengimplementasikan _interface_ `Store` dengan _map_ di memori, lalu `httptest.NewRecorder` menangkap respons _handler_ tanpa membuka port jaringan. Test ini berjalan dalam hitungan milidetik dan dapat dijalankan di _pipeline_ CI yang tidak memiliki database.

Test disusun sebagai _table-driven test_: setiap baris tabel berisi satu skenario (_method_, _path_, _body_, status yang diharapkan, dan potongan _body_ respons yang diharapkan). Menambah skenario cukup dengan menambah satu baris.

*File `studi-kasus/account/internal/account/http_test.go`*

#perintah[```go
package account

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeStore keeps accounts in memory so the HTTP layer is tested without PostgreSQL.
type fakeStore struct {
	accounts map[string]Account
	pingErr  error
}

func newFakeStore() *fakeStore { return &fakeStore{accounts: map[string]Account{}} }

func (f *fakeStore) Create(_ context.Context, req CreateRequest) (Account, error) {
	if _, ok := f.accounts[req.Number]; ok {
		return Account{}, ErrAlreadyExists
	}
	a := Account{Number: req.Number, OwnerName: req.OwnerName, Balance: req.InitialBalance, CreatedAt: time.Now()}
	f.accounts[a.Number] = a
	return a, nil
}

func (f *fakeStore) Get(_ context.Context, number string) (Account, error) {
	a, ok := f.accounts[number]
	if !ok {
		return Account{}, ErrNotFound
	}
	return a, nil
}

func (f *fakeStore) List(context.Context) ([]Account, error) {
	var out []Account
	for _, a := range f.accounts {
		out = append(out, a)
	}
	return out, nil
}

func (f *fakeStore) Ping(context.Context) error { return f.pingErr }

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
	return rec
}

func TestAccountAPI(t *testing.T) {
	h := NewHandler(newFakeStore(), slog.New(slog.NewTextHandler(io.Discard, nil))).Routes()

	tests := []struct {
		name, method, path, body string
		wantStatus               int
		wantBody                 string
	}{
		{"create", "POST", "/accounts", `{"number":"1234567890","owner_name":"Budi","initial_balance":"500000"}`, 201, `"balance":"500000"`},
		{"duplicate", "POST", "/accounts", `{"number":"1234567890","owner_name":"Budi","initial_balance":"0"}`, 409, "already exists"},
		{"invalid fields", "POST", "/accounts", `{"number":"12","owner_name":" ","initial_balance":"-1"}`, 400, `"number":"must be exactly 10 digits"`},
		{"unknown field", "POST", "/accounts", `{"nomor":"1234567890"}`, 400, "unknown field"},
		{"get", "GET", "/accounts/1234567890", "", 200, `"owner_name":"Budi"`},
		{"not found", "GET", "/accounts/0000000000", "", 404, "not found"},
		{"wrong method", "DELETE", "/accounts/1234567890", "", 405, ""},
		{"liveness", "GET", "/healthz", "", 200, "UP"},
		{"readiness", "GET", "/readyz", "", 200, `"database":"UP"`},
	}
	// Subtests run in order and share the handler: "duplicate" and "get" rely on "create".
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, tc.method, tc.path, tc.body)
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body: %s", rec.Code, tc.wantStatus, rec.Body)
			}
			if !strings.Contains(rec.Body.String(), tc.wantBody) {
				t.Fatalf("body %q does not contain %q", rec.Body, tc.wantBody)
			}
		})
	}
}

func TestReadinessDown(t *testing.T) {
	store := newFakeStore()
	store.pingErr = context.DeadlineExceeded
	h := NewHandler(store, slog.New(slog.NewTextHandler(io.Discard, nil))).Routes()
	if rec := do(t, h, "GET", "/readyz", ""); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}
```]

Skenario `"wrong method"` memastikan pola `ServeMux` benar-benar membedakan _method_: `DELETE` ke _path_ yang hanya terdaftar untuk `GET` menghasilkan 405. `TestReadinessDown` mensimulasikan database yang tidak menjawab dengan membuat `Ping` mengembalikan error.

Jalankan seluruh test dari direktori `studi-kasus`:

#perintah[```bash
make test
```]

_Output_ yang diharapkan:

#perintah[```
go vet ./...
go test ./...
?   	github.com/artivisi/training-microservices-2026-01/studi-kasus/account	[no test files]
ok  	github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/account	0.012s
```]

Pada Linux, `make` juga menampilkan baris `make[1]: Entering directory` dan `make[1]: Leaving directory`. Durasi test akan berbeda di setiap laptop.
Untuk melihat setiap skenario, jalankan `go test -v ./...` dari direktori `account`.

== Verifikasi

Jalankan perintah berikut di terminal kedua, sementara `make -C account run` masih berjalan di terminal pertama. Setiap respons JSON tampil dalam satu baris. Nama _field_ pada objek JSON yang berasal dari _map_ Go selalu diurutkan secara alfabetis.

*1. _Liveness_ dan _readiness_.*

#perintah[```bash
curl -i http://localhost:28081/healthz
curl -i http://localhost:28081/readyz
```]

Keduanya mengembalikan `HTTP/1.1 200 OK` dengan _header_ `Content-Type: application/json`. _Body_ masing-masing:

#perintah[```
{"status":"UP"}
{"database":"UP","status":"UP"}
```]

*2. Membuat rekening.* Nilai uang dikirim sebagai _string_ JSON agar tidak melewati konversi `float` di sisi klien.

#perintah[```bash
curl -i -X POST http://localhost:28081/accounts \
  -H 'Content-Type: application/json' \
  -d '{"number":"1234567890","owner_name":"Budi Santoso","initial_balance":"500000"}'

curl -sS -X POST http://localhost:28081/accounts \
  -H 'Content-Type: application/json' \
  -d '{"number":"9876543210","owner_name":"Siti Aminah","initial_balance":"250000.50"}'
```]

Perintah pertama menghasilkan `HTTP/1.1 201 Created`, _header_ `Location: /accounts/1234567890`, dan _body_ seperti berikut (nilai `created_at` akan berbeda):

#perintah[```
{"number":"1234567890","owner_name":"Budi Santoso","balance":"500000","created_at":"2026-10-26T09:16:40.512345+07:00"}
```]

Saldo `500000` disimpan di database sebagai `500000.00`. Angka nol di belakang koma tidak ditampilkan oleh `decimal.Decimal`, sehingga rekening kedua menampilkan saldo `"250000.5"`.

*3. Membaca rekening.*

#perintah[```bash
curl -sS http://localhost:28081/accounts/1234567890
curl -sS http://localhost:28081/accounts
```]

Perintah pertama mengembalikan satu objek rekening. Perintah kedua mengembalikan _array_ berisi kedua rekening, diurutkan menurut nomor rekening. Sebelum ada rekening sama sekali, `GET /accounts` mengembalikan `[]`.

*4. Kasus gagal.*

#perintah[```bash
# nomor rekening yang sama: 409
curl -sS -w ' %{http_code}\n' -X POST http://localhost:28081/accounts \
  -H 'Content-Type: application/json' \
  -d '{"number":"1234567890","owner_name":"Budi","initial_balance":"0"}'

# validasi gagal: 400
curl -sS -w ' %{http_code}\n' -X POST http://localhost:28081/accounts \
  -H 'Content-Type: application/json' \
  -d '{"number":"12","owner_name":" ","initial_balance":"-1"}'

# field tidak dikenal: 400
curl -sS -w ' %{http_code}\n' -X POST http://localhost:28081/accounts \
  -H 'Content-Type: application/json' \
  -d '{"nomor":"1234567890"}'

# rekening tidak ada: 404
curl -sS -w ' %{http_code}\n' http://localhost:28081/accounts/0000000000

# method tidak terdaftar: 405
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE http://localhost:28081/accounts/1234567890
```]

_Output_ yang diharapkan, berurutan:

#perintah[```
{"error":"account already exists"}
 409
{"error":"validation failed","fields":{"initial_balance":"must not be negative","number":"must be exactly 10 digits","owner_name":"must not be empty"}}
 400
{"error":"invalid JSON body: json: unknown field \"nomor\""}
 400
{"error":"account not found"}
 404
405
```]

Kode status tampil di baris berikutnya karena `json.Encoder` menambahkan karakter _newline_ di akhir setiap respons JSON.

*5. _Readiness_ saat database mati.* Hentikan _container_ database, periksa `/readyz` dan `/healthz`, lalu jalankan kembali database:

#perintah[```bash
docker compose stop db-account
curl -sS -w ' %{http_code}\n' http://localhost:28081/readyz
curl -sS -w ' %{http_code}\n' http://localhost:28081/healthz
docker compose start db-account
```]

_Output_ yang diharapkan:

#perintah[```
{"database":"DOWN","status":"DOWN"}
 503
{"status":"UP"}
 200
```]

Terminal pertama menampilkan _log_ `level=WARN msg="readiness check failed"` beserta detail error koneksi, sedangkan respons ke klien hanya berisi status. Setelah database kembali berjalan, `/readyz` kembali mengembalikan 200 tanpa perlu me-_restart_ _service_, karena _connection pool_ membuka koneksi baru.

*6. Data tetap tersimpan.* Hentikan _service_ dengan Ctrl+C. _Log_ menampilkan `msg="shutting down"`. Jalankan ulang `make -C account run`, lalu panggil `GET /accounts`. Kedua rekening masih ada karena data tersimpan di _volume_ Docker.

*7. Konfigurasi wajib.* Jalankan _service_ tanpa _environment variable_ dari direktori `account`:

#perintah[```bash
cd account
go run .
cd ..
```]

_Output_ yang diharapkan:

#perintah[```
time=... level=ERROR msg="account service stopped" error="missing required environment variables: HTTP_ADDR, DATABASE_URL"
exit status 1
```]

== Masalah Umum

#table(
  columns: (1fr, 1fr, 1.4fr),
  table.header([Gejala], [Penyebab], [Solusi]),
  [`make infra-up` gagal dengan `port is already allocated`],
  [Port 15432 sudah digunakan program lain, misalnya _container_ dari latihan sebelumnya],
  [Periksa dengan `docker ps` dan hentikan _container_ yang menggunakan port tersebut. Pada Linux dan macOS, `lsof -i :15432` menampilkan proses yang menggunakan port],
  [_Service_ berhenti dengan `connect to database: ... connection refused`],
  [_Container_ `db-account` belum berjalan atau belum `healthy`],
  [Jalankan `make infra-up` dan pastikan `docker compose ps` menampilkan status `healthy`],
  [_Service_ berhenti dengan `password authentication failed for user "account"`],
  [_Volume_ `db-account` dibuat sebelumnya dengan kredensial lain. PostgreSQL hanya membaca `POSTGRES_PASSWORD` saat _volume_ masih kosong],
  [Jalankan `make infra-reset` lalu `make infra-up`. Seluruh data lab di database akan terhapus],
  [`go: module ... listed in go.work file requires go >= 1.27...`],
  [Versi Go di `go.mod` lebih tinggi dibandingkan versi di `go.work`],
  [Jalankan `go mod edit -go=1.26.0` di direktori `account` dan `go work edit -go=1.26.0` di direktori `studi-kasus`],
  [`make: *** missing separator`],
  [Baris perintah di `Makefile` diawali spasi],
  [Ganti spasi di awal baris perintah dengan karakter _tab_],
  [`listen tcp :28081: bind: address already in use`],
  [_Service_ `account` dari terminal lain masih berjalan],
  [Hentikan proses lama dengan Ctrl+C di terminal tersebut, lalu jalankan ulang],
  [_Field_ `balance` atau `created_at` kosong atau tertukar pada respons],
  [Urutan kolom di `select`/`returning` tidak sama dengan urutan _field_ di _struct_ `Account`],
  [Samakan urutan kolom dengan urutan _field_: `number`, `owner_name`, `balance`, `created_at`],
)

== Eksplorasi Mandiri

+ *Menambah _endpoint_ penutupan rekening.* Tambahkan `DELETE /accounts/{number}` yang hanya berhasil bila saldo rekening nol. Tentukan kode status yang tepat untuk rekening yang tidak ditemukan dan untuk rekening yang saldonya belum nol, lalu tambahkan skenarionya ke tabel test. Skenario `"wrong method"` yang sudah ada perlu diperbarui.
+ *_Pagination_.* Ubah `GET /accounts` agar menerima parameter `limit` dan `after` (nomor rekening terakhir pada halaman sebelumnya), misalnya `GET /accounts?limit=10&after=1234567890`. Validasi `limit` antara 1 dan 100, dan jawab 400 bila nilainya di luar rentang.
+ *Test ke database sungguhan.* Tulis test untuk `PostgresStore` yang terhubung ke `db-account`. URL database dibaca dari _environment variable_ `TEST_DATABASE_URL`, dan test dilewati dengan `t.Skip` bila variabel tersebut kosong. Test tersebut harus memastikan bahwa rekening ganda menghasilkan `ErrAlreadyExists` dan saldo negatif ditolak oleh _constraint_ `check`.
+ *Melihat isi database.* Masuk ke database dengan `docker compose exec db-account psql -U account -d account`, lalu jalankan `\d account` dan `select * from account;`. Bandingkan nilai `balance` di database dengan nilai pada respons JSON.

== Checkpoint

Kondisi kode di akhir lab ini tersimpan di tag `lab-01`. Untuk membandingkan hasil pekerjaan dengan _checkpoint_, jalankan dari direktori `studi-kasus`:

#perintah[```bash
git diff lab-01 -- .
```]

Perbedaan pada `README.md` dapat diabaikan, karena isi file tersebut disediakan oleh _checkpoint_ dan tidak ditulis pada langkah lab.

Bila hasil pekerjaan belum selesai atau tidak dapat dijalankan, simpan pekerjaan lalu lanjutkan dari _checkpoint_:

#perintah[```bash
git add -A && git commit -m "Lab 1 (pekerjaan sendiri)"
git checkout -b lab-01-checkpoint lab-01
```]

Lab 2 dimulai dari kondisi ini: _service_ `account` berjalan di port 28081 dengan database `db-account`. Lab 2 menambahkan _service_ `transfer` yang memanggil API `account` melalui REST.
