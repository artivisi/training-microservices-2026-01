// Hari 4 — Cloud: Observability, Deployment, dan CI/CD (Lab 8–10).
// Build: make CLIENT="..." Deck-Hari-4-Microservices-2026-10.pdf
#import "../_template/deck.typ": *

#show: deck.with(
  title: "Cloud: Observability, Deployment, dan CI/CD",
  subtitle: [Melacak satu transfer lintas service, mengemas service ke _container_, menjalankannya di Kubernetes, lalu merilisnya melalui _pipeline_ CI/CD],
  day-label: "Hari 4",
  client: sys.inputs.at("client"),
  date: "29 Oktober 2026",
)

// Small helper: one lab briefing slide.
#let lab-slide(number, title, goal, builds, start, guide) = slide(kicker: "Lab " + number, title: title)[
  #two-col(
    card("Tujuan")[#goal],
    card("Yang dikerjakan", accent: gold.darken(15%))[#builds],
  )
  #v(12pt)
  #note(kind: "tip")[
    Langkah lengkap ada di *Panduan Lab, bab Lab #number*. Titik awal: _tag_ #raw(start). Peserta yang tertinggal cukup melakukan `git checkout` ke _tag_ tersebut.
  ]
  #v(4pt)
  #guide
]

// ════════════════════════════════════════════════════════════════════════════
#slide(kicker: "Hari 4", title: "Agenda hari ini")[
  #table(
    columns: (auto, 1fr, auto),
    [Waktu], [Topik], [Format],
    [09:00 – 09:45], [Lanskap _cloud_ untuk perbankan: model _deployment_, _managed_ vs _self-managed_, regulasi, posisi Kubernetes], [Presentasi + diskusi],
    [09:45 – 10:45], [*Lab 8*: melacak satu transfer lintas tiga service di Grafana], [_Hands-on_],
    [11:00 – 12:30], [_Containerization_ dan *Lab 9*: seluruh sistem berjalan di k3d], [Demo + _hands-on_],
    [13:30 – 14:15], [CI/CD per service dan pemetaannya ke Jenkins; GitOps sekilas], [Presentasi + demo],
    [14:15 – 15:45], [*Lab 10*: satu _commit_ menjadi _rolling update_], [_Hands-on_],
    [15:45 – 16:30], [Operasional: HPA, penempatan _observability stack_, OpenShift; diskusi dan tanya jawab], [Presentasi + diskusi],
  )
]

#slide(kicker: "Studi kasus", title: "Posisi sistem di awal Hari 4")[
  #diagram(height: 250pt,
    at(0pt, 95pt, node("klien", sub: "channel-app", kind: "ext")),
    at(200pt, 95pt, node("transfer", sub: "HTTP :8082")),
    at(450pt, 10pt, node("account", sub: "gRPC :9091")),
    at(450pt, 180pt, node("Kafka", sub: "transfer-events", kind: "broker")),
    at(690pt, 180pt, node("notification", sub: "HTTP :8083")),
    at(690pt, 5pt, node("Hydra", sub: "OAuth2 :4444", kind: "infra")),
    at(200pt, 190pt, node("db-transfer", sub: "outbox", kind: "db", height: 60pt)),
    edge((120pt, 123pt), (200pt, 123pt), label: "REST + JWT"),
    edge((320pt, 110pt), (450pt, 45pt), label: "gRPC + JWT", label-dx: -18pt),
    edge((320pt, 140pt), (450pt, 205pt), label: "relay outbox", dash: "dashed", label-dx: -20pt, label-dy: 8pt),
    edge((570pt, 208pt), (690pt, 208pt), label: "consume"),
    edge((570pt, 33pt), (690pt, 33pt), label: "JWKS"),
    edge((260pt, 151pt), (260pt, 190pt), both: true),
  )
  #v(6pt)
  #bullets(size: 13pt,
    [Hasil Lab 1–7: saga dengan kompensasi, _outbox_, _idempotent consumer_, gRPC dengan _circuit breaker_, dan JWT dari Hydra.],
    [Hari ini sistem yang sama diberi instrumentasi, dikemas ke _container_, dijalankan di Kubernetes, lalu dirilis melalui _pipeline_.],
  )
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "01", title: [Lanskap _cloud_ untuk perbankan], subtitle: [Model _deployment_, _managed_ vs _self-managed_, regulasi, dan posisi Kubernetes])

#slide(kicker: "Model deployment", title: [Empat model _deployment_])[
  #table(
    columns: (auto, 1fr, 1fr, 1fr),
    [Model], [Ciri], [Kelebihan], [Pertimbangan],
    [_On-premise_], [Server milik sendiri di _data center_ sendiri], [Kendali penuh atas data dan jaringan], [Kapasitas harus dibeli di muka; tim mengelola seluruh _stack_],
    [_Private cloud_], [Platform _cloud_ khusus satu organisasi], [Kendali tetap tinggi, penyediaan _resource_ lebih cepat], [Investasi platform dan tim operasional],
    [_Public cloud_], [_Resource_ milik penyedia, digunakan bersama oleh banyak pelanggan], [Elastis, layanan _managed_ lengkap], [Klasifikasi data dan lokasi penyimpanan harus sesuai regulasi],
    [_Hybrid_], [Gabungan model di atas], [Penempatan dipilih per _workload_], [Konektivitas, identitas, dan observability lintas lokasi],
  )
  #v(10pt)
  #note[Pilihan model ditentukan per _workload_, berdasarkan klasifikasi data yang diolah _workload_ tersebut.]
]

#slide(kicker: "Model deployment", title: [_Managed_ vs _self-managed_])[
  #two-col(
    card([_Managed service_])[
      - Penyedia mengurus instalasi, _patch_, _backup_, dan _high availability_
      - Tim fokus pada aplikasi
      - Konfigurasi terbatas pada pilihan yang disediakan penyedia
      - Contoh: database _managed_, Kafka _managed_, Kubernetes _managed_
    ],
    card([_Self-managed_], accent: gold.darken(15%))[
      - Tim menjalankan sendiri PostgreSQL, Kafka, Kubernetes
      - Seluruh parameter bisa diatur
      - Beban operasional: _upgrade_, _monitoring_, pemulihan data, rotasi sertifikat
      - Lazim di _on-premise_ dan _private cloud_
    ],
  )
  #v(12pt)
  #note(kind: "tip")[Pertanyaan yang membantu memilih: siapa yang dihubungi pukul 02.00 ketika layanan tersebut mati, dan apakah tim tersebut memiliki keahlian untuk memulihkannya.]
]

