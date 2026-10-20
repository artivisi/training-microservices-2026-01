// Day 1 deck: architecture, Go essentials, service foundation (Labs 1-2).
// Build: make CLIENT="..." Deck-Hari-1-Microservices-2026-10.pdf
#import "../_template/deck.typ": *

#show: deck.with(
  title: "Arsitektur Microservices dan Fondasi Service Go",
  subtitle: "Hari 1: monolith dan microservices, penentuan batas service, Go essentials, serta account service dan transfer service",
  day-label: "Hari 1",
  client: sys.inputs.at("client"),
  date: "Oktober 2026",
)

// Sequence-diagram helpers for this deck.
#let lifeline(x, top, bottom) = at(x, top, line(angle: 90deg, length: bottom - top,
  stroke: (paint: faint, thickness: 1pt, dash: "dashed")))
#let msg(y, x1, x2, label, dash: none) = {
  let left-x = calc.min(x1 / 1pt, x2 / 1pt) * 1pt
  let w = calc.abs((x2 - x1) / 1pt) * 1pt
  edge((x1, y), (x2, y), dash: dash)
  at(left-x, y - 16pt, box(width: w, align(center, text(size: 12pt, fill: slate, label))))
}
#let step-note(x, y, body) = at(x, y - 9pt, box(fill: cream, stroke: 0.6pt + border, radius: 3pt,
  inset: (x: 6pt, y: 3pt), text(size: 12pt, fill: ink, body)))

// ── Pembuka ────────────────────────────────────────────────────────────────

#slide(kicker: "Hari 1", title: "Agenda Hari 1")[
  #table(
    columns: (auto, 1fr, auto),
    [Waktu], [Topik], [Format],
    [09:00–09:45], [Monolith dan microservices: _trade-off_, kondisi yang membuat microservices merugikan, gejala _distributed monolith_], [Presentasi],
    [09:45–10:30], [_Service decomposition_: kapabilitas bisnis, _bounded context_, dekomposisi studi kasus perbankan], [Presentasi dan diskusi],
    [10:45–12:00], [Go _essentials_ untuk service: _module_, _struct_, _interface_, _error handling_, _goroutine_ dan _channel_, `net/http`], [Presentasi dan demo],
    [12:00–12:30], [Anatomi service Go: struktur _project_, _routing_, validasi, konfigurasi, _health check_], [Demo],
    [13:30–15:00], [*Lab 1*: account service dengan REST, PostgreSQL, dan _health check_], [_Hands-on_],
    [15:15–16:30], [*Lab 2*: transfer service sebagai service kedua, komunikasi REST pertama], [_Hands-on_],
  )
]

#slide(kicker: "Peta training", title: "Materi dan lab selama empat hari")[
  #table(
    columns: (auto, 1fr, 1.3fr),
    [Hari], [Tema], [Lab],
    [1], [Arsitektur, Go _essentials_, fondasi service], [Lab 1 account service; Lab 2 transfer service dengan REST],
    [2], [_Resiliency_ dan gRPC], [Lab 3 _timeout_, _retry_, _circuit breaker_; Lab 4 transfer ke account melalui gRPC],
    [3], [_Messaging_, konsistensi data, _security_], [Lab 5 saga, _outbox_, Kafka; Lab 6 _idempotent consumer_; Lab 7 JWT],
    [4], [_Observability_, _deployment_, CI/CD], [Lab 8 _tracing_ di Grafana; Lab 9 _deploy_ ke k3d; Lab 10 _pipeline_ CI/CD],
  )
  #v(10pt)
  #note[Setiap lab melanjutkan kode dari lab sebelumnya. Di akhir Hari 4, sistem yang sama sudah berjalan di Kubernetes dan dirilis melalui _pipeline_ CI/CD.]
]

#slide(kicker: "Studi kasus", title: "Sistem perbankan sederhana di akhir Hari 4")[
  #diagram(height: 320pt,
    at(0pt, 125pt, node("channel", sub: "aplikasi klien", kind: "ext", width: 100pt)),
    at(150pt, 125pt, node("transfer", sub: "HTTP :28082")),
    at(390pt, 20pt, node("account", sub: "HTTP :28081")),
    at(600pt, 13pt, node("db-account", sub: "PostgreSQL", kind: "db", width: 120pt, height: 70pt)),
    at(150pt, 240pt, node("db-transfer", sub: "PostgreSQL", kind: "db", width: 120pt, height: 70pt)),
    at(390pt, 230pt, node("Kafka", sub: "transfer-events", kind: "broker", width: 130pt)),
    at(590pt, 230pt, node("notification", sub: "HTTP :28083")),
    at(740pt, 223pt, node("db-notif.", sub: "PostgreSQL", kind: "db", width: 110pt, height: 70pt)),
    edge((100pt, 153pt), (150pt, 153pt), label: "REST", label-dy: -18pt),
    edge((50pt, 125pt), (390pt, 40pt), label: "REST", label-dx: -60pt),
    edge((270pt, 140pt), (390pt, 55pt), label: "gRPC (Hari 2)", label-dx: -30pt),
    edge((270pt, 166pt), (390pt, 250pt), label: "event (Hari 3)", dash: "dashed", label-dx: -30pt, label-dy: 4pt),
    edge((510pt, 48pt), (600pt, 48pt)),
    edge((520pt, 258pt), (590pt, 258pt)),
    edge((710pt, 258pt), (740pt, 258pt)),
    edge((210pt, 181pt), (210pt, 240pt), both: true),
  )
  #align(center, legend(("svc", "service"), ("db", "database"), ("broker", "broker"), ("ext", "klien")))
]

