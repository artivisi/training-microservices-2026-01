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
    [14:15 – 15:45], [*Lab 10*: dari _commit_ hingga _rolling update_], [_Hands-on_],
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
    [_On-premise_], [Server milik sendiri di _data center_ sendiri], [Kendali penuh atas data dan jaringan], [Kapasitas harus dibeli di muka, dan tim mengelola sendiri seluruh _stack_],
    [_Private cloud_], [Platform _cloud_ khusus satu organisasi], [Kendali tetap tinggi, penyediaan _resource_ lebih cepat], [Investasi platform dan tim operasional],
    [_Public cloud_], [_Resource_ milik _cloud provider_, digunakan bersama oleh banyak pelanggan], [Elastis, pilihan _managed service_ lengkap], [Klasifikasi data dan lokasi penyimpanan harus sesuai regulasi],
    [_Hybrid_], [Gabungan model di atas], [Penempatan dipilih per _workload_], [Konektivitas, identitas, dan _observability_ lintas lokasi],
  )
  #v(10pt)
  #note[Pilihan model ditentukan per _workload_, berdasarkan klasifikasi data yang diolah _workload_ tersebut.]
]

#slide(kicker: "Model deployment", title: [_Managed_ vs _self-managed_])[
  #two-col(
    card([_Managed service_])[
      - _Cloud provider_ mengurus instalasi, _patch_, _backup_, dan _high availability_
      - Tim fokus pada aplikasi
      - Konfigurasi terbatas pada pilihan yang disediakan _cloud provider_
      - Contoh: database _managed_, Kafka _managed_, Kubernetes _managed_
    ],
    card([_Self-managed_], accent: gold.darken(15%))[
      - Tim menjalankan sendiri PostgreSQL, Kafka, Kubernetes
      - Seluruh parameter bisa diatur
      - Beban operasional: _upgrade_, _monitoring_, _restore_ data, rotasi sertifikat
      - Lazim di _on-premise_ dan _private cloud_
    ],
  )
  #v(12pt)
  #note(kind: "tip")[Untuk memilih, tanyakan siapa yang dihubungi bila service tersebut mati pukul 02.00, dan apakah pihak tersebut mampu mengaktifkannya kembali.]
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

#slide(kicker: "Portabilitas", title: [Manifest Kubernetes yang sama berjalan di semua model _deployment_])[
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
  #note[Portabilitas berlaku selama aplikasi hanya bergantung pada API Kubernetes standar. Fitur khusus satu _cloud provider_, misalnya _load balancer_ atau _storage class_ tertentu, perlu dipisahkan ke _overlay_.]
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "02", title: "Observability lintas service", subtitle: [_Log_, metrik, dan _trace_ untuk menjawab "transfer pukul 14.03 itu mengapa lambat?"])

#slide(kicker: "Observability", title: [_Log_, metrik, dan _trace_])[
  #table(
    columns: (auto, 1fr, 1fr, auto),
    [Sumber], [Pertanyaan yang dijawab], [Implementasi di studi kasus], [Disimpan di],
    [_Log_], [Apa yang terjadi pada satu _request_ tertentu?], [`slog` format JSON, `correlation_id`, `trace_id`], [Loki],
    [Metrik], [Seberapa sering, seberapa cepat, berapa yang gagal?], [`prometheus/client_golang`, _endpoint_ `/metrics`], [Prometheus],
    [_Trace_], [Di service mana sebagian besar waktu satu transaksi terpakai?], [OpenTelemetry, `otelhttp`, `otelgrpc`, _header_ Kafka], [Tempo],
  )
  #v(12pt)
  #bullets(size: 13.5pt,
    [Metrik mendeteksi adanya masalah. _Trace_ menunjukkan service yang paling banyak menyita waktu, dan _log_ berisi penyebabnya.],
    [_Trace_ dan _log_ dihubungkan oleh `trace_id`. Dari lonjakan di grafik metrik, _engineer_ mempersempit rentang waktu lalu membuka _trace_ pada rentang tersebut. Tautan langsung dari metrik ke _trace_ membutuhkan _exemplar_ Prometheus, dan fitur tersebut tidak dipasang di lab.],
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
    - _Output_ JSON ke _stdout_ sekaligus diekspor sebagai _log_ OTLP (_bridge_ `otelslog`)
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
    [_Counter_ transisi _breaker_], [transfer], [Berapa kali _breaker_ berganti status],
    [`outbox_pending`], [transfer], [_Event_ yang belum terkirim ke Kafka],
    [`notifications_processed_total{result}`], [notification], [`sent`, `duplicate`, dan `skipped`. `skipped` menghitung _event_ rusak atau yang ditolak database, dan nilainya seharusnya tetap 0],
  )
  #v(10pt)
  #note(kind: "warn")[Label `route` diisi pola ServeMux (`GET /transfers/{id}`). Bila diisi _path_ asli yang mengandung ID, jumlah _time series_ akan terus bertambah.]
]