#slide(kicker: "Regulasi", title: "Regulasi dan klasifikasi data")[
  #bullets(
    [Penempatan sistem elektronik, klasifikasi data, dan manajemen risiko TI di sektor perbankan diatur ketentuan OJK.],
    [Data nasabah dan data transaksi umumnya masuk kelas paling ketat, sehingga _workload_ yang mengolahnya cenderung ditempatkan di _on-premise_ atau _private cloud_.],
    [_Workload_ dengan data yang tidak sensitif, misalnya konten publik atau _environment_ pengembangan, lebih leluasa ditempatkan di _public cloud_.],
    [Keputusan penempatan perlu dicatat beserta alasannya, karena auditor akan menanyakan dasar keputusan tersebut.],
  )
  #v(8pt)
  #note(kind: "warn")[Ketentuan regulasi berubah dari waktu ke waktu. Rujuk ketentuan yang berlaku dan kebijakan internal organisasi sebelum memindahkan _workload_.]
]

#slide(kicker: "Portabilitas", title: "Kubernetes sebagai landasan yang portabel")[
  #diagram(height: 200pt,
    at(0pt, 70pt, node("manifest + image", sub: "hasil training", kind: "infra", width: 150pt)),
    at(340pt, 0pt, node("on-premise", sub: "cluster sendiri", width: 160pt)),
    at(340pt, 72pt, node("private cloud", sub: "OpenShift, dll.", width: 160pt)),
    at(340pt, 144pt, node("public cloud", sub: "Kubernetes managed", width: 160pt)),
    edge((150pt, 98pt), (340pt, 28pt)),
    edge((150pt, 98pt), (340pt, 100pt)),
    edge((150pt, 98pt), (340pt, 172pt)),
    at(560pt, 30pt, box(width: 300pt)[
      #set text(size: 13pt)
      - Objek yang sama di semua tempat: Deployment, Service, ConfigMap, Secret
      - Perbedaan antar-_cluster_ ditampung di _overlay_ Kustomize
      - Saat kebijakan penempatan berubah, aplikasi tidak perlu ditulis ulang
    ]),
  )
  #v(10pt)
  #note[Portabilitas berlaku selama aplikasi hanya bergantung pada API Kubernetes standar. Fitur khusus satu penyedia, misalnya _load balancer_ atau _storage class_ tertentu, perlu dipisahkan ke _overlay_.]
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "02", title: "Observability lintas service", subtitle: [_Log_, metrik, dan _trace_ untuk menjawab "transfer pukul 14.03 itu mengapa lambat?"])

#slide(kicker: "Observability", title: [_Log_, metrik, dan _trace_])[
  #table(
    columns: (auto, 1fr, 1fr, auto),
    [Sumber], [Pertanyaan yang dijawab], [Implementasi di studi kasus], [Disimpan di],
    [_Log_], [Apa yang terjadi pada satu _request_ tertentu?], [`slog` format JSON, `correlation_id`, `trace_id`], [Loki],
    [Metrik], [Seberapa sering, seberapa cepat, berapa yang gagal?], [`prometheus/client_golang`, _endpoint_ `/metrics`], [Prometheus],
    [_Trace_], [Di service mana waktu habis untuk satu transaksi?], [OpenTelemetry, `otelhttp`, `otelgrpc`, Kafka _header_], [Tempo],
  )
  #v(12pt)
  #bullets(size: 13.5pt,
    [Metrik mendeteksi adanya masalah. _Trace_ menunjukkan service tempat waktu habis, dan _log_ berisi penyebabnya.],
    [_Trace_ dan _log_ dihubungkan oleh `trace_id`. Dari lonjakan di grafik metrik, _engineer_ mempersempit rentang waktu lalu membuka _trace_ pada rentang tersebut. Tautan langsung dari metrik ke _trace_ membutuhkan _exemplar_ Prometheus, yang tidak dipasang di lab.],
  )
]

#slide(kicker: "Correlation ID", title: [_Correlation ID_ lintas tiga service])[
  #flow(
    node("klien", kind: "ext", width: 100pt),
    arr(label: "X-Correlation-ID", length: 130pt),
    node("transfer"),
    arr(label: "metadata x-correlation-id", length: 170pt),
    node("account"),
  )
  #v(10pt)
  #flow(
    node("transfer", sub: "baris outbox"),
    arr(label: "relay", length: 90pt, dash: "dashed"),
    node("Kafka", sub: "header", kind: "broker"),
    arr(label: "consume", length: 90pt),
    node("notification"),
  )
  #v(10pt)
  #bullets(size: 13pt,
    [Transfer membaca _header_ `X-Correlation-ID`, atau membuat ID baru bila _header_ tersebut kosong, lalu mengembalikannya di _response_.],
    [ID disimpan di `context.Context`, ikut ke gRPC _metadata_, ke baris _outbox_, lalu ke _header_ Kafka.],
  )
]

#code-slide(kicker: "Logging", title: [_Handler_ `slog` yang membaca `context`],
  side: [
    - Setiap baris _log_ otomatis membawa `correlation_id`, `trace_id`, `span_id`
    - Kode _handler_ HTTP cukup memanggil `slog.InfoContext(ctx, ...)`
    - Output JSON ke _stdout_ sekaligus diekspor sebagai _log_ OTLP (_bridge_ `otelslog`)
    - `WithAttrs` dan `WithGroup` membungkus ulang _handler_ hasilnya, sehingga _logger_ dari `logger.With(...)` tetap membawa ketiga atribut tersebut
  ],
)[
```go
type ctxHandler struct{ slog.Handler }

func (h ctxHandler) Handle(ctx context.Context,
    r slog.Record) error {
    if id, ok := correlation.FromContext(ctx); ok {
        r.AddAttrs(slog.String("correlation_id", id))
    }
    sc := trace.SpanContextFromContext(ctx)
    if sc.IsValid() {
        r.AddAttrs(
            slog.String("trace_id", sc.TraceID().String()),
            slog.String("span_id", sc.SpanID().String()))
    }
    return h.Handler.Handle(ctx, r)
}

func (h ctxHandler) WithAttrs(a []slog.Attr) slog.Handler {
    return ctxHandler{h.Handler.WithAttrs(a)}
}

func (h ctxHandler) WithGroup(n string) slog.Handler {
    return ctxHandler{h.Handler.WithGroup(n)}
}
```
]