#slide(kicker: "Studi kasus", title: "Kondisi kode di akhir setiap lab")[
  #set table(inset: 5pt)
  #table(
    columns: (auto, 1fr),
    [Lab], [Yang ditambahkan ke sistem],
    [1], [Account service: REST, PostgreSQL, validasi, _health check_],
    [2], [Transfer service dengan database sendiri, memanggil account melalui REST],
    [3], [_Timeout_, _retry_, dan _circuit breaker_ (failsafe-go) pada panggilan transfer ke account],
    [4], [Kontrak protobuf; transfer memanggil account melalui gRPC dengan _interceptor_],
    [5], [Saga dengan kompensasi, _transactional outbox_, Kafka, notification service],
    [6], [_Idempotent consumer_ dan _idempotency key_ pada `POST /transfers`],
    [7], [Token OAuth2 dari authorization server, validasi JWT di REST dan gRPC],
    [8], [_Structured log_, _correlation ID_, metrik Prometheus, _trace_ OpenTelemetry, Grafana],
    [9], [Dockerfile _multi-stage_ dan _manifest_ Kubernetes, berjalan di k3d],
    [10], [_Pipeline_ CI/CD per service: _test_, _build image_, _push_, _deploy_],
  )
  #v(6pt)
  #text(size: 12.5pt)[Setiap kondisi akhir lab tersedia sebagai _git tag_ (`lab-01` … `lab-10`). Peserta yang tertinggal melanjutkan dari _tag_ lab sebelumnya dengan `git checkout lab-NN`.]
]

// ── 01 Monolith dan microservices ─────────────────────────────────────────

#section-slide(number: "01", title: "Monolith dan Microservices", subtitle: [_Trade-off_ kedua arsitektur dan gejala _distributed monolith_])

#slide(kicker: "Konsep", title: "Ciri monolith")[
  #two-col(
    card("Ciri")[
      - Seluruh fitur dirilis sebagai satu _deployable unit_
      - Seluruh data tersimpan di satu database
      - Modul saling memanggil melalui _function call_ di dalam proses yang sama
      - Satu transaksi ACID dapat mencakup perubahan di banyak tabel
    ],
    card("Kelebihan yang sering terlupakan", accent: gold.darken(15%))[
      - _Debugging_ cukup di satu proses, dengan satu _stack trace_
      - _Refactoring_ lintas modul dibantu _compiler_
      - Satu _pipeline_ dan satu jadwal rilis
      - Pemanggilan antarmodul tidak menanggung latensi jaringan
    ],
  )
  #v(10pt)
  #note[Monolith yang modular, dengan batas modul yang rapi, tetap menjadi pilihan yang wajar untuk banyak sistem.]
]

#slide(kicker: "Konsep", title: "Ciri microservices")[
  #two-col(
    card("Ciri")[
      - Setiap service dirilis secara terpisah
      - Setiap service memiliki database sendiri
      - Service berkomunikasi melalui jaringan: REST, gRPC, atau _message broker_
      - Tim pemilik service dapat merilis tanpa menunggu tim lain
    ],
    card("Konsekuensi", accent: amber)[
      - Panggilan jaringan bisa lambat atau gagal di tengah jalan
      - Perubahan di dua service tidak dapat dibungkus satu transaksi database
      - Jumlah _pipeline_, database, dan proses yang harus dipantau bertambah
      - Penelusuran masalah membutuhkan _log_ dan _trace_ lintas service
    ],
  )
]

#slide(kicker: "Konsep", title: [_Trade-off_ monolith dan microservices])[
  #table(
    columns: (auto, 1fr, 1fr),
    [Aspek], [Monolith], [Microservices],
    [_Deployment_], [Seluruh aplikasi dirilis sekaligus], [Setiap service dirilis terpisah],
    [Skalabilitas], [Seluruh aplikasi diperbanyak bersama], [Hanya service yang sibuk yang diperbanyak],
    [Konsistensi data], [Satu transaksi database], [Saga, _outbox_, dan _idempotency_ (Hari 2–3)],
    [Kegagalan], [Proses mati, seluruh aplikasi berhenti], [Kegagalan parsial, perlu _timeout_ dan _circuit breaker_ (Hari 2)],
    [_Debugging_], [_Stack trace_ dalam satu proses], [_Distributed tracing_ lintas service (Hari 4)],
    [Beban operasional], [Satu aplikasi, satu database], [Banyak _deployable unit_, _pipeline_, dan database],
  )
]