#slide(kicker: "Tracing", title: [Meneruskan _trace context_ lewat Kafka])[
  #two-col(ratio: (1.15fr, 1fr),
    [
```go
// telemetry.Setup: hanya W3C Trace Context
otel.SetTextMapPropagator(propagation.TraceContext{})

// transfer, outbox.Insert: dalam transaksi DB yang
// sama dengan perubahan status transfer
carrier := propagation.MapCarrier{}
otel.GetTextMapPropagator().Inject(ctx, carrier)
// carrier masuk kolom trace_context,
// relay menyalinnya ke header Kafka

// notification: saat membaca message
headers := m.Headers
ctx = otel.GetTextMapPropagator().Extract(ctx,
    telemetry.KafkaHeaders{Headers: &headers})
ctx, span := c.tracer.Start(ctx, "process "+m.Topic,
    trace.WithSpanKind(trace.SpanKindConsumer))
defer span.End()
```
    ],
    [
      #set text(size: 12.5pt)
      - HTTP dan gRPC: `otelhttp` dan _stats handler_ `otelgrpc` meneruskan _header_ `traceparent` secara otomatis
      - Kafka: _relay_ berjalan di _goroutine_ terpisah tanpa _context_ dari _request_ asal, dan baru mengirim _event_ hingga ±500 ms kemudian. Karena itu _trace context_ disimpan ke baris _outbox_ saat baris tersebut ditulis
      - Hanya `traceparent` yang diteruskan. _Baggage_ tidak digunakan karena REST API diakses langsung oleh aplikasi _channel_, dan _baggage_ dari pemanggil luar itu akan ikut terkirim ke semua service yang dipanggil sesudahnya
      - Hasilnya, satu transfer tampil sebagai satu _trace_ yang mencakup tiga service
    ],
  )
]

#slide(kicker: "Stack", title: [_Observability stack_ lab dalam satu _container_ `otel-lgtm`])[
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
    [Satu _container_ `grafana/otel-lgtm` berisi _collector_, Tempo, Loki, Prometheus, dan Grafana dengan _dashboard_ bawaan.],
    [_Trace_ dan _log_ dikirim (_push_) lewat OTLP, sedangkan metrik diambil (_pull_) oleh Prometheus dari `/metrics` di setiap service.],
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

#slide(kicker: "Go dan container", title: [_Static binary_ Go menghasilkan _image_ yang kecil])[
  #two-col(
    [
      #bullets(
        [Dengan `CGO_ENABLED=0`, hasil _build_ Go berupa satu _static binary_ yang tidak membutuhkan _library_ sistem.],
        [_Image_ akhir cukup berisi _binary_ tersebut dan sertifikat CA, berukuran belasan hingga puluhan megabyte.],
        [Tanpa _shell_ dan _package manager_ di _image_, _attack surface_ lebih kecil dan hasil _scanning_ lebih bersih.],
      )
    ],
    card("Ukuran tipikal")[
      #table(
        columns: (1fr, auto),
        [_Base image_], [Ukuran kira-kira],
        [`golang:1.27.2-alpine` (_builder_)], [± 300 MB],
        [`alpine` + _binary_], [± 30 MB],
        [`scratch` + _binary_], [± 22 MB],
        [`scratch` + _binary_, terkompresi], [± 8 MB],
      )
      #text(size: 10.5pt, fill: slate)[Studi kasus: _binary_ 21–23 MB per service. `docker images` dengan _containerd image store_ menampilkan `CONTENT SIZE` ± 8 MB dan `DISK USAGE` ± 32 MB.]
    ],
  )
]