#slide(kicker: "Metrik", title: "Metrik yang dipasang di setiap service")[
  #table(
    columns: (auto, auto, 1fr),
    [Metrik], [Service], [Kegunaan],
    [Histogram durasi _request_ (`method`, `route`, `status`)], [Semua], [_Latency_ p95 per _endpoint_],
    [`transfers_total{status}`], [transfer], [Laju transfer per status: `COMPLETED`, `FAILED`, `COMPENSATED`],
    [`circuit_breaker_state{target}`], [transfer], [0 = _closed_, 1 = _half-open_, 2 = _open_],
    [Penghitung transisi _breaker_], [transfer], [Berapa kali _breaker_ berganti status],
    [`outbox_pending`], [transfer], [_Event_ yang belum terkirim ke Kafka],
    [`notifications_processed_total{result}`], [notification], [Jumlah _event_ diproses, termasuk duplikat yang dilewati],
  )
  #v(10pt)
  #note(kind: "warn")[Label `route` diisi pola ServeMux (`GET /transfers/{id}`), tidak diisi _path_ asli. _Path_ asli berisi ID sehingga jumlah _time series_ terus bertambah.]
]

#slide(kicker: "Tracing", title: [Meneruskan _trace context_ lewat Kafka])[
  #two-col(ratio: (1.15fr, 1fr),
    [
```go
// transfer: dalam transaksi DB yang sama
// dengan perubahan status transfer
carrier := propagation.MapCarrier{}
otel.GetTextMapPropagator().Inject(ctx, carrier)
// carrier disimpan di kolom baris outbox,
// relay menyalinnya ke header Kafka

// notification: saat membaca message
ctx = otel.GetTextMapPropagator().
    Extract(ctx, headerCarrier(msg.Headers))
ctx, span := tracer.Start(ctx,
    "notification.process")
defer span.End()
```
    ],
    [
      #set text(size: 13pt)
      - HTTP dan gRPC: `otelhttp` dan _stats handler_ `otelgrpc` meneruskan _header_ `traceparent` secara otomatis
      - Kafka: _relay_ berjalan di _goroutine_ terpisah tanpa _context_ dari _request_ asal, dan baru mengirim _event_ hingga ±500 ms kemudian. Karena itu _trace context_ disimpan ke baris _outbox_ saat baris tersebut ditulis
      - Hasilnya, satu transfer tampil sebagai satu _trace_ yang mencakup tiga service
    ],
  )
]

#slide(kicker: "Stack", title: [_Stack_ observability di lab: `otel-lgtm`])[
  #diagram(height: 250pt,
    at(0pt, 0pt, node("transfer")),
    at(0pt, 90pt, node("account")),
    at(0pt, 180pt, node("notification")),
    at(250pt, 90pt, node("collector", sub: "OTLP :4317", kind: "infra", width: 130pt)),
    at(480pt, 30pt, node("Tempo", sub: "trace", kind: "infra")),
    at(480pt, 110pt, node("Loki", sub: "log", kind: "infra")),
    at(480pt, 190pt, node("Prometheus", sub: "metrik", kind: "infra")),
    at(720pt, 110pt, node("Grafana", sub: ":3000", kind: "infra")),
    edge((120pt, 28pt), (250pt, 108pt)),
    edge((120pt, 118pt), (250pt, 118pt), label: "OTLP"),
    edge((120pt, 208pt), (250pt, 128pt)),
    edge((380pt, 110pt), (480pt, 58pt)),
    edge((380pt, 126pt), (480pt, 138pt)),
    edge((480pt, 226pt), (120pt, 226pt), label: "scrape /metrics", dash: "dashed", label-dy: 8pt),
    edge((600pt, 58pt), (720pt, 128pt)),
    edge((600pt, 138pt), (720pt, 138pt)),
    edge((600pt, 218pt), (720pt, 148pt)),
  )
  #v(6pt)
  #bullets(size: 13pt,
    [Satu _container_ `grafana/otel-lgtm` berisi _collector_, Tempo, Loki, Prometheus, dan Grafana dengan _dashboard_ yang sudah diprovisikan.],
    [_Trace_ dan _log_ dikirim (_push_) lewat OTLP; metrik diambil (_pull_) oleh Prometheus dari `/metrics` di setiap service.],
  )
]

#slide(kicker: "Membaca trace", title: [Mencari service yang lambat dari _waterfall_])[
  #let bar(y, x, w, label, c: navy) = (
    at(0pt, y, box(width: 230pt, height: 22pt, align(left + horizon, text(size: 11pt, label)))),
    at(240pt + x, y, box(width: w, height: 22pt, fill: c.lighten(70%), stroke: 0.8pt + c, radius: 2pt)),
  )
  #diagram(height: 190pt,
    at(240pt, 0pt, text(size: 10pt, fill: slate)[0 ms #h(240pt) 1.000 ms #h(240pt) 2.100 ms]),
    ..bar(24pt, 0pt, 600pt, [transfer `POST /transfers`]),
    ..bar(54pt, 6pt, 280pt, [account `Debit`], c: red),
    ..bar(84pt, 292pt, 280pt, [account `Credit`], c: red),
    ..bar(114pt, 580pt, 16pt, [transfer `insert outbox`]),
    ..bar(144pt, 600pt, 24pt, [notification `process`], c: gold.darken(20%)),
  )
  #bullets(size: 13pt,
    [_Span_ `Debit` dan `Credit` di account memakan hampir seluruh durasi transfer. Sumber masalah ada di account, sedangkan transfer hanya menunggu.],
    [Buka atribut _span_ dan _log_ dengan `trace_id` yang sama untuk melihat penyebabnya, misalnya _fault delay_ yang sengaja dipasang di Lab 8.],
  )
]

#lab-slide("8", "Melacak satu transfer di Grafana",
  [
    - Menemukan service yang lambat langsung dari data _trace_
    - Membaca status _circuit breaker_ dari _dashboard_
    - Berangkat dari lonjakan di metrik, lalu menghubungkan _trace_ dan _log_ melalui `trace_id`
  ],
  [
    - Instrumentasi `slog`, Prometheus, dan OpenTelemetry di tiga service
    - Menjalankan `otel-lgtm` dari `compose.yaml`
    - Memasang _fault delay_ di account dengan `make fault-slow`, lalu mencari _span_ yang lambat di Tempo
    - Mengamati _breaker_ berubah ke _open_ di _dashboard_
  ],
  "lab-07",
  [],
)

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "03", title: [_Containerization_], subtitle: [_Multi-stage build_, _static binary_ Go, _image_ minimal, dan 12-factor])