#slide(kicker: "Konsep", title: "Kondisi yang membuat microservices merugikan")[
  #bullets(
    [*Tim kecil.* Bila satu tim mengelola semua service, tidak ada koordinasi antartim yang berkurang, sedangkan beban operasional tetap bertambah.],
    [*Batas domain belum jelas.* Batas service yang salah jauh lebih sulit diperbaiki dibandingkan batas modul di dalam satu aplikasi.],
    [*Belum ada otomasi.* Tanpa _pipeline_ dan _observability_, setiap service tambahan menambah pekerjaan manual.],
    [*Beban merata.* Bila semua fitur menerima beban yang serupa, pemecahan tidak menambah kemampuan skala.],
  )
  #v(4pt)
  #note(kind: "tip")[Microservices layak dipertimbangkan ketika ada kebutuhan konkret: tim yang harus merilis secara independen, atau bagian sistem dengan kebutuhan skala yang berbeda jauh.]
]

#slide(kicker: "Gejala", title: [Gejala _distributed monolith_])[
  #two-col(ratio: (1.15fr, 1fr),
    [
      #text(size: 14pt)[Sistem sudah terpecah menjadi banyak service, tetapi masih harus dirilis dan dijalankan bersama-sama.]
      #v(6pt)
      #bullets(size: 13.5pt,
        [Beberapa service harus di-_deploy_ bersamaan],
        [Satu service mati, seluruh alur bisnis berhenti],
        [Service membaca tabel milik service lain secara langsung],
        [Perubahan satu kontrak API memaksa banyak service ikut berubah],
      )
    ],
    [
      #diagram(height: 250pt,
        at(0pt, 0pt, node("transfer", width: 110pt)),
        at(220pt, 0pt, node("account", width: 110pt)),
        at(110pt, 150pt, node("db bersama", kind: "db", width: 120pt, height: 70pt)),
        edge((55pt, 56pt), (140pt, 150pt), color: red),
        edge((275pt, 56pt), (200pt, 150pt)),
        at(0pt, 92pt, text(size: 10pt, fill: red)[`select … from account`]),
      )
      #text(size: 11.5pt, fill: slate)[Transfer service membaca tabel `account` secara langsung, sehingga setiap perubahan skema tabel tersebut ikut merusak transfer service.]
    ],
  )
]

// ── 02 Service decomposition ──────────────────────────────────────────────

#section-slide(number: "02", title: "Service Decomposition", subtitle: [Menentukan batas service dengan kapabilitas bisnis dan _bounded context_])

#slide(kicker: "Konsep", title: [Kapabilitas bisnis dan _bounded context_])[
  #two-col(
    card("Kapabilitas bisnis")[
      Hal yang dikerjakan organisasi, terlepas dari cara aplikasi mengerjakannya: mengelola rekening, memindahkan dana, memberi tahu nasabah.

      Kapabilitas bisnis jarang berubah, sehingga menjadi acuan batas service yang stabil.
    ],
    card([_Bounded context_], accent: gold.darken(15%))[
      Batas berlakunya satu model domain. Di dalam batas tersebut, setiap istilah hanya memiliki satu arti.

      Contoh: bagi account service, transfer hanyalah dua mutasi saldo. Bagi transfer service, transfer memiliki status, alasan gagal, dan riwayat.
    ],
  )
]

#slide(kicker: "Konsep", title: "Tiga acuan penentuan batas service")[
  #enum(
    spacing: 14pt,
    [*Service memiliki datanya sendiri.* Service lain hanya mengakses data tersebut melalui API, tidak melalui _query_ ke tabelnya.],
    [*Service dapat dirilis tanpa koordinasi lintas tim.* Rilis account service tidak menunggu jadwal rilis transfer service.],
    [*Perubahan satu kebutuhan bisnis idealnya cukup di satu service.* Bila setiap fitur baru menyentuh tiga service, batasnya perlu ditinjau ulang.],
  )
  #v(10pt)
  #note[Ketiga acuan ini sekaligus menjadi alat uji: batas service yang melanggar salah satunya akan mengarah ke _distributed monolith_.]
]

#slide(kicker: "Kesalahan umum", title: "Pemecahan service yang keliru")[
  #two-col(
    card([Dipecah menurut _layer_ teknis], accent: red)[
      Contoh: service "database", service "validasi", service "API".

      Setiap fitur baru menyentuh semua service tersebut, sehingga rilisnya tetap harus serempak.
    ],
    card("Dipecah terlalu kecil", accent: red)[
      Contoh: satu service per tabel, misalnya service "nasabah", service "saldo", service "mutasi".

      Satu operasi bisnis membutuhkan banyak panggilan jaringan, dan konsistensi data harus dijaga lintas service untuk hal yang seharusnya cukup satu transaksi.
    ],
  )
]

#slide(kicker: "Studi kasus", title: "Dekomposisi sistem perbankan")[
  #table(
    columns: (auto, 1fr, 1fr, 1fr),
    [Service], [Kapabilitas], [Data yang dimiliki], [Pemanggil],
    [account], [Mengelola rekening dan saldo], [Tabel `account` dan `mutation`], [Aplikasi klien (REST), transfer service],
    [transfer], [Memindahkan dana antarrekening], [Tabel `transfer`], [Aplikasi klien (REST)],
    [notification], [Memberi tahu hasil transfer (Hari 3)], [Tabel `notification`], [Tidak dipanggil langsung; membaca _event_ dari Kafka],
  )
  #v(10pt)
  #note[Transfer dipisahkan dari account karena aturan transfer (status, kompensasi, _idempotency_) berubah karena alasan dan pada waktu yang berbeda dari pengelolaan rekening. Saldo tetap hanya diubah oleh account service.]
]