#code-slide(kicker: "Dockerfile", title: [_Multi-stage build_ untuk service transfer],
  side: [
    - _Stage_ pertama: kompilasi dengan _toolchain_ lengkap
    - _Stage_ kedua: `FROM scratch`, hanya menyalin hasil _build_
    - `-trimpath -ldflags "-s -w"`: _path_ lokal dan simbol _debug_ dibuang
    - `GOWORK=off`: _build_ hanya melibatkan modul service dan `proto`, sehingga perubahan service lain tidak membuat _cache_ menjadi tidak valid
    - `go.mod` disalin terlebih dahulu agar _layer_ hasil `go mod download` tetap di-_cache_
    - _Build context_ `studi-kasus/` karena account dan transfer membutuhkan modul `proto` (`replace ../proto`). Notification tidak menyalin `proto/`
  ],
)[
```dockerfile
FROM golang:1.27.2-alpine AS build
ENV GOWORK=off CGO_ENABLED=0
WORKDIR /src
COPY proto/go.mod proto/go.sum proto/
COPY transfer/go.mod transfer/go.sum transfer/
WORKDIR /src/transfer
RUN go mod download
COPY proto/ /src/proto/
COPY transfer/ /src/transfer/
RUN go build -trimpath -ldflags "-s -w" \
      -o /out/transfer .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt \
     /etc/ssl/certs/
COPY --from=build /out/transfer /transfer
USER 65532:65532
EXPOSE 8082
ENTRYPOINT ["/transfer"]
```
]

#slide(kicker: "Keamanan image", title: [_Non-root_ dan UID acak])[
  #two-col(
    card([`USER 65532:65532`])[
      - Proses tidak berjalan sebagai `root` walaupun _image_ dijalankan tanpa opsi tambahan
      - UID numerik dibutuhkan agar Kubernetes bisa memverifikasi `runAsNonRoot`
      - `scratch` tidak memiliki `/etc/passwd`, sehingga nama pengguna tidak bisa digunakan
    ],
    card([UID acak], accent: gold.darken(15%))[
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
    [_Config_], [Seluruh konfigurasi dibaca dari _environment variable_ oleh satu `LoadConfig` di setiap service],
    [_Backing services_], [Database, Kafka, Hydra, _collector_ diakses lewat URL dari konfigurasi sehingga bisa diganti tanpa _build_ ulang],
    [_Build, release, run_], [Setiap _commit_ menghasilkan satu _image_, dan konfigurasinya ditambahkan saat _deploy_ melalui ConfigMap dan Secret],
    [_Processes_], [Service tidak menyimpan _state_ di memori karena _state_ disimpan di database],
    [_Port binding_], [Service membuka _port_ HTTP dan gRPC sendiri: `HTTP_ADDR`, `GRPC_ADDR`],
    [_Disposability_], [Service bisa _start_ dengan cepat dan melakukan _graceful shutdown_ saat menerima `SIGTERM`],
    [_Logs_], [Service menulis _log_ JSON ke _stdout_, lalu platform mengumpulkannya],
  )
]