#slide(kicker: "Go dan container", title: [Mengapa Go cocok untuk _container_])[
  #two-col(
    [
      #bullets(
        [Dengan `CGO_ENABLED=0`, hasil _build_ Go berupa satu _static binary_ yang tidak membutuhkan _library_ sistem.],
        [_Image_ akhir cukup berisi _binary_ tersebut dan sertifikat CA, berukuran belasan hingga puluhan megabyte.],
        [Tanpa _shell_ dan _package manager_ di _image_, celah serangan berkurang dan hasil _scanning_ lebih bersih.],
      )
    ],
    card("Ukuran tipikal")[
      #table(
        columns: (1fr, auto),
        [_Base image_], [Ukuran kira-kira],
        [`golang:1.27.2-alpine` (_builder_)], [± 300 MB],
        [`alpine` + _binary_], [± 25 MB],
        [`scratch` + _binary_], [± 15 MB],
      )
      #text(size: 10.5pt, fill: slate)[Angka bergantung pada jumlah dependensi service.]
    ],
  )
]

#code-slide(kicker: "Dockerfile", title: [_Multi-stage build_ untuk service transfer],
  side: [
    - _Stage_ pertama: kompilasi dengan _toolchain_ lengkap
    - _Stage_ kedua: `FROM scratch`, hanya menyalin hasil _build_
    - `-trimpath -ldflags "-s -w"`: _path_ lokal dan simbol _debug_ dibuang
    - _Build context_ `studi-kasus/` karena `go.work` dan modul `proto` ikut dibutuhkan
  ],
)[
```dockerfile
FROM golang:1.27.2-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w" -o /out/app ./transfer

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt \
     /etc/ssl/certs/
COPY --from=build /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
```
]

#slide(kicker: "Keamanan image", title: [_Non-root_ dan UID sembarang])[
  #two-col(
    card([`USER 65532:65532`])[
      - Proses tidak berjalan sebagai `root` walaupun _image_ dijalankan tanpa opsi tambahan
      - Angka numerik dibutuhkan agar Kubernetes bisa memverifikasi `runAsNonRoot`
      - `scratch` tidak memiliki `/etc/passwd`, sehingga nama pengguna tidak bisa digunakan
    ],
    card([UID sembarang], accent: gold.darken(15%))[
      - OpenShift dengan SCC `restricted-v2` menjalankan _container_ dengan UID acak dari rentang milik _namespace_
      - _Binary_ harus tetap berjalan dengan UID berapa pun
      - Service tidak menulis ke _filesystem_: _log_ ke _stdout_, data ke database
    ],
  )
  #v(12pt)
  #note(kind: "tip")[Uji sendiri: `docker run --user 1000770000:0 ...` harus berjalan normal. Bila gagal, kemungkinan besar service mencoba menulis _file_ ke direktori milik UID lain.]
]

#slide(kicker: "12-factor", title: [Prinsip 12-factor yang langsung terlihat di studi kasus])[
  #table(
    columns: (auto, 1fr),
    [Prinsip], [Penerapan di studi kasus],
    [_Config_], [Seluruh konfigurasi dari _environment variable_; satu `LoadConfig` per service],
    [_Backing services_], [Database, Kafka, Hydra, _collector_ diakses lewat URL dari konfigurasi; bisa diganti tanpa _build_ ulang],
    [_Build, release, run_], [Satu _image_ per _commit_; konfigurasi ditambahkan saat _deploy_ melalui ConfigMap dan Secret],
    [_Processes_], [Service tidak menyimpan _state_ di memori; _state_ ada di database],
    [_Port binding_], [Service membuka _port_ HTTP dan gRPC sendiri: `HTTP_ADDR`, `GRPC_ADDR`],
    [_Disposability_], [_Start_ cepat; _graceful shutdown_ saat menerima `SIGTERM`],
    [_Logs_], [JSON ke _stdout_; platform yang mengumpulkan],
  )
]

#code-slide(kicker: "Konfigurasi", title: [Konfigurasi wajib, tanpa nilai _default_],
  side: [
    - _Environment variable_ yang kosong menghentikan _startup_ dengan pesan galat yang menyebut namanya
    - _Pod_ dengan ConfigMap yang salah langsung gagal dan terlihat di `kubectl get pods`
    - Nilai _default_ yang digunakan tanpa terdeteksi, misalnya `localhost`, baru ketahuan saat transaksi pertama gagal
  ],
)[
```go
func LoadConfig() (Config, error) {
    var missing []string
    get := func(key string) string {
        v := os.Getenv(key)
        if v == "" {
            missing = append(missing, key)
        }
        return v
    }
    cfg := Config{
        HTTPAddr:    get("HTTP_ADDR"),
        DatabaseURL: get("DATABASE_URL"),
        AccountGRPC: get("ACCOUNT_GRPC_ADDR"),
    }
    if len(missing) > 0 {
        return Config{}, fmt.Errorf(
            "missing required env: %s",
            strings.Join(missing, ", "))
    }
    return cfg, nil
}
```
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "04", title: "Deployment ke Kubernetes", subtitle: [Deployment, Service, ConfigMap/Secret, _probe_, dan _rolling update_ di k3d])