#slide(kicker: "Studi kasus", title: [_Database per service_])[
  #two-col(ratio: (1fr, 1fr),
    [
      #diagram(height: 260pt,
        at(0pt, 20pt, node("transfer", sub: ":28082")),
        at(230pt, 20pt, node("account", sub: ":28081")),
        at(0pt, 160pt, node("db-transfer", sub: "port 15433", kind: "db", width: 120pt, height: 70pt)),
        at(230pt, 160pt, node("db-account", sub: "port 15432", kind: "db", width: 120pt, height: 70pt)),
        edge((120pt, 48pt), (230pt, 48pt), label: "REST"),
        edge((60pt, 76pt), (60pt, 160pt)),
        edge((290pt, 76pt), (290pt, 160pt)),
      )
    ],
    [
      #bullets(size: 13.5pt,
        [Setiap service memiliki _container_ PostgreSQL sendiri di `compose.yaml`.],
        [Transfer service tidak memiliki koneksi ke `db-account`; data rekening hanya diperoleh melalui API account.],
        [Konsekuensinya, _join_ lintas service tidak tersedia, dan debit serta credit tidak dapat dibungkus satu transaksi database.],
      )
    ],
  )
]

#code-slide(kicker: "Konsekuensi", title: "Debit dan credit tidak dapat dibungkus satu transaksi database",
  side: [
    Di monolith, debit dan credit cukup dibungkus satu transaksi: bila salah satu gagal, keduanya dibatalkan.

    Di microservices, debit dan credit menjadi dua panggilan jaringan ke account service. Bila credit gagal setelah debit berhasil, tidak ada _rollback_ otomatis.

    - Hari 1: transfer dicatat `FAILED` dan masuk _log_
    - Hari 2: konsep saga dan _idempotency key_
    - Hari 3: saga dengan kompensasi
  ],
)[
```sql
-- Monolith: satu database, satu transaksi
begin;
update account set balance = balance - 100000
 where number = '1000000001';
update account set balance = balance + 100000
 where number = '1000000002';
commit;
```
```text
# Microservices: dua panggilan jaringan
transfer -> account  POST /accounts/1000000001/debit
transfer -> account  POST /accounts/1000000002/credit
                     (gagal? debit sudah terjadi)
```
]

// ── 03 Go essentials ───────────────────────────────────────────────────────

#section-slide(number: "03", title: "Go Essentials untuk Service", subtitle: [Fitur bahasa yang langsung digunakan di lab, secukupnya untuk menulis dan membaca kode service])

#code-slide(kicker: "Go essentials", title: [_Module_ dan _workspace_],
  side: [
    - Setiap _module_ didefinisikan oleh `go.mod` dan memiliki versi serta dependensi sendiri.
    - Setiap service menjadi _module_ sendiri, sehingga dapat di-_build_ dan dirilis terpisah.
    - `go.work` menggabungkan beberapa _module_ lokal agar `go build` dan editor mengenali semuanya sekaligus.
  ],
)[
```go
// studi-kasus/go.work
go 1.26.0

use (
    ./account
    ./transfer
)
```
```go
// studi-kasus/account/go.mod
module github.com/artivisi/training-microservices-2026-01/studi-kasus/account

go 1.26.0

require (
    github.com/jackc/pgx-shopspring-decimal v0.0.0-20220624020537-1d36b5a1853e
    github.com/jackc/pgx/v5 v5.11.0
    github.com/shopspring/decimal v1.6.0
)
```
]

#code-slide(kicker: "Go essentials", title: [_Struct_ dan JSON],
  side: [
    - _Struct tag_ `json:"..."` menentukan nama _field_ di JSON.
    - Nominal uang menggunakan `decimal.Decimal`, disimpan sebagai `numeric(19,2)`.
    - `float64` tidak dapat menyimpan 0.1 secara tepat, sehingga selisih pembulatan menumpuk pada saldo.
    - Kolom `numeric` dipetakan ke `decimal.Decimal` dengan mendaftarkan `pgxdecimal.Register` di `AfterConnect`.
  ],
)[
```go
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
```
]

#code-slide(kicker: "Go essentials", title: [_Interface_],
  side: [
    - _Interface_ didefinisikan di sisi pengguna, yaitu _handler_.
    - Implementasi PostgreSQL memenuhi _interface_ secara implisit, tanpa kata kunci `implements`.
    - _Unit test_ untuk _handler_ cukup menggunakan implementasi _in-memory_.
  ],
)[
```go
// Store is the persistence contract; the HTTP handler
// depends on this, not on PostgreSQL.
type Store interface {
    Create(ctx context.Context, req CreateRequest) (Account, error)
    Get(ctx context.Context, number string) (Account, error)
    List(ctx context.Context) ([]Account, error)
    Mutate(ctx context.Context, number string,
        t MutationType, req MutationRequest) (Account, error)
    Ping(ctx context.Context) error
}

type Handler struct {
    store Store
    log   *slog.Logger
}
```
]