#code-slide(kicker: "Konfigurasi", title: [Konfigurasi wajib tidak memiliki nilai _default_],
  side: [
    - _Environment variable_ yang kosong menghentikan _startup_ dengan pesan _error_ yang menyebut nama variabel tersebut
    - _Pod_ dengan ConfigMap yang salah langsung gagal dan terlihat di `kubectl get pods`
    - Nilai _default_ yang digunakan tanpa terdeteksi, misalnya `localhost`, baru ketahuan saat transaksi pertama gagal
    - Nilai yang formatnya salah juga ditolak saat _startup_. `OTEL_EXPORTER_OTLP_ENDPOINT` tanpa _port_ membuat gRPC menghubungi _port_ 443, dan semua ekspor gagal tanpa pesan _error_ setelah service berjalan
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
        HTTPAddr:        get("HTTP_ADDR"),
        DatabaseURL:     get("DATABASE_URL"),
        AccountGRPCAddr: get("ACCOUNT_GRPC_ADDR"),
        // ... Kafka, OAuth, OTel
    }
    if len(missing) > 0 {
        return Config{}, fmt.Errorf(
            "missing required environment variables: %s",
            strings.Join(missing, ", "))
    }
    if err := checkEndpointURL(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        cfg.OTelEndpoint); err != nil {
        return Config{}, err // juga bila port kosong
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
    [Ingress], [_Routing_ HTTP dari luar _cluster_], [`/transfers` lewat Traefik bawaan k3s],
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
    - Semua _probe_ menggunakan HTTP. _Health service_ gRPC account tidak memeriksa database, jadi tidak digunakan sebagai _readiness probe_
  ],
)[
```yaml
containers:
- name: transfer
  image: studi-kasus/transfer   # tag dari overlay
  imagePullPolicy: IfNotPresent
  ports: [{ name: http, containerPort: 8082 }]
  envFrom:
  - configMapRef: { name: transfer }
  - secretRef:    { name: transfer }
  readinessProbe:
    httpGet: { path: /readyz, port: http }
    periodSeconds: 5
    failureThreshold: 2
  livenessProbe:
    httpGet: { path: /healthz, port: http }
    periodSeconds: 10
    failureThreshold: 3
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 256Mi }
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
make images VERSION=1.0.1
make k3d-import VERSION=1.0.1
kubectl -n bank set image deployment/transfer \
  transfer=studi-kasus/transfer:1.0.1
kubectl -n bank rollout status deployment/transfer
kubectl -n bank rollout undo deployment/transfer
```
    ],
    [
      #set text(size: 12.5pt)
      - Dengan `maxSurge: 1` dan `maxUnavailable: 0` di manifest, satu _pod_ tambahan dibuat terlebih dahulu sehingga jumlah _pod_ tidak pernah turun
      - _Pod_ lama baru dihentikan setelah _pod_ baru lolos _readiness probe_. Bila _image_ baru gagal _start_, _rollout_ tertahan dan _pod_ versi lama tetap melayani _request_
      - Setiap perubahan mendapat `VERSION` baru. _Build_ ulang dengan _tag_ yang sama tidak mengubah _pod_ yang berjalan, karena `IfNotPresent` dan referensi _image_ yang tidak berubah tidak memicu _rollout_
      - `rollout undo` mengembalikan versi sebelumnya. Peringatan `last-applied-configuration` yang muncul dapat diabaikan
    ],
  )
]

#code-slide(kicker: "Rolling update", title: [`preStop` dan _grace period_ saat _pod_ dihentikan],
  side: [
    - _Pod_ dikeluarkan dari daftar _endpoint_ Service dan Ingress bersamaan dengan proses penghentiannya. Selama beberapa detik, _request_ baru masih datang
    - `preStop` `sleep` 5 detik menunda `SIGTERM` sampai _pod_ tidak lagi menerima _request_ baru. Aksi `sleep` bawaan (Kubernetes 1.30+) tidak membutuhkan _shell_, yang memang tidak ada di `scratch`
    - `terminationGracePeriodSeconds` dihitung sejak `preStop` dimulai: `preStop` + _timeout_ _shutdown_ + _flush_ telemetri 5 detik. Account dan notification 30 (5 + 10 + 5), transfer 75 (5 + 60 + 5, ditambah cadangan)
    - Dengan nilai _default_ 30 detik, Kubernetes akan mengirim `SIGKILL` ke transfer di tengah saga
  ],
)[
```yaml
spec:
  # 5 s preStop + 60 s shutdownGrace
  # + 5 s flush telemetri, ditambah cadangan
  terminationGracePeriodSeconds: 75
  containers:
    - name: transfer
      lifecycle:
        preStop:
          sleep:
            seconds: 5
```
]