#slide(kicker: "Lab 9", title: [Arsitektur _deployment_ di laptop])[
  #diagram(height: 330pt,
    at(150pt, 0pt, rect(width: 470pt, height: 325pt, radius: 6pt, fill: panel.lighten(40%),
      stroke: (paint: navy, thickness: 1pt, dash: "dashed"))),
    at(162pt, 8pt, text(size: 10.5pt, weight: "bold", fill: navy)[_cluster_ k3d · _namespace_ `bank`]),
    at(0pt, 135pt, node("klien", sub: "localhost:8080", kind: "ext", width: 110pt)),
    at(170pt, 135pt, node("Ingress", sub: "Traefik", kind: "infra", width: 110pt)),
    at(320pt, 135pt, node("transfer", sub: "Deployment")),
    at(485pt, 45pt, node("account", sub: "Deployment", width: 120pt)),
    at(485pt, 235pt, node("notification", sub: "Deployment", width: 120pt)),
    edge((110pt, 163pt), (170pt, 163pt)),
    edge((280pt, 163pt), (320pt, 163pt)),
    edge((440pt, 150pt), (485pt, 80pt), label: "gRPC", label-dx: -26pt),
    at(680pt, 0pt, text(size: 10.5pt, weight: "bold", fill: slate)[`compose.yaml` di _host_]),
    at(680pt, 22pt, node("PostgreSQL", sub: "3 database", kind: "db", width: 150pt, height: 60pt)),
    at(680pt, 98pt, node("Kafka", sub: ":19092", kind: "broker", width: 150pt)),
    at(680pt, 170pt, node("Hydra", sub: ":4444", kind: "infra", width: 150pt)),
    at(680pt, 242pt, node("otel-lgtm", sub: ":4317", kind: "infra", width: 150pt)),
    edge((620pt, 175pt), (680pt, 175pt), both: true),
    at(560pt, 300pt, text(size: 10pt, fill: slate)[`host.k3d.internal`]),
  )
]

#slide(kicker: "Objek Kubernetes", title: "Objek Kubernetes di Lab 9")[
  #table(
    columns: (auto, 1fr, 1fr),
    [Objek], [Fungsi], [Di studi kasus],
    [Deployment], [Menjaga jumlah _replica_ dan mengatur _rolling update_], [Satu per service],
    [Service], [Nama DNS dan _load balancing_ ke _pod_ yang _ready_], [`account:9091` dipanggil transfer lewat gRPC],
    [ConfigMap], [Konfigurasi yang tidak rahasia], [`HTTP_ADDR`, `KAFKA_TOPIC`, `OAUTH_ISSUER`],
    [Secret], [Konfigurasi rahasia], [`DATABASE_URL`, `OAUTH_CLIENT_SECRET`],
    [Ingress], [Jalur HTTP dari luar _cluster_], [`/transfers` lewat Traefik bawaan k3s],
    [Kustomize], [_Base_ bersama, _overlay_ per _cluster_], [`k8s/base`, `k8s/overlays/k3d`],
  )
  #v(10pt)
  #note[Manifest sudah disediakan di repositori studi kasus. Fokus Lab 9 adalah menerapkan, membaca, lalu memodifikasi manifest tersebut.]
]

#code-slide(kicker: "Probe", title: [_Readiness_ dan _liveness probe_],
  side: [
    - `/readyz` gagal → _pod_ dikeluarkan dari Service, tidak di-_restart_. Cocok untuk kondisi database belum terhubung
    - `/healthz` gagal → _container_ di-_restart_. Hanya untuk proses yang macet
    - Kesalahan umum: _liveness_ memeriksa database, sehingga gangguan database menyebabkan semua _pod_ di-_restart_ bersamaan
  ],
)[
```yaml
containers:
- name: transfer
  image: transfer:dev
  envFrom:
  - configMapRef: { name: transfer }
  - secretRef:    { name: transfer }
  readinessProbe:
    httpGet: { path: /readyz, port: 8082 }
    periodSeconds: 5
  livenessProbe:
    httpGet: { path: /healthz, port: 8082 }
    periodSeconds: 10
  resources:
    requests: { cpu: 50m,  memory: 64Mi }
    limits:   { memory: 128Mi }
```
]

#code-slide(kicker: "Security context", title: [_Security context_ yang lolos SCC `restricted-v2`],
  side: [
    - Tidak ada `runAsUser`: platform yang memilih UID, sesuai perilaku OpenShift
    - `readOnlyRootFilesystem` aman karena service tidak menulis _file_
    - Manifest yang sama berlaku di k3d dan di _cluster_ yang menerapkan kebijakan ketat
  ],
)[
```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
# runAsUser sengaja tidak diisi
```
]

#slide(kicker: "Rolling update", title: [_Rolling update_ tanpa _downtime_])[
  #flow(
    node("v1 · v1 · v1", sub: "3 pod ready", width: 120pt),
    arr(label: "set image", length: 75pt),
    node("v1 · v1 · v1 + v2", sub: "4 pod, v2 menunggu ready", width: 165pt),
    arr(length: 40pt),
    node("v1 · v1 · v2", sub: "satu v1 dihentikan", width: 135pt),
    arr(label: "berulang", length: 70pt),
    node("v2 · v2 · v2", sub: "selesai", width: 120pt),
  )
  #v(14pt)
  #two-col(ratio: (1fr, 1fr),
    [
```bash
kubectl -n bank set image deploy/transfer \
  transfer=transfer:v2
kubectl -n bank rollout status deploy/transfer
kubectl -n bank rollout undo deploy/transfer
```
    ],
    [
      #set text(size: 13pt)
      - Nilai _default_ `maxSurge` 25% (dibulatkan ke atas menjadi 1) dan `maxUnavailable` 25% (dibulatkan ke bawah menjadi 0): satu _pod_ tambahan dibuat lebih dulu
      - _Pod_ lama baru dihentikan setelah _pod_ baru lolos _readiness probe_
      - _Image_ baru yang gagal _start_ menahan _rollout_; versi lama tetap melayani
      - `rollout undo` mengembalikan versi sebelumnya
    ],
  )
]

#slide(kicker: "Infra dari cluster", title: [_Pod_ menjangkau infrastruktur di _host_])[
  #bullets(size: 13.5pt,
    [Hanya tiga service yang berjalan di k3d. PostgreSQL, Kafka, Hydra, dan `otel-lgtm` tetap berjalan dari `compose.yaml`.],
    [_Pod_ menjangkau _host_ lewat nama `host.k3d.internal`.],
    [Kafka mengiklankan alamat _broker_ ke klien. _Listener_ tambahan pada _port_ 19092 mengiklankan `host.k3d.internal`, sementara klien di _host_ tetap menggunakan `localhost:9092`.],
    [Token dari Hydra membawa `iss` = `http://localhost:4444/`. _Pod_ tetap memeriksa _issuer_ tersebut, tetapi mengambil JWKS dan token lewat `host.k3d.internal`.],
  )
  #v(8pt)
  #note(kind: "warn")[Di _cluster_ sungguhan, infrastruktur memiliki nama DNS sendiri sehingga perbedaan alamat _issuer_ seperti ini tidak muncul. Bagian ini khusus untuk lab di laptop.]
]