#code-slide(kicker: "Go essentials", title: [_Error handling_],
  side: [
    - _Error_ berupa nilai biasa yang dikembalikan fungsi dan diperiksa tepat setelah pemanggilan.
    - `%w` membungkus _error_ dengan konteks tambahan tanpa menghilangkan identitas _error_ asalnya.
    - `errors.Is` memeriksa seluruh rantai bungkusan, sehingga _handler_ transfer tetap mengenali `ErrInsufficientFunds`.
  ],
)[
```go
// package transfer
var (
    ErrAccountNotFound   = errors.New("account not found")
    ErrInsufficientFunds = errors.New("insufficient funds")
)

// package accountclient: bungkus dengan konteks
case http.StatusUnprocessableEntity:
    return fmt.Errorf("%s %s: %w", kind, number,
        transfer.ErrInsufficientFunds)

// handler transfer: kenali jenis error, lalu pilih status
t, err := h.svc.Execute(ctx, req)
switch {
case err == nil:
    writeJSON(w, http.StatusCreated, t)
case errors.Is(err, ErrAccountNotFound),
    errors.Is(err, ErrInsufficientFunds):
    writeJSON(w, http.StatusUnprocessableEntity, t)
default:
    writeJSON(w, http.StatusBadGateway, t)
}
```
]

#code-slide(kicker: "Go essentials", title: [_Goroutine_ dan _channel_],
  side: [
    - `go func()` menjalankan fungsi secara konkuren di _goroutine_ baru.
    - _Channel_ `errCh` mengirim hasil dari _goroutine_ tersebut ke fungsi `run`.
    - `select` berhenti menunggu begitu salah satu kejadian terjadi: server berhenti karena _error_, atau sistem operasi mengirim sinyal berhenti.
  ],
)[
```go
errCh := make(chan error, 1)
go func() {
    log.Info("account service listening", "addr", cfg.HTTPAddr)
    errCh <- srv.ListenAndServe()
}()

select {
case err := <-errCh:
    return err          // server gagal start, misalnya port terpakai
case <-ctx.Done():
    log.Info("shutting down")
    // lanjut ke graceful shutdown
}
```
]

#code-slide(kicker: "Go essentials", title: [`context.Context`],
  side: [
    - `context` membawa batas waktu dan sinyal pembatalan ke seluruh rantai pemanggilan.
    - `signal.NotifyContext` membatalkan `ctx` ketika menerima Ctrl+C atau `SIGTERM` dari Docker dan Kubernetes.
    - `WithTimeout` membatasi waktu satu operasi, misalnya _ping_ ke database.
    - Setiap fungsi yang mengakses jaringan atau database menerima `ctx` sebagai parameter pertama.
  ],
)[
```go
// dibatalkan saat Ctrl+C atau SIGTERM
ctx, stop := signal.NotifyContext(context.Background(),
    os.Interrupt, syscall.SIGTERM)
defer stop()

// batas waktu 2 detik untuk satu operasi
ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
defer cancel()
if err := h.store.Ping(ctx); err != nil {
    // database tidak menjawab dalam 2 detik
}
```
]

#code-slide(kicker: "Go essentials", title: [`net/http`: _handler_ dan _middleware_],
  side: [
    - Setiap tipe yang memiliki _method_ `ServeHTTP` dapat menangani _request_.
    - `http.HandlerFunc` mengubah fungsi biasa menjadi _handler_.
    - _Middleware_ berupa fungsi yang menerima _handler_ dan mengembalikan _handler_ baru. Pola ini digunakan kembali untuk _fault injection_ (Hari 2), JWT (Hari 3), dan metrik (Hari 4).
  ],
)[
```go
type Handler interface {
    ServeHTTP(http.ResponseWriter, *http.Request)
}

// middleware: wraps a handler and returns a new one
func logging(log *slog.Logger, next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        next.ServeHTTP(w, r)
        log.Info("request", "method", r.Method,
            "path", r.URL.Path, "took", time.Since(start))
    })
}
```
]

// ── 04 Anatomi service Go ──────────────────────────────────────────────────

#section-slide(number: "04", title: "Anatomi Service Go", subtitle: [Struktur _project_, _routing_, validasi, konfigurasi, dan _health check_])

#code-slide(kicker: "Anatomi service", title: [Struktur _project_],
  side: [
    - Kode dikelompokkan per fitur (_package-by-feature_) di bawah `internal/`.
    - _Package_ di `internal/` tidak dapat di-_import_ oleh _module_ lain.
    - `main.go` hanya merangkai komponen; logika bisnis berada di _package_ domain.
    - Setiap service memiliki `Makefile` sendiri. Target yang sama nantinya dipanggil _pipeline_ CI.
  ],
)[
```text
studi-kasus/
├── go.work
├── compose.yaml        # PostgreSQL per service
├── Makefile            # infra-up, infra-down, test
├── account/
│   ├── go.mod
│   ├── main.go         # run(): rangkai komponen, server
│   ├── config.go       # LoadConfig dari environment
│   ├── Makefile        # run, test, build
│   └── internal/
│       ├── account/    # model, validasi, store, HTTP
│       └── fault/      # fault injection (Hari 2)
└── transfer/
    ├── main.go, config.go, Makefile
    └── internal/
        ├── transfer/       # model, service, store, HTTP
        └── accountclient/  # client REST ke account
```
]