#slide(kicker: "Infra dari cluster", title: [_Pod_ mengakses infrastruktur di _host_])[
  #bullets(size: 13.5pt,
    [Hanya tiga service yang berjalan di k3d. PostgreSQL, Kafka, Hydra, dan `otel-lgtm` tetap berjalan dari `compose.yaml`.],
    [_Pod_ mengakses _host_ lewat nama `host.k3d.internal`.],
    [Kafka mengirim alamat _broker_ ke klien (_advertised listener_). _Listener_ tambahan pada _port_ 19092 mengirim alamat `host.k3d.internal`, sementara klien di _host_ tetap menggunakan `localhost:9092`.],
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
    - `make images VERSION=1.0.0`, `make k3d-up`, `make k3d-import VERSION=1.0.0`, `make k8s-apply`
    - Transfer lewat Ingress `localhost:8080`, cek hasilnya di Grafana
    - `kubectl scale` notification menjadi 3 dan 4 _replica_
    - Hapus `KAFKA_GROUP_ID` dari ConfigMap notification, _apply_, lalu `rollout restart`; kembalikan nilainya dan `rollout restart` lagi
    - `VERSION=1.0.1`, `set image`, `rollout status`, `rollout undo`
  ],
  "lab-08",
  [#note[`make k3d-up` menunggu 40–60 detik sampai DNS _cluster_ mengenal `host.k3d.internal`. Bila _pod_ masuk `CrashLoopBackOff` dengan pesan `no such host` setelah Docker atau laptop di-_restart_, jalankan `k3d cluster stop bank` lalu `k3d cluster start bank`.]],
)

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "05", title: "CI/CD per service", subtitle: [_Pipeline_ per service, pemetaan ke Jenkins, dan GitOps sebagai konsep])

#slide(kicker: "Mengapa per service", title: [Setiap service memiliki _pipeline_ sendiri])[
  #bullets(
    [Sistem dipecah menjadi service terutama agar setiap service bisa di-_deploy_ secara independen. Tujuan tersebut baru tercapai bila setiap service memiliki _pipeline_ sendiri.],
    [Perubahan di `studi-kasus/transfer/` hanya menjalankan _pipeline_ transfer. Perubahan di `proto/` menjalankan _pipeline_ account dan transfer karena keduanya bergantung pada kontrak tersebut.],
    [Bila semua service berbagi satu _pipeline_, pola rilisnya kembali seperti monolith: semua service ikut di-_build_ dan di-_deploy_ setiap kali ada perubahan.],
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
    - Workflow tidak menggunakan `uses:`, sehingga setiap _step_ berupa perintah _shell_ biasa
    - Logika _build_ ada di `Makefile`, sehingga bisa dijalankan sama persis di laptop
    - _Checkout_ berupa `git fetch` dengan token yang diterbitkan runner untuk _job_ tersebut. Isi lengkapnya ada di `.forgejo/workflows/transfer.yaml`
    - _Tag image_ = SHA _commit_, sehingga setiap _image_ bisa dilacak ke kode sumbernya
    - `concurrency` mengantrekan _run_ berikutnya tanpa membatalkan yang sedang berjalan, agar dua _deploy_ tidak berebut Deployment yang sama
  ],
)[
```yaml
on:
  push:
    branches: [main]
    paths:
      - studi-kasus/transfer/**
      - studi-kasus/proto/**
      - studi-kasus/go.work
      - studi-kasus/pipeline.mk
concurrency:
  group: pipeline-transfer
  cancel-in-progress: false
jobs:
  pipeline:
    runs-on: host
    env:
      REGISTRY: ${{ vars.REGISTRY }}
      IMAGE_OWNER: ${{ github.repository_owner }}
      NAMESPACE: ${{ vars.NAMESPACE }}
      VERSION: ${{ github.sha }}
    steps:
      - name: Checkout    # git fetch dengan token job
        run: ...
      - run: make -C studi-kasus/transfer test
      - run: make -C studi-kasus/transfer image
      - run: make -C studi-kasus/transfer push
      - run: make -C studi-kasus/transfer deploy
```
]