#lab-slide("9", [Menjalankan seluruh sistem di k3d],
  [
    - Mengemas tiga service menjadi _image_ minimal dan _non-root_
    - Menerapkan manifest yang disediakan ke _cluster_ k3d
    - Melakukan _scaling_, perubahan konfigurasi, dan _rolling update_
  ],
  [
    - `make images`, `make k3d-up`, `make k3d-import`, `make k8s-apply`
    - Transfer lewat Ingress `localhost:8080`, cek hasilnya di Grafana
    - `kubectl scale` transfer menjadi 3 _replica_
    - Ubah satu nilai ConfigMap, jalankan `kubectl rollout restart deploy/transfer`, lalu periksa nilai baru di _pod_
    - _Build_ _tag_ baru, `set image`, `rollout status`
  ],
  "lab-08",
  [],
)

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "05", title: "CI/CD per service", subtitle: [_Pipeline_ per service, pemetaan ke Jenkins, dan GitOps sebagai konsep])

#slide(kicker: "Mengapa per service", title: [Setiap service memiliki _pipeline_ sendiri])[
  #bullets(
    [Alasan utama memecah sistem menjadi service adalah _deployment_ yang independen. Tujuan tersebut baru tercapai bila setiap service memiliki jalur rilis sendiri.],
    [Perubahan di `studi-kasus/transfer/` hanya menjalankan _pipeline_ transfer. Perubahan di `proto/` menjalankan _pipeline_ account dan transfer karena keduanya bergantung pada kontrak tersebut.],
    [Satu _pipeline_ untuk semua service mengembalikan sistem ke pola rilis monolith: semua service ikut di-_build_ dan di-_deploy_ setiap kali ada perubahan.],
  )
  #v(10pt)
  #flow(
    node("push", sub: "satu commit", kind: "ext", width: 100pt),
    arr(label: "path filter", length: 90pt),
    node("test", sub: "make test", width: 110pt, kind: "infra"),
    arr(length: 40pt),
    node("image", sub: "VERSION=sha", width: 110pt, kind: "infra"),
    arr(length: 40pt),
    node("push", sub: "registry", width: 110pt, kind: "infra"),
    arr(length: 40pt),
    node("deploy", sub: "rollout", width: 110pt, kind: "infra"),
  )
]

#code-slide(kicker: "Workflow", title: [_Workflow_ hanya memanggil target `make`],
  side: [
    - Tidak ada `uses:`; setiap _step_ berupa perintah _shell_ biasa
    - Logika _build_ ada di `Makefile`, sehingga bisa dijalankan sama persis di laptop
    - _Checkout_ menggunakan variabel dan token yang disediakan runner: `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`, `github.token`
    - Memindahkan _pipeline_ ke runner CI lain cukup dengan menyalin urutan perintah yang sama
    - _Tag image_ = SHA _commit_, sehingga setiap _image_ bisa dilacak ke kode sumbernya
  ],
)[
```yaml
on:
  push:
    paths:
      - "studi-kasus/transfer/**"
      - "studi-kasus/proto/**"
jobs:
  transfer:
    runs-on: docker
    env:
      TOKEN: ${{ github.token }}
      VERSION: ${{ github.sha }}
    steps:
      - run: |   # checkout dengan perintah git
          git -c http.extraHeader="Authorization: token $TOKEN" \
            clone "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY.git" src
          git -C src checkout "$GITHUB_SHA"
      - run: make -C src/studi-kasus/transfer test
      - run: make -C src/studi-kasus/transfer image
      - run: make -C src/studi-kasus/transfer push
      - run: make -C src/studi-kasus/transfer deploy
```
]

#code-slide(kicker: "Makefile", title: [Target `image`, `push`, `deploy`],
  side: [
    - `REGISTRY`, `IMAGE_OWNER`, `VERSION`, `NAMESPACE` wajib diisi; target berhenti dengan pesan galat bila salah satunya kosong
    - Tidak ada _tag_ `latest`: _rollout_ selalu menunjuk versi yang pasti
    - `deploy` menunggu `rollout status`, sehingga _pipeline_ gagal bila _pod_ baru tidak pernah _ready_
  ],
)[
```make
IMAGE = $(REGISTRY)/$(IMAGE_OWNER)/transfer:$(VERSION)

require = $(foreach v,$(1),$(if $($(v)),,$(error $(v) is required)))

image:
	$(call require,REGISTRY IMAGE_OWNER VERSION)
	# Dockerfile di studi-kasus/transfer, context studi-kasus/
	docker build -f Dockerfile -t $(IMAGE) ..

deploy:
	$(call require,REGISTRY IMAGE_OWNER VERSION NAMESPACE)
	kubectl -n $(NAMESPACE) set image \
	  deploy/transfer transfer=$(IMAGE)
	kubectl -n $(NAMESPACE) rollout status \
	  deploy/transfer --timeout=120s
```
]

#slide(kicker: "Lab 10", title: [Arsitektur _pipeline_ di lab])[
  #diagram(height: 270pt,
    at(0pt, 30pt, node("laptop peserta", sub: "git push", kind: "ext", width: 130pt)),
    at(215pt, 30pt, node("git server", sub: "repositori", kind: "infra", width: 130pt)),
    at(450pt, 30pt, node("runner CI", sub: "pusat", kind: "infra", width: 130pt)),
    at(690pt, 30pt, node("server pelatihan", sub: "namespace per peserta", width: 160pt)),
    at(215pt, 190pt, node("container registry", sub: "di git server", kind: "infra", width: 150pt)),
    at(0pt, 190pt, node("k3d laptop", sub: "imagePullSecret", width: 130pt)),
    edge((130pt, 58pt), (215pt, 58pt), label: "push"),
    edge((345pt, 58pt), (450pt, 58pt), label: "trigger"),
    edge((580pt, 58pt), (690pt, 58pt), label: "deploy"),
    edge((480pt, 86pt), (365pt, 200pt), label: "push image", label-dx: 40pt),
    edge((215pt, 218pt), (130pt, 218pt), label: "pull", dash: "dashed"),
    edge((365pt, 230pt), (740pt, 86pt), label: "pull", dash: "dashed", label-dx: 50pt, label-dy: 10pt),
  )
  // TODO: runner pusat dan server pelatihan belum diuji end-to-end (push hingga deploy).
  // Sebelum delivery: bila pipeline belum berjalan, ganti catatan di bawah dengan
  // pernyataan tanpa tanggal tentang bagian yang hanya didemonstrasikan.
  #note[Alamat server dan akses setiap peserta dibagikan saat lab.]
]