#code-slide(kicker: "Anatomi service", title: [_Routing_ dengan `ServeMux`],
  side: [
    - Sejak Go 1.22, pola _route_ memuat _method_ dan _path_ sekaligus.
    - `{number}` dibaca dengan `r.PathValue("number")`.
    - _Request_ dengan _method_ yang tidak terdaftar otomatis mendapat _response_ `405 Method Not Allowed`.
    - Kebutuhan _routing_ di lab terpenuhi tanpa _router_ pihak ketiga.
  ],
)[
```go
func (h *Handler) Routes() *http.ServeMux {
    mux := http.NewServeMux()
    mux.HandleFunc("POST /accounts", h.create)
    mux.HandleFunc("GET /accounts", h.list)
    mux.HandleFunc("GET /accounts/{number}", h.get)
    mux.HandleFunc("POST /accounts/{number}/debit", h.mutate(Debit))
    mux.HandleFunc("POST /accounts/{number}/credit", h.mutate(Credit))
    mux.HandleFunc("GET /healthz", h.healthz)
    mux.HandleFunc("GET /readyz", h.readyz)
    return mux
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
    a, err := h.store.Get(r.Context(), r.PathValue("number"))
    // ...
}
```
]

#code-slide(kicker: "Anatomi service", title: "Validasi input",
  side: [
    - Validasi berjalan sebelum data menyentuh database.
    - `ValidationError` mengumpulkan semua _field_ yang bermasalah, sehingga klien menerima seluruh daftar kesalahan dalam satu _response_.
    - JSON dengan _field_ yang tidak dikenal ditolak (`DisallowUnknownFields`).
  ],
)[
```go
type ValidationError map[string]string

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
```
```json
HTTP 400
{"error": "validation failed",
 "fields": {"number": "must be exactly 10 digits"}}
```
]

#code-slide(kicker: "Anatomi service", title: [Konfigurasi dari _environment variable_],
  side: [
    - Konfigurasi hanya dibaca dari _environment variable_ (prinsip _12-factor_), sehingga _image_ yang sama berjalan di laptop, CI, dan Kubernetes.
    - Semua variabel wajib diisi dan tidak ada nilai _default_.
    - Variabel yang kosong menghentikan service saat _startup_ dengan _error_ yang menyebut nama variabelnya.
  ],
)[
```go
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
        return Config{}, fmt.Errorf(
            "missing required environment variables: %s",
            strings.Join(missing, ", "))
    }
    return cfg, nil
}
```
```text
level=ERROR msg="account service stopped"
  error="missing required environment variables: DATABASE_URL"
```
]

#slide(kicker: "Anatomi service", title: [_Health check_: _liveness_ dan _readiness_])[
  #table(
    columns: (auto, 1fr, 1fr, 1fr),
    [_Endpoint_], [Pertanyaan yang dijawab], [Yang diperiksa], [Akibat bila gagal di Kubernetes],
    [`GET /healthz`], [Apakah proses masih hidup dan melayani HTTP?], [Tidak ada dependensi yang diperiksa], [_Pod_ di-_restart_],
    [`GET /readyz`], [Apakah service siap mengerjakan _request_?], [Database milik service sendiri menjawab _ping_ dalam 2 detik], [_Pod_ dikeluarkan sementara dari daftar tujuan _traffic_],
  )
  #v(10pt)
  #note(kind: "warn")[Database tidak diperiksa di _liveness_. Bila database mati dan _liveness_ ikut gagal, Kubernetes me-_restart_ semua _pod_ yang sebenarnya sehat, padahal _restart_ tidak memperbaiki database.]
  #v(4pt)
  #note[_Readiness_ transfer service hanya memeriksa database transfer. Gangguan di account service ditangani dengan _resiliency_ (Hari 2) dan tidak mengeluarkan transfer service dari daftar tujuan _traffic_.]
]

#code-slide(kicker: "Anatomi service", title: [_Graceful shutdown_],
  side: [
    - Saat menerima `SIGTERM`, server berhenti menerima koneksi baru.
    - `srv.Shutdown` menunggu _request_ yang sedang berjalan selesai, dengan batas 10 detik.
    - Batas ini berbeda per service. Sejak Lab 5, transfer menunggu hingga 60 detik agar saga tidak terpotong di antara debit dan credit.
    - _Rolling update_ di Kubernetes (Hari 4) mengandalkan perilaku ini agar tidak ada transfer yang terputus di tengah proses.
  ],
)[
```go
srv := &http.Server{
    Addr:              cfg.HTTPAddr,
    Handler:           mux,
    ReadHeaderTimeout: 5 * time.Second,
}
// ... server berjalan di goroutine, lihat slide sebelumnya

case <-ctx.Done():
    log.Info("shutting down")
    shutdownCtx, cancel := context.WithTimeout(
        context.Background(), 10*time.Second)
    defer cancel()
    if err := srv.Shutdown(shutdownCtx); err != nil &&
        !errors.Is(err, http.ErrServerClosed) {
        return err
    }
    return nil
```
]

