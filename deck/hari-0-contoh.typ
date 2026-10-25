// Template showcase: exercises every helper in _template/deck.typ.
// Build: make sample CLIENT="PT Contoh Klien"
#import "../_template/deck.typ": *

#show: deck.with(
  title: "Contoh Template Slide",
  subtitle: "Semua komponen template dalam satu deck: slide, card, bullets, kode, diagram, catatan",
  day-label: "Hari 0 · Contoh",
  client: sys.inputs.at("client"),
  date: "Oktober 2026",
)

#section-slide(number: "01", title: "Arsitektur Microservices", subtitle: [Monolith, microservices, dan gejala _distributed monolith_])

#slide(kicker: "Konsep", title: "Monolith vs microservices")[
  #two-col(
    card("Monolith")[
      - Satu _deployable unit_, satu database
      - Transaksi lokal: ACID cukup
      - Skala seluruh aplikasi sekaligus
    ],
    card("Microservices", accent: gold.darken(15%))[
      - Satu service, satu database
      - Konsistensi lintas service: saga
      - Skala per service
    ],
  )
  #v(12pt)
  #chip("account") #chip("transfer") #chip("notification", c: amber) #chip("Go 1.25", c: gold.darken(20%))
]

#slide(kicker: "Gejala", title: [_Distributed monolith_])[
  #bullets(
    [Service harus di-_deploy_ bersamaan],
    [Satu service mati, seluruh alur berhenti],
    [Tabel dibaca langsung oleh service lain],
    [Perubahan kontrak memecahkan banyak service sekaligus],
  )
  #v(4pt)
  #note[Indikator paling mudah: berapa service yang harus ikut rilis ketika satu _endpoint_ berubah.]
  #v(4pt)
  #note(kind: "tip")[Mulai dari batas data: siapa pemilik tabel `account`?]
  #v(4pt)
  #note(kind: "warn")[Jangan memecah service sebelum batas domain jelas.]
]

#code-slide(kicker: "Go essentials", title: "Routing dengan ServeMux",
  side: [
    - Pola `METHOD /path/{id}` tersedia sejak Go 1.22
    - `r.PathValue("id")` membaca parameter _path_
    - Tanpa _router_ pihak ketiga
  ],
)[
```go
func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("GET /accounts/{id}", getAccount)
    mux.HandleFunc("POST /accounts", createAccount)
    mux.HandleFunc("GET /health", health)

    addr := os.Getenv("HTTP_ADDR")
    if addr == "" {
        log.Fatal("HTTP_ADDR is required")
    }
    log.Fatal(http.ListenAndServe(addr, mux))
}
```
]

#slide(kicker: "Studi kasus", title: [Alur transfer: `flow`])[
  #flow(
    node("client", sub: "REST", kind: "ext"),
    arr(label: "POST /transfers", length: 100pt),
    node("transfer", sub: "service"),
    arr(label: "gRPC"),
    node("account", sub: "service"),
    arr(label: "pgx", length: 50pt),
    node("account-db", sub: "PostgreSQL", kind: "db", width: 110pt, height: 64pt),
  )
  #v(18pt)
  #flow(
    node("transfer", sub: "outbox"),
    arr(label: "publish", dash: "dashed"),
    node("Kafka", sub: "transfer.events", kind: "broker", width: 140pt),
    arr(label: "consume"),
    node("notification", sub: "consumer"),
    arr(label: "token", dir: "lr", length: 60pt),
    node("IdP", sub: "OAuth2", kind: "infra", width: 90pt),
  )
  #v(14pt)
  #align(center, legend(("svc", "service"), ("db", "database"), ("broker", "broker"), ("ext", "klien"), ("infra", "infrastruktur")))
]

#slide(kicker: "Studi kasus", title: [Alur transfer: `diagram`])[
  #diagram(height: 300pt,
    at(0pt, 110pt, node("client", kind: "ext")),
    at(220pt, 110pt, node("transfer")),
    at(480pt, 20pt, node("account")),
    at(480pt, 200pt, node("Kafka", sub: "topic", kind: "broker")),
    at(720pt, 200pt, node("notification")),
    at(720pt, 10pt, node("account-db", kind: "db", height: 70pt)),
    at(220pt, 220pt, node("transfer-db", kind: "db", height: 70pt)),
    edge((120pt, 138pt), (220pt, 138pt), label: "REST"),
    edge((340pt, 125pt), (480pt, 55pt), label: "gRPC", label-dx: -14pt),
    edge((340pt, 152pt), (480pt, 222pt), label: "event", dash: "dashed", label-dx: -14pt, label-dy: 6pt),
    edge((600pt, 228pt), (720pt, 228pt), label: "consume"),
    edge((600pt, 48pt), (720pt, 45pt), label: "pgx"),
    edge((280pt, 166pt), (280pt, 220pt), both: true),
  )
]

#slide(kicker: "Ringkasan", title: "Pola dan kapan dipakai")[
  #table(
    columns: (auto, 1fr, 1fr),
    [Pola], [Masalah], [Layak dipakai ketika],
    [_Circuit breaker_], [Service lambat menahan _thread_], [Panggilan _synchronous_ ke service yang bisa gagal],
    [Saga], [Transaksi lintas database], [Satu proses bisnis menyentuh lebih dari satu service],
    [_Transactional outbox_], [Tulis DB dan kirim event tidak atomik], [Event harus terkirim jika dan hanya jika data tersimpan],
  )
]