#slide(kicker: "Jenkins", title: [Pemetaan ke Bitbucket dan Jenkins _on-premise_])[
  #two-col(ratio: (0.8fr, 1.3fr),
    [
      #table(
        columns: (1fr, 1fr),
        [Lab], [Jenkins],
        [Repositori di git server], [Repositori Bitbucket],
        [_Trigger_ `on: push`], [_Webhook_ Bitbucket ke Jenkins],
        [Filter `paths:`], [_Multibranch_ + `when { changeset }`],
        [_Step_ `run: make test`], [`stage('Test')`],
        [_Step_ `image`, `push`], [`stage('Build Image')`, `stage('Push')`],
        [_Step_ `deploy`], [`stage('Deploy')`],
        [_Secret_ runner], [Jenkins _credentials_],
      )
    ],
    [
```groovy
pipeline {
  agent any
  environment {
    VERSION     = "${env.GIT_COMMIT}"
    REGISTRY    = 'registry.example.com'
    IMAGE_OWNER = 'tim-app'
    NAMESPACE   = 'bank'
    REG = credentials('registry') // REG_USR, REG_PSW
  }
  stages {
    stage('Test') { steps {
      sh 'make -C studi-kasus/transfer test' } }
    stage('Build Image') { steps {
      sh 'make -C studi-kasus/transfer image' } }
    stage('Push') { steps {
      sh 'echo $REG_PSW | docker login -u $REG_USR --password-stdin $REGISTRY'
      sh 'make -C studi-kasus/transfer push' } }
    stage('Deploy') { steps {
      sh 'make -C studi-kasus/transfer deploy' } }
  }
}
```
    ],
  )
  #v(6pt)
  #note[Karena setiap tahap hanya memanggil `make`, _Jenkinsfile_ deklaratif cukup berisi empat _stage_ yang sama. Repositori studi kasus menyediakan satu _Jenkinsfile_ per service.]
]

#slide(kicker: "GitOps", title: [GitOps: keadaan _cluster_ mengikuti isi repositori])[
  #two-col(
    card([Model _push_ (Lab 10)])[
      #flow(
        node("runner", kind: "infra", width: 90pt, height: 46pt),
        arr(label: "kubectl", length: 80pt),
        node("cluster", width: 90pt, height: 46pt),
      )
      - Runner memegang _credential_ ke _cluster_
      - Perubahan manual di _cluster_ tidak terdeteksi
      - Sederhana; cocok untuk awal
    ],
    card([Model _pull_ (GitOps)], accent: gold.darken(15%))[
      #flow(
        node("repo config", kind: "infra", width: 100pt, height: 46pt),
        arr(label: "dibaca", dir: "l", length: 70pt),
        node("agen di cluster", width: 110pt, height: 46pt),
      )
      - Agen di dalam _cluster_ membandingkan isi repositori dengan keadaan _cluster_, lalu menyamakannya
      - _Rollback_ = `git revert`; riwayat perubahan = riwayat _commit_
      - CI hanya memperbarui _tag image_ di repositori konfigurasi
    ],
  )
  #v(10pt)
  #note[GitOps dibahas sebagai arah pengembangan. Lab tidak memasang _tools_ GitOps; konsepnya cukup dipahami agar bisa dinilai ketika organisasi siap.]
]

#lab-slide("10", [Satu _commit_ menjadi _rolling update_],
  [
    - Mengamati _pipeline_ per service berjalan otomatis setelah _push_
    - Melacak satu _commit_ hingga menjadi _image_ dengan _tag_ SHA dan _pod_ baru di _cluster_
  ],
  [
    - Membaca _workflow_ `transfer.yaml` dan target `make` yang dipanggilnya
    - Mengubah kode transfer, _commit_, lalu _push_ ke git server
    - Memantau _log pipeline_: _test_, _build image_, _push_, _deploy_
    - Memeriksa `kubectl rollout history` dan versi _image_ yang berjalan
    - Membandingkan _workflow_ tersebut dengan _Jenkinsfile_ yang setara
  ],
  "lab-09",
  [#note(kind: "warn")[Bagian _deploy_ ke k3d dengan runner lokal didemonstrasikan instruktur. Runner tidak dipasang di laptop peserta.]],
)

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "06", title: [Operasional di _cloud_], subtitle: [HPA, penempatan _observability stack_, dan pemetaan ke OpenShift])