#slide(kicker: "Anatomi service", title: [Pemetaan _error_ ke status HTTP])[
  #table(
    columns: (1fr, auto, auto),
    [Kondisi], [_Error_ di Go], [Status HTTP],
    [_Body_ berisi JSON yang tidak valid atau memuat _field_ tak dikenal], [_decode_ gagal], [`400`],
    [Isi _field_ tidak memenuhi aturan], [`ValidationError`], [`400` beserta daftar _field_],
    [Nomor rekening sudah terdaftar], [`ErrAlreadyExists`], [`409`],
    [Rekening tidak ditemukan], [`ErrNotFound`], [`404`],
    [Saldo tidak mencukupi untuk debit], [`ErrInsufficientFunds`], [`422`],
    [_Error_ lain, misalnya database terputus], [_error_ apa pun], [`500`],
  )
  #v(10pt)
  #note[Untuk status `500`, klien hanya menerima `"internal error"`. Detail _error_ seperti alamat database atau isi _query_ hanya ditulis ke _log_.]
]

// ── 05 Lab 1 ───────────────────────────────────────────────────────────────

#section-slide(number: "05", title: "Lab 1: Account Service", subtitle: [REST, PostgreSQL, validasi, dan _health check_])

#slide(kicker: "Lab 1", title: "Mengembangkan account service dari nol")[
  #two-col(ratio: (1.2fr, 1fr),
    [
      #card("Tujuan")[
        Service pertama yang berjalan lengkap: menerima _request_ REST, memvalidasi input, menyimpan data ke database miliknya sendiri, dan melaporkan kondisinya melalui _health check_.
      ]
      #v(8pt)
      #card("Yang dikerjakan", accent: gold.darken(15%))[
        - `POST /accounts`, `GET /accounts`, `GET /accounts/{number}`
        - `POST /accounts/{number}/debit` dan `/credit` beserta tabel `mutation`
        - `GET /healthz` dan `GET /readyz`
        - `LoadConfig` dengan variabel wajib `HTTP_ADDR` dan `DATABASE_URL`
      ]
    ],
    [
      #card("Rujukan", accent: slate)[
        - Langkah lengkap: *Panduan Lab, bab Lab 1*
        - Kondisi akhir: _tag_ `lab-01`
        - Port: HTTP `28081`, PostgreSQL `15432`
      ]
      #v(8pt)
      #note(kind: "tip")[Jalankan `make test` sebelum melanjutkan ke Lab 2. _Test handler_ menggunakan `httptest` tanpa database.]
    ],
  )
]

#slide(kicker: "Lab 1", title: "Menjalankan dan mencoba account service")[
  #flow(
    node("curl", kind: "ext", width: 90pt),
    arr(label: "HTTP :28081", length: 110pt),
    node("account", sub: "go run"),
    arr(label: "pgx", length: 80pt),
    node("db-account", sub: "port 15432", kind: "db", width: 120pt, height: 64pt),
  )
  #v(14pt)
```bash
cd studi-kasus
make infra-up                 # PostgreSQL di Docker Compose
make -C account run           # HTTP_ADDR=:28081, DATABASE_URL=...localhost:15432

curl -s -X POST localhost:28081/accounts -H 'Content-Type: application/json' \
  -d '{"number":"1000000001","owner_name":"Budi","initial_balance":"500000.00"}'
curl -s localhost:28081/accounts/1000000001
curl -s localhost:28081/readyz
```
]

#code-slide(kicker: "Lab 1", title: "Mencegah saldo negatif saat dua debit bersamaan",
  side: [
    - Pemeriksaan saldo berada di klausa `where`. Dua debit yang datang bersamaan tidak dapat sama-sama lolos: debit kedua menunggu _row lock_, lalu kondisinya dievaluasi ulang dengan saldo terbaru.
    - Perubahan saldo dan baris `mutation` ditulis dalam satu transaksi.
    - _Constraint_ `check (balance >= 0)` menjadi pengaman terakhir di database.
  ],
)[
```go
tx, err := s.pool.Begin(ctx)
// ...
defer tx.Rollback(ctx) // no-op after Commit

rows, err := tx.Query(ctx, `
    update account set balance = balance + @delta
    where number = @number and balance + @delta >= 0
    returning number, owner_name, balance, created_at`,
    pgx.NamedArgs{"number": number, "delta": delta})
// tidak ada baris: rekening tidak ada, atau saldo kurang

_, err = tx.Exec(ctx, `
    insert into mutation (account_number, type, amount, reference)
    values (@number, @type, @amount, @reference)`, ...)
return a, tx.Commit(ctx)
```
]

// ── 06 Lab 2 ───────────────────────────────────────────────────────────────

#section-slide(number: "06", title: "Lab 2: Transfer Service", subtitle: [Dua service, dua database, dan komunikasi REST pertama])

#slide(kicker: "Lab 2", title: "Mengembangkan transfer service sebagai service kedua")[
  #two-col(ratio: (1.2fr, 1fr),
    [
      #card("Tujuan")[
        Mengalami langsung komunikasi antarservice: transfer service menyimpan transfer di database sendiri, lalu meminta account service melakukan debit dan credit melalui REST.
      ]
      #v(8pt)
      #card("Yang dikerjakan", accent: gold.darken(15%))[
        - `POST /transfers` dan `GET /transfers/{id}`
        - Tabel `transfer` dengan status `PENDING`, `COMPLETED`, `FAILED`
        - _Package_ `accountclient`: client REST ke account service
        - Variabel wajib baru: `ACCOUNT_SERVICE_URL`
      ]
    ],
    [
      #card("Rujukan", accent: slate)[
        - Langkah lengkap: *Panduan Lab, bab Lab 2*
        - Kondisi akhir: _tag_ `lab-02`
        - Port: HTTP `28082`, PostgreSQL `15433`
      ]
      #v(8pt)
      #note[Account service dari Lab 1 harus tetap berjalan di port `28081` selama Lab 2.]
    ],
  )
]