#code-slide(kicker: "Makefile", title: [Target `image`, `push`, `deploy`],
  side: [
    - Target ini ada di `studi-kasus/pipeline.mk` dan di-_include_ oleh `Makefile` setiap service
    - `REGISTRY`, `IMAGE_OWNER`, `VERSION`, `NAMESPACE` wajib diisi. Bila ada yang kosong, target berhenti dengan pesan `missing required variables`
    - _Tag_ `latest` tidak digunakan agar _rollout_ selalu menunjuk versi yang pasti
    - _Deploy_ pertama di _namespace_ kosong menjalankan `apply`: ConfigMap, Service, Deployment (dan Ingress transfer) dibuat dari `k8s/overlays/server` dengan _image_ _commit_ ini
    - `change-cause` diisi setelah `set image`, sehingga `rollout history` mencatat versi per revisi
    - `deploy` menunggu `rollout status`, sehingga _pipeline_ gagal bila _pod_ baru tidak pernah _ready_
  ],
)[
```make
IMAGE = $(REGISTRY)/$(IMAGE_OWNER)/$(SERVICE):$(VERSION)

image:
	$(call require,REGISTRY IMAGE_OWNER VERSION)
	docker build -f Dockerfile --label \
	  org.opencontainers.image.revision=$(VERSION) \
	  -t $(IMAGE) ..

deploy:
	$(call require,REGISTRY IMAGE_OWNER VERSION NAMESPACE)
	@d=$$(kubectl -n $(NAMESPACE) get deployment/$(SERVICE) \
	  --ignore-not-found -o name) || exit 1; \
	if [ -z "$$d" ]; then $(MAKE) apply || exit 1; fi
	kubectl -n $(NAMESPACE) set image \
	  deployment/$(SERVICE) $(SERVICE)=$(IMAGE)
	kubectl -n $(NAMESPACE) annotate deployment/$(SERVICE) \
	  kubernetes.io/change-cause="$(SERVICE) $(VERSION)" \
	  --overwrite
	kubectl -n $(NAMESPACE) rollout status \
	  deployment/$(SERVICE) --timeout=180s
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
        [`branches`, `paths:`], [Hanya _Multibranch Pipeline_ (_job_ lain tidak mengisi `BRANCH_NAME`): `when { branch 'main' }` + `changeset`],
        [`concurrency`], [`disableConcurrentBuilds()`],
        [_Step_ `run: make test`], [`stage('Test')`],
        [_Step_ `image`, `push`], [`stage('Build Image')`, `stage('Push')`],
        [_Step_ `deploy`], [`stage('Deploy')`],
        [_Variable_ dan _secret_ runner], [_Environment_ _folder_ dan Jenkins _credentials_],
      )
    ],
    [
```groovy
pipeline {
  agent any
  options { disableConcurrentBuilds() }
  environment { VERSION = "${env.GIT_COMMIT}" }
  stages { stage('transfer') {
    when { allOf { branch 'main'
      anyOf { changeset 'studi-kasus/transfer/**'
              changeset 'studi-kasus/proto/**' } } }
    stages {
      stage('Test') { steps {
        script { if (!env.GIT_COMMIT ||
          env.GIT_COMMIT == 'null') error('...') }
        sh 'make -C studi-kasus/transfer test' } }
      stage('Build Image') { steps {
        sh 'make -C studi-kasus/transfer image' } }
      stage('Push') { steps {
        withCredentials([usernamePassword(...)]) {
          sh 'make -C studi-kasus/transfer push' } } }
      stage('Deploy') { steps {
        withCredentials([file(...)]) {
          sh 'make -C studi-kasus/transfer deploy' } } }
    } } }
}
```
    ],
  )
]

#slide(kicker: "GitOps", title: [GitOps menyamakan _state_ _cluster_ dengan isi repositori])[
  #two-col(
    card([Model _push_ (Lab 10)])[
      #flow(
        node("runner", kind: "infra", width: 90pt, height: 46pt),
        arr(label: "kubectl", length: 80pt),
        node("cluster", width: 90pt, height: 46pt),
      )
      - Runner menyimpan _credential_ untuk mengakses _cluster_
      - Perubahan manual di _cluster_ tidak terdeteksi
      - Sederhana dan cocok sebagai langkah awal
    ],
    card([Model _pull_ (GitOps)], accent: gold.darken(15%))[
      #flow(
        node("repo config", kind: "infra", width: 100pt, height: 46pt),
        arr(label: "dibaca", dir: "l", length: 70pt),
        node("agent di cluster", width: 110pt, height: 46pt),
      )
      - _Agent_ GitOps di dalam _cluster_ membandingkan isi repositori dengan _state_ _cluster_, lalu menyamakannya
      - _Rollback_ cukup dengan `git revert`, dan riwayat perubahan tercatat sebagai riwayat _commit_
      - CI hanya memperbarui _tag image_ di repositori konfigurasi
    ],
  )
  #v(10pt)
  #note[GitOps dibahas sebagai arah pengembangan. Lab tidak memasang _tools_ GitOps. Konsepnya cukup dipahami agar organisasi dapat menilainya ketika sudah siap.]
]

#lab-slide("10", [Dari _commit_ hingga _rolling update_],
  [
    - Mengamati _pipeline_ per service berjalan otomatis setelah _push_
    - Melacak satu _commit_ hingga menjadi _image_ dengan _tag_ SHA dan _pod_ baru di _cluster_
  ],
  [
    - Membaca _workflow_ `transfer.yaml` dan target `make` yang dipanggilnya
    - Mengubah kode transfer, _commit_, lalu _push_ ke git server
    - Memantau _log pipeline_: _test_, _build image_, _push_, _deploy_. _Run_ pertama di _namespace_ kosong mencatat `first deploy, applying the overlay`
    - Memeriksa `kubectl rollout history` (versi per revisi) dan versi _image_ yang berjalan
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
      - _Collector_ OpenTelemetry sebagai DaemonSet atau _sidecar_ di setiap _cluster_
      - Penyimpanan jangka pendek dekat dengan sumber data
      - Risiko: gangguan _cluster_ ikut mematikan Grafana, Tempo, dan Loki yang dibutuhkan untuk menyelidiki gangguan tersebut
    ],
    card([_Cluster_ terpisah atau terpusat], accent: gold.darken(15%))[
      - Tempo, Loki, Prometheus, dan Grafana di _cluster_ khusus _observability_
      - Satu tempat untuk melihat semua _environment_
      - Data tetap tersedia saat _cluster_ aplikasi bermasalah
    ],
  )
  #v(12pt)
  #bullets(size: 13pt,
    [Pola yang umum: _collector_ di setiap _cluster_ aplikasi, penyimpanan dan Grafana di tempat terpusat.],
    [Kode aplikasi tidak perlu diubah karena service hanya mengenal `OTEL_EXPORTER_OTLP_ENDPOINT`. Cukup alamat tersebut yang diganti.],
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
    [_Registry_ eksternal], [_Internal registry_ + ImageStream], [_Pipeline_ tetap bisa melakukan _push image_ ke _registry_ eksternal],
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
  #text(size: 13pt)[Kedua objek mengarahkan _traffic_ HTTP ke Service yang sama. Perbedaannya hanya pada objek _routing_, sedangkan Deployment dan Service tetap sama.]
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
    [_Pipeline_ per service], [Service lain ikut dirilis setiap kali satu service berubah], [Tim ingin merilis service secara independen],
    [HPA], [Beban berubah-ubah sepanjang hari], [Service _stateless_ yang _CPU-bound_],
    [GitOps], [_State_ _cluster_ menyimpang dari repositori], [Banyak _cluster_ dan kebutuhan audit perubahan yang ketat],
  )
]

#slide(kicker: "Eksplorasi mandiri", title: "Langkah lanjutan setelah training")[
  #bullets(
    [Ulangi Lab 3 dan Lab 8 dengan nilai _fault_ yang berbeda, lalu cocokkan perilaku _breaker_ di _log_, metrik, dan _trace_.],
    [Tambahkan HPA untuk transfer di k3d, lalu beri beban dengan _load generator_ sederhana dan amati jumlah _replica_.],
    [Jalankan _Jenkinsfile_ salah satu service sebagai _Multibranch Pipeline_ di Jenkins, lalu bandingkan _log_ Jenkins dengan _log_ _run_ di runner lab.],
    [Jalankan _image_ setiap service dengan UID acak dan `--read-only` untuk memastikan kecocokan dengan SCC `restricted-v2`.],
    [Pilih satu aplikasi internal, lalu tentukan pola mana saja di kartu referensi yang benar-benar dibutuhkan aplikasi tersebut.],
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