#code-slide(kicker: "Scaling", title: [_Horizontal Pod Autoscaler_ (HPA)],
  side: [
    - HPA menambah atau mengurangi _replica_ berdasarkan metrik, umumnya CPU terhadap `requests`
    - Syarat: `resources.requests` terisi dan _metrics-server_ berjalan (k3s menyediakannya)
    - Service harus _stateless_ agar _replica_ bisa ditambah kapan saja
    - _Scaling_ transfer tidak menolong bila yang lambat adalah database account
  ],
)[
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: transfer
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: transfer
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```
]

#slide(kicker: "Observability", title: [Penempatan _observability stack_])[
  #two-col(
    card([Di dalam _cluster_ aplikasi])[
      - _Collector_ OpenTelemetry sebagai _DaemonSet_ atau _sidecar_ di setiap _cluster_
      - Penyimpanan jangka pendek dekat dengan sumber data
      - Risiko: gangguan _cluster_ ikut mematikan Grafana, Tempo, dan Loki yang dibutuhkan untuk menyelidiki gangguan tersebut
    ],
    card([_Cluster_ terpisah atau terpusat], accent: gold.darken(15%))[
      - Tempo, Loki, Prometheus, dan Grafana di _cluster_ khusus observability
      - Satu tempat untuk melihat semua _environment_
      - Data tetap tersedia saat _cluster_ aplikasi bermasalah
    ],
  )
  #v(12pt)
  #bullets(size: 13pt,
    [Pola yang umum: _collector_ di setiap _cluster_ aplikasi, penyimpanan dan Grafana di tempat terpusat.],
    [Kode aplikasi tidak berubah karena service hanya mengenal `OTEL_EXPORTER_OTLP_ENDPOINT`; yang berubah hanya alamat tersebut.],
    [_Log_ dan _trace_ bisa berisi data nasabah. Retensi dan hak akses mengikuti klasifikasi data yang sama dengan aplikasinya.],
  )
]

#slide(kicker: "OpenShift", title: "Pemetaan Kubernetes ke OpenShift")[
  #table(
    columns: (auto, auto, 1fr),
    [Kubernetes (lab)], [OpenShift], [Catatan],
    [Ingress (Traefik)], [Route], [OpenShift juga menerima Ingress dan mengubahnya menjadi Route. Route menambahkan opsi TLS _edge_, _passthrough_, _reencrypt_],
    [`securityContext` + Pod Security], [SCC `restricted-v2`], [Pengganti SCC `restricted` sejak OpenShift 4.11. UID acak, tanpa _privilege escalation_, _capabilities_ dibuang, _seccomp_ `RuntimeDefault`. Manifest Lab 9 sudah memenuhinya],
    [`kubectl`], [`oc`], [`oc` mencakup semua perintah `kubectl`, ditambah `oc login`, `oc new-project`, `oc adm`],
    [_Namespace_], [_Project_], [_Project_ = _namespace_ dengan anotasi dan kuota tambahan],
    [_Registry_ eksternal], [_Internal registry_ + ImageStream], [Pipeline bisa tetap mendorong _image_ ke _registry_ eksternal],
  )
  #v(10pt)
  #note(kind: "tip")[Uji kecocokan sebelum ke OpenShift: jalankan _image_ dengan UID acak dan _root filesystem_ _read-only_. Bila keduanya lolos, sebagian besar masalah SCC sudah tertangani.]
]

#slide(kicker: "OpenShift", title: [Route vs Ingress])[
  #two-col(
    [
```yaml
# Kubernetes: Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: transfer }
spec:
  rules:
  - http:
      paths:
      - path: /transfers
        pathType: Prefix
        backend:
          service:
            name: transfer
            port: { number: 8082 }
```
    ],
    [
```yaml
# OpenShift: Route
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: transfer }
spec:
  path: /transfers
  to:
    kind: Service
    name: transfer
  port:
    targetPort: 8082
  tls:
    termination: edge
```
    ],
  )
  #v(8pt)
  #text(size: 13pt)[Kedua objek mengarahkan _traffic_ HTTP ke Service yang sama. Perbedaannya ada di objek _routing_ saja; Deployment dan Service tidak berubah.]
]

// ════════════════════════════════════════════════════════════════════════════

#slide(kicker: "Ringkasan", title: "Hasil empat hari")[
  #two-col(
    [
      #bullets(size: 13pt,
        [Tiga service Go dengan _database-per-service_ dalam satu repositori multi-modul.],
        [_Timeout_, _retry_, dan _circuit breaker_ dengan failsafe-go, diuji dengan _fault injection_.],
        [Kontrak Protobuf, gRPC _server_ dan _client_ dengan _interceptor_.],
        [Saga dengan kompensasi, _transactional outbox_, dan _idempotent consumer_ di Kafka.],
        [OAuth2 _client credentials_ dari Hydra: _middleware_ REST dan _interceptor_ gRPC.],
      )
    ],
    [
      #bullets(size: 13pt,
        [`slog` dengan _correlation ID_, metrik Prometheus, _trace_ OpenTelemetry, _dashboard_ Grafana.],
        [Dockerfile _multi-stage_ per service dan Docker Compose untuk seluruh sistem.],
        [Manifest Kubernetes untuk seluruh sistem, diuji di k3d.],
        [_Pipeline_ CI/CD per service: _test_, _build image_, _deploy_.],
      )
    ],
  )
]

#slide(kicker: "Kartu referensi", title: "Pola Hari 4 beserta syarat penggunaannya")[
  #table(
    columns: (auto, 1fr, 1fr),
    [Pola], [Masalah yang diselesaikan], [Layak digunakan ketika],
    [_Correlation ID_ + _tracing_], [Satu transaksi tersebar di banyak _log_], [Satu _request_ melewati lebih dari satu service],
    [_Multi-stage build_ + `scratch`], [_Image_ besar dan penuh paket yang tidak dibutuhkan], [Service Go tanpa CGO],
    [_Readiness probe_], [_Traffic_ masuk ke _pod_ yang belum siap], [Selalu, untuk setiap service yang menerima _traffic_],
    [_Rolling update_], [_Downtime_ saat rilis], [Service _stateless_ dengan _readiness probe_ yang benar],
    [_Pipeline_ per service], [Rilis satu service menyeret service lain], [Tim ingin merilis service secara independen],
    [HPA], [Beban berubah-ubah sepanjang hari], [Service _stateless_ yang kinerjanya terbatas CPU],
    [GitOps], [Keadaan _cluster_ menyimpang dari repositori], [Banyak _cluster_ dan kebutuhan audit perubahan yang ketat],
  )
]

#slide(kicker: "Eksplorasi mandiri", title: "Langkah lanjutan setelah training")[
  #bullets(
    [Ulangi Lab 3 dan Lab 8 dengan nilai _fault_ yang berbeda, lalu cocokkan perilaku _breaker_ di _log_, metrik, dan _trace_.],
    [Tambahkan HPA untuk transfer di k3d, lalu beri beban dengan _load generator_ sederhana dan amati jumlah _replica_.],
    [Tulis _Jenkinsfile_ untuk account dan notification berdasarkan contoh transfer.],
    [Jalankan _image_ setiap service dengan UID acak dan `--read-only` untuk memastikan kecocokan dengan SCC `restricted-v2`.],
    [Pilih satu aplikasi internal, lalu petakan pola mana dari kartu referensi yang benar-benar dibutuhkan aplikasi tersebut.],
  )
]

#page(fill: navy-dk, footer: none)[
  #place(center + horizon)[
    #align(center)[
      #text(size: 48pt, weight: "bold", fill: white)[Tanya jawab]
      #v(12pt)
      #line(length: 56pt, stroke: 2.5pt + gold)
      #v(12pt)
      #text(size: 16pt, fill: white.transparentize(25%))[Diskusi arsitektur, kendala penerapan, dan pertanyaan seputar materi empat hari]
    ]
  ]
  #place(bottom + right, dx: -48pt, dy: -28pt, image("../_template/assets/logo-artivisi-dark.svg", width: 70pt))
]