#slide(kicker: "Lab 2", title: "Alur transfer yang berhasil")[
  #diagram(height: 360pt,
    at(40pt, 0pt, node("aplikasi klien", kind: "ext", height: 40pt)),
    at(372pt, 0pt, node("transfer", sub: ":28082", height: 40pt)),
    at(704pt, 0pt, node("account", sub: ":28081", height: 40pt)),
    lifeline(100pt, 40pt, 350pt),
    lifeline(432pt, 40pt, 350pt),
    lifeline(764pt, 40pt, 350pt),
    msg(75pt, 100pt, 432pt, [`POST /transfers`]),
    step-note(442pt, 112pt, [simpan transfer, status `PENDING`]),
    msg(155pt, 432pt, 764pt, [`POST /accounts/{from}/debit`]),
    msg(195pt, 764pt, 432pt, [`200 OK`], dash: "dashed"),
    msg(240pt, 432pt, 764pt, [`POST /accounts/{to}/credit`]),
    msg(280pt, 764pt, 432pt, [`200 OK`], dash: "dashed"),
    step-note(442pt, 310pt, [ubah status menjadi `COMPLETED`]),
    msg(340pt, 432pt, 100pt, [`201 Created`], dash: "dashed"),
  )
]

#code-slide(kicker: "Lab 2", title: [Status transfer dan _response_ HTTP],
  side: [
    #table(
      columns: (1fr, auto),
      [Hasil], [HTTP],
      [Transfer selesai], [`201`],
      [Rekening tidak ada atau saldo kurang], [`422`],
      [Account service gagal atau tidak dapat dihubungi], [`502`],
    )
    #v(4pt)
    Transfer yang gagal tetap tersimpan dengan status `FAILED` dan `failure_reason`, sehingga dapat ditelusuri melalui `GET /transfers/{id}`.
  ],
)[
```go
func (s *Service) Execute(ctx context.Context,
    req CreateRequest) (Transfer, error) {
    t, err := s.store.Create(ctx, req) // PENDING
    if err != nil {
        return Transfer{}, fmt.Errorf("record transfer: %w", err)
    }
    if err := s.accounts.Debit(ctx, t.FromAccount,
        t.Amount, t.ID); err != nil {
        return s.fail(ctx, t, "debit failed", err)
    }
    if err := s.accounts.Credit(ctx, t.ToAccount,
        t.Amount, t.ID); err != nil {
        return s.fail(ctx, t, "credit failed after debit", err)
    }
    return s.store.Finish(ctx, t.ID, Completed, "")
}
```
]

#slide(kicker: "Lab 2", title: "Celah yang sengaja dibiarkan di Lab 2")[
  #two-col(
    card([Client tanpa _timeout_], accent: amber)[
      `accountclient` menggunakan `http.Client` tanpa _timeout_. Bila account service lambat, setiap transfer ikut menunggu tanpa batas, dan _goroutine_ serta koneksi menumpuk di transfer service.

      #v(4pt)
      *Ditangani di Lab 3* dengan _timeout_, _retry_, dan _circuit breaker_.
    ],
    card("Credit gagal setelah debit", accent: red)[
      Dana sudah keluar dari rekening sumber, tetapi tidak sampai di rekening tujuan. Transfer dicatat `FAILED` dan _log_ meminta _reversal_ manual.

      #v(4pt)
      *Ditangani di Lab 5* dengan saga: debit yang sudah terjadi dibatalkan melalui transaksi kompensasi.
    ],
  )
  #v(12pt)
  #note(kind: "tip")[Lab 3 diawali dengan _fault injection_ pada account service (`PUT /admin/fault`) untuk menyuntikkan _delay_ dan _error_, sehingga kedua celah ini terlihat langsung.]
]

// ── Penutup ────────────────────────────────────────────────────────────────

#slide(kicker: "Penutup Hari 1", title: "Ringkasan dan persiapan Hari 2")[
  #two-col(
    card("Hasil Hari 1")[
      - Batas service ditentukan dari kapabilitas bisnis dan kepemilikan data
      - Account service dan transfer service berjalan dengan database masing-masing
      - Konfigurasi wajib dari _environment variable_, tanpa nilai _default_
      - _Liveness_ dan _readiness_ dipisahkan sejak awal
      - Transfer memanggil account melalui REST, dengan dua celah yang tercatat
    ],
    card("Persiapan Hari 2", accent: gold.darken(15%))[
      - Pastikan `make test` lulus dan kode sesuai _tag_ `lab-02`
      - Pastikan `protoc`, `protoc-gen-go`, dan `protoc-gen-go-grpc` terpasang (Lab 4)
      - Topik Hari 2: service lambat dan service mati, _timeout_, _retry_, _circuit breaker_, gRPC, serta konsistensi data lintas service
    ],
  )
]
