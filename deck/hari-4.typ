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
    Langkah lengkap ada di *Panduan Lab, bab Lab #number*. Titik awal: _tag_ #raw(start). Kode lab diambil dengan #raw("git checkout lab-" + (if number.len() == 1 { "0" + number } else { number }) + " -- studi-kasus" + (if number == "10" { " .forgejo .github .gitignore" } else { "" })).
  ]
  #v(4pt)
  #guide
]

// ════════════════════════════════════════════════════════════════════════════
#slide(kicker: "Hari 4", title: "Agenda hari ini")[
  #table(
    columns: (auto, 1fr, auto),
    [Waktu], [Topik], [Format],
    [08:00 – 08:15], [Rekap Hari 3 dan penyamaan posisi dari _checkpoint_ `lab-07` bagi peserta yang tertinggal], [Diskusi],
    [08:15 – 09:00], [Peta _concern_ microservices. Lanskap _cloud_ untuk perbankan: model _deployment_, _managed_ vs _self-managed_, service pendukung, analisis _build_/_reuse_/_buy_, regulasi, posisi Kubernetes], [Presentasi + diskusi],
    [09:00 – 10:15], [Penempatan _observability stack_ dan pengiriman log di _production_. *Lab 8*: melacak satu transfer lintas tiga service di Grafana], [_Hands-on_],
    [10:30 – 12:00], [_Containerization_, konfigurasi, Kubernetes, pemetaan ke OpenShift, HPA, dan *Lab 9* (1): seluruh sistem berjalan di k3d], [Demo + _hands-on_],
    [12:00 – 13:00], [Istirahat makan siang], [—],
    [13:00 – 13:30], [*Lab 9* (2): _rolling update_, perubahan konfigurasi, _probe_], [_Hands-on_],
    [13:30 – 14:15], [CI/CD per service dan pemetaannya ke Jenkins dan GitHub Actions; GitOps], [Presentasi + demo],
    [14:15 – 15:45], [*Lab 10*: dari _commit_ hingga _rolling update_], [_Hands-on_],
    [16:00 – 17:00], [Peta _concern_ lengkap, ringkasan keputusan desain, diskusi dan tanya jawab], [Presentasi + diskusi],
  )
]

#slide(kicker: "Peta concern microservices", title: [_Concern_ yang dibahas di Hari 4])[
  #concern-map(highlight: (6, 7, 8, 9, 10))
  #v(8pt)
  #note[Hari 1–3 banyak membahas sisi kode. Hari 4 membahas _concern_ yang sebagian besar ditangani platform: Kubernetes dan _pipeline_. _Observability_ muncul di Lab 8, yang mempraktikkan konsep dan kode dari akhir Hari 3, didahului penempatan _observability stack_ dan pengiriman log di _production_.]
]

#slide(kicker: "Studi kasus", title: "Posisi sistem di awal Hari 4")[
  #diagram(height: 250pt,
    at(0pt, 95pt, node("klien", sub: "channel-app", kind: "ext")),
    at(200pt, 95pt, node("transfer", sub: "HTTP :28082")),
    at(450pt, 10pt, node("account", sub: "gRPC :29091")),
    at(450pt, 180pt, node("Kafka", sub: "transfer-events", kind: "broker")),
    at(690pt, 180pt, node("notification", sub: "HTTP :28083")),
    at(690pt, 5pt, node("Hydra", sub: "OAuth2 :14444", kind: "infra")),
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
#section-slide(number: "01", title: [Lanskap _cloud_ untuk perbankan], subtitle: [Model _deployment_, _managed_ vs _self-managed_, service pendukung, _build_/_reuse_/_buy_, regulasi, dan posisi Kubernetes])

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

#slide(kicker: "Service pendukung", title: [Service pendukung tersedia untuk semua bahasa])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (auto, 1fr, 1fr, 1.15fr),
      inset: (x: 6pt, y: 5pt),
      [Kebutuhan], [Produk (tidak terikat bahasa)], [Integrasi di Java (Spring)], [Integrasi di Go (studi kasus)],
      [_Service registry_ dan _discovery_], [Consul, etcd, Kubernetes Service], [Spring Cloud Netflix (Eureka), Spring Cloud Consul], [Kubernetes Service DNS, alamat dari `ACCOUNT_GRPC_ADDR`],
      [_Config server_], [Spring Cloud Config Server, Consul KV, ConfigMap], [Spring Cloud Config _client_], [_Environment variable_ dari ConfigMap, dibaca `LoadConfig`],
      [_Secret_], [Vault, _secret manager_ milik _cloud provider_], [Spring Cloud Vault], [Secret Kubernetes, diisi dari Vault oleh External Secrets Operator tanpa perubahan kode],
      [SSO dan IdP], [Keycloak, Ory Hydra, ZITADEL, IdP komersial], [Spring Security: _resource server_, OAuth2 _client_, dan _Authorization Server_ _embedded_], [golang-jwt dan keyfunc (JWKS), `x/oauth2/clientcredentials`],
      [_Log server_], [Loki, Elasticsearch, OpenSearch], [_Appender_ Logback atau Log4j2, _agent_ OpenTelemetry Java], [`slog` JSON ke _stdout_ dan _bridge_ `otelslog`],
      [_Monitoring_ dan _tracing_], [Prometheus, Grafana, OTel Collector, Tempo, Jaeger], [Micrometer (Actuator), _agent_ OpenTelemetry Java], [`prometheus/client_golang`, OTel Go SDK, `otelhttp`, `otelgrpc`],
    )
  }
  #v(8pt)
  #note[Produk di kolom kedua dapat digunakan oleh service dari bahasa apa pun. Yang berbeda adalah integrasi di sisi service. Spring Cloud menyediakan integrasi siap pakai, sedangkan service Go di studi kasus bersandar pada Kubernetes, OTel SDK, dan beberapa _library_ kecil. Perbandingan bahasa dan _library_ per _concern_ (Go, Java, Node.js, PHP) ada di Hari 1. Consul dan Vault menggunakan lisensi BSL sejak 2023, sedangkan OpenBao adalah _fork_ Vault berlisensi MPL.]
]

#slide(kicker: "Build, reuse, buy", title: [Analisis _build_, _reuse_, dan _buy_ per _concern_])[
  #{
    show table.cell: set text(size: 10pt)
    table(
      columns: (auto, 0.9fr, 1fr, 1fr, 1.3fr),
      inset: (x: 6pt, y: 4.5pt),
      [_Concern_], [_Build_ (tulis sendiri)], [_Reuse_ (_open source_, dioperasikan sendiri)], [_Buy_ (_managed service_ atau produk komersial)], [Pertimbangan untuk bank],
      [Konfigurasi dan _secret_], [`LoadConfig` dengan validasi saat _startup_], [ConfigMap, OpenBao, External Secrets Operator], [_Secret manager_ milik _cloud provider_, Vault (lisensi BSL, edisi Enterprise atau HCP)], [Lokasi penyimpanan _credential_, audit akses, rotasi],
      [IdP dan SSO], [_Middleware_ dan _interceptor_ JWT, atau _authorization server_ _embedded_ (Spring Security, zitadel/oidc)], [Keycloak, Ory Hydra], [IdP komersial atau _managed_], [Semua service bergantung pada IdP, sehingga tim harus sanggup menjaga ketersediaannya],
      [_Observability_], [Setup telemetri, _handler_ `slog`], [Prometheus, Grafana, Loki, Tempo, OTel Collector], [Platform _observability_ SaaS], [_Log_ dan _trace_ bisa berisi data nasabah. Lokasi data dan retensi menentukan boleh tidaknya SaaS digunakan],
      [_Messaging_], [—], [Apache Kafka], [Kafka _managed_, distribusi Kafka komersial], [Kemampuan tim melakukan _upgrade_, menambah _broker_, dan memulihkan data],
      [_Container platform_], [—], [Kubernetes, k3s], [OpenShift, Kubernetes _managed_], [Biaya lisensi dibandingkan biaya tim platform, dukungan vendor saat audit],
      [CI/CD], [Target `make`, _pipeline_ per service], [Jenkins, git server + runner], [Layanan CI SaaS], [Akses runner ke jaringan _production_, penyimpanan _credential_ untuk _deploy_],
    )
  }
  #v(8pt)
  #note(kind: "tip")[Tulis sendiri hanya _glue code_ yang tipis: pembaca konfigurasi, _middleware_, dan setup telemetri. Perangkat lunak infrastruktur cukup di-_reuse_. Pilih _buy_ ketika kapasitas operasional tim atau ketentuan regulasi lebih cocok dengan produk yang didukung vendor.]
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
#section-slide(number: "02", title: "Lab 8: Observability lintas service", subtitle: [Penempatan _observability stack_ dan pengiriman log di _production_, lalu melacak satu transfer lintas tiga service di Grafana])

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
    [Kode aplikasi tidak perlu diubah: _trace_ dikirim ke alamat di `OTEL_EXPORTER_OTLP_ENDPOINT` dan metrik diambil dari `/metrics`. Bila log dikumpulkan _agent_ dari stdout, salinan log melalui OTLP tidak lagi dibutuhkan.],
    [_Log_ dan _trace_ bisa berisi data nasabah. Retensi dan hak akses mengikuti klasifikasi data yang sama dengan aplikasinya.],
  )
]

#slide(kicker: "Observability", title: [Pengiriman log per jenis _deployment_])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (1fr, 0.9fr, 1.1fr, 1.6fr),
      inset: (x: 6pt, y: 4pt),
      [_Deployment_], [Aplikasi Menulis ke], [_Agent_ Membaca], [Yang Perlu Diatur],
      [Kubernetes atau OpenShift], [stdout], [_File_ di `/var/log/pods`, _agent_ sebagai DaemonSet], [OpenShift Logging 6: Vector sebagai _agent_, LokiStack sebagai penyimpanan],
      [VM dengan systemd], [stdout], [journald], [`RateLimitBurst` (journald membuang log di atas batas), `Storage=persistent`, `SystemMaxUse`],
      [VM, volume log tinggi atau aplikasi Java], [_File_ JSON dengan rotasi], [_File_ tersebut], [Rotasi dengan _rename_. `copytruncate` di logrotate dapat menghilangkan baris],
      [Docker tanpa Kubernetes], [stdout], [_File_ dari _driver_ `json-file` atau journald], [`max-size` dan `max-file`, karena _driver_ `json-file` tidak merotasi secara bawaan],
    )
  }
  #v(6pt)
  #two-col(
    card([Syslog])[
      #set text(size: 11.5pt)
      - rsyslog tetap digunakan untuk log OS, perangkat jaringan, dan pengiriman ke SIEM (_Security Information and Event Management_)
      - Log aplikasi baru jarang dikirim lewat syslog: ukuran pesan terbatas, dan UDP dapat kehilangan pesan tanpa tanda
    ],
    card([Pola yang sama di semua baris], accent: gold.darken(15%))[
      #set text(size: 11.5pt)
      - Aplikasi menulis satu baris JSON per event, lengkap dengan `trace_id` dan `correlation_id`
      - _Agent_ menambahkan _metadata_, menyimpan _buffer_ di disk, lalu mengirim log. _Binary_ Go studi kasus tidak berubah
    ],
  )
  #v(4pt)
  #note(kind: "warn")[Pengiriman log tidak menjamin semua baris sampai, misalnya _file_ dirotasi sebelum dibaca _agent_. Jejak audit yang tidak boleh hilang ditulis ke database dalam transaksi yang sama dengan data bisnis, misalnya ke tabel audit atau outbox.]
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
  [#note[Konsep, kode instrumentasi, dan `otel-lgtm` dibahas di akhir Hari 3, sesi _Observability_ lintas service.]],
)

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "03", title: [_Containerization_], subtitle: [_Multi-stage build_, _static binary_ Go, _image_ minimal, dan rekap 12-factor dari Hari 1])

#decision(title: [_Container image_ sebagai artefak rilis],
  [
    - Artefak yang sama berjalan di laptop, CI, dan _production_
    - Dependensi _runtime_ ikut terkemas, sehingga tidak ada perbedaan versi antar-_server_
    - Isolasi antar-service yang berjalan di _host_ yang sama
  ],
  [
    - _Binary_ langsung di VM, dijalankan systemd
    - Paket OS (deb, rpm)
    - _Container image_ (format OCI)
  ],
  [
    - Satu _image_ per service per _commit_, dibangun dengan _multi-stage build_
    - `FROM scratch`, _non-root_ (`USER 65532:65532`), konfigurasi dari _environment variable_
  ],
  [
    - Membutuhkan _container runtime_, _container registry_, dan pemindaian _image_
    - _Image_ harus dibangun ulang ketika Go atau sertifikat CA mendapat _patch_
    - `scratch` tidak memiliki _shell_. Pemeriksaan di dalam _pod_ dilakukan dengan `kubectl debug` (_ephemeral container_)
  ],
)

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
#source(("studi-kasus/transfer/Dockerfile", "lab-09"))
]

#slide(kicker: "Keamanan image", title: [_Non-root_ dan UID acak])[
  #two-col(
    card([`USER 65532:65532`])[
      - Proses tidak berjalan sebagai `root` walaupun _image_ dijalankan tanpa opsi tambahan
      - UID numerik dibutuhkan agar Kubernetes bisa memverifikasi `runAsNonRoot`
      - `scratch` tidak memiliki `/etc/passwd`, sehingga nama pengguna tidak bisa digunakan
    ],
    card([UID acak], accent: gold.darken(15%))[
      - OpenShift dengan SCC (_Security Context Constraints_) `restricted-v2` menjalankan _container_ dengan UID acak dari rentang milik _namespace_
      - _Binary_ harus tetap berjalan dengan UID berapa pun
      - Service tidak menulis ke _filesystem_: _log_ ke _stdout_, data ke database
    ],
  )
  #v(12pt)
  #note(kind: "tip")[Uji sendiri: `docker run --user 1000770000:0 ...` harus berjalan normal. Bila gagal, kemungkinan besar service mencoba menulis _file_ ke direktori milik UID lain.]
]

#slide(kicker: "Rekap 12-factor", title: [Prinsip 12-factor dari Hari 1 yang sudah diterapkan di lab])[
  #{
    show table.cell: set text(size: 11pt)
    table(
      columns: (auto, 1fr, auto),
      inset: (x: 7pt, y: 4.5pt),
      [Prinsip], [Penerapan di studi kasus], [Lab],
      [II. _Dependencies_], [Dependensi dideklarasikan di `go.mod` setiap modul dan ikut terkompilasi ke _binary_], [Lab 1],
      [III. _Config_], [Seluruh konfigurasi dibaca dari _environment variable_ oleh satu `LoadConfig`, tanpa nilai _default_], [Lab 1, 9],
      [IV. _Backing services_], [Database, Kafka, Hydra, dan _collector_ diakses lewat URL dari konfigurasi, sehingga bisa diganti tanpa _build_ ulang], [Lab 1–2, 5, 7–8],
      [V. _Build, release, run_], [Setiap _commit_ menghasilkan satu _image_. Konfigurasi ditambahkan saat _deploy_ melalui ConfigMap dan Secret], [Lab 9–10],
      [VI. _Processes_], [Service tidak menyimpan _state_ di memori karena _state_ disimpan di database], [Lab 1, 9],
      [VII. _Port binding_], [Service membuka _port_ HTTP dan gRPC sendiri: `HTTP_ADDR`, `GRPC_ADDR`], [Lab 1, 4],
      [VIII. _Concurrency_], [Kapasitas ditambah dengan menambah _replica_ (`kubectl scale`) dan tidak memperbesar satu proses], [Lab 9],
      [IX. _Disposability_], [_Startup_ cepat dan _graceful shutdown_ saat menerima `SIGTERM`, ditambah `preStop` di Kubernetes], [Lab 1, 9–10],
      [X. _Dev/prod parity_], [_Image_ dan manifest _base_ yang sama di k3d dan di _server_ pelatihan. Perbedaannya hanya di _overlay_], [Lab 9–10],
      [XI. _Logs_], [Service menulis _log_ ke _stdout_ (format JSON sejak Lab 8), lalu platform yang mengumpulkannya], [Lab 1, 8],
    )
  }
  #v(6pt)
  #text(size: 11.5pt, fill: slate)[Tabel lengkap ada di Hari 1 (anatomi service). Faktor I (_Codebase_: satu _module_ dan satu _pipeline_ per service) dan XII (_Admin processes_: skema database diterapkan saat _startup_) tidak diulang di sini.]
]

#code-slide(kicker: "Konfigurasi", title: [_Startup_ dihentikan bila ada konfigurasi wajib yang belum diisi],
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
#source(("studi-kasus/transfer/config.go", "lab-08"))
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "04", title: "Deployment ke Kubernetes", subtitle: [_Pod_, _node_, dan _scheduling_; Deployment, Service, ConfigMap/Secret, konfigurasi terpusat, _probe_, pemetaan ke OpenShift, _rolling update_, dan HPA di k3d])

#decision(title: [Kubernetes sebagai platform _deployment_],
  [
    - Banyak service, masing-masing dengan beberapa _replica_
    - _Scheduling_ _pod_ ke _node_, _restart_ otomatis, _rolling update_
    - _Service discovery_ dan konfigurasi per _environment_
  ],
  [
    - Docker Compose di beberapa VM
    - HashiCorp Nomad
    - Kubernetes: _vanilla_, OpenShift, atau Kubernetes _managed_ milik _cloud provider_
  ],
  [
    - Manifest standar: Deployment, Service, ConfigMap, Secret, Ingress, disusun dengan Kustomize
    - Deklaratif: manifest berisi _desired state_, _controller_ menyamakan isi _cluster_ dengan manifest tersebut (_self-healing_)
    - Service DNS menggantikan _service registry_, dan manifest yang sama berjalan di OpenShift dan Kubernetes _managed_
  ],
  [
    - Platform yang kompleks: _upgrade_ _cluster_, RBAC, jaringan, dan penyimpanan membutuhkan tim platform
    - Berlebihan untuk satu atau dua service
    - Fitur khusus distribusi tetap perlu dipelajari, misalnya Route dan SCC di OpenShift
  ],
)

#let k-box(x, y, w, h, title, fill: white, stroke: 1pt + slate, dash: none, size: 10.5pt, color: navy) = at(x, y, box(width: w, height: h, fill: fill, radius: 5pt,
  stroke: (paint: stroke.paint, thickness: stroke.thickness, dash: dash), inset: (x: 7pt, y: 5pt),
  align(left + top, text(size: size, weight: "bold", fill: color, title))))
#let k-ctr(x, y, label, w: 118pt, sidecar: false) = at(x, y, box(width: w, height: 30pt, radius: 3pt,
  fill: if sidecar { gold.lighten(85%) } else { navy.lighten(85%) },
  stroke: (paint: if sidecar { gold.darken(15%) } else { navy }, thickness: 1pt),
  align(center + horizon, text(size: 9.5pt, fill: ink, label))))

#slide(kicker: "Konsep Kubernetes", title: [_Container_, _pod_, _node_, dan _cluster_])[
  #diagram(height: 262pt,
    // control plane
    k-box(0pt, 0pt, 180pt, 258pt, [_control plane_], fill: panel),
    at(12pt, 30pt, node("API server", kind: "infra", width: 156pt, height: 38pt)),
    at(12pt, 78pt, node("scheduler", sub: "memilih node", width: 156pt, height: 46pt)),
    at(12pt, 134pt, node("controller", sub: "Deployment, ReplicaSet", kind: "infra", width: 156pt, height: 46pt)),
    at(12pt, 192pt, node("etcd", sub: "state cluster", kind: "db", width: 156pt, height: 56pt)),
    // node 1
    k-box(205pt, 0pt, 315pt, 258pt, [_node_ 1 · kubelet + _container runtime_], stroke: 1pt + slate, dash: "dashed", color: slate),
    k-box(218pt, 28pt, 289pt, 105pt, [_pod_ `transfer-…-2w7zm` · IP 10.42.0.14], stroke: 1.2pt + navy),
    k-ctr(230pt, 60pt, [_container_ `transfer`]),
    k-ctr(360pt, 60pt, [`vault-agent` (_sidecar_)], w: 135pt, sidecar: true),
    at(230pt, 98pt, text(size: 9pt, fill: slate)[berbagi IP, port, dan _volume_ `/vault/secrets`]),
    at(230pt, 112pt, text(size: 8.5pt, fill: slate)[_sidecar_ ini contoh, tidak digunakan di Lab 9]),
    k-box(218pt, 143pt, 289pt, 105pt, [_pod_ `account-…` · IP 10.42.0.11], stroke: 1.2pt + navy),
    k-ctr(230pt, 175pt, [_container_ `account`]),
    // node 2
    k-box(540pt, 0pt, 315pt, 258pt, [_node_ 2 · kubelet + _container runtime_], stroke: 1pt + slate, dash: "dashed", color: slate),
    k-box(553pt, 28pt, 289pt, 105pt, [_pod_ `transfer-…-x9k2p` (_replica_ kedua)], stroke: 1.2pt + navy),
    k-ctr(565pt, 60pt, [_container_ `transfer`]),
    k-ctr(695pt, 60pt, [`vault-agent` (_sidecar_)], w: 135pt, sidecar: true),
    k-box(553pt, 143pt, 289pt, 105pt, [_pod_ `notification-…`], stroke: 1.2pt + navy),
    k-ctr(565pt, 175pt, [_container_ `notification`]),
  )
  #v(4pt)
  #bullets(size: 12pt,
    [*_Container_*: proses dari satu _image_. *_Pod_*: satu atau lebih _container_ yang berbagi IP, port, dan _volume_, selalu berjalan di satu _node_ yang sama. _Pod_ adalah unit terkecil yang ditempatkan Kubernetes. _Sidecar_ adalah _container_ pendamping di _pod_ yang sama, misalnya Vault Agent yang menulis _secret_ ke _volume_ bersama.],
    [*_Node_*: mesin (VM atau fisik) yang menjalankan kubelet dan _container runtime_. Kubelet menjalankan _container_ milik _pod_ yang sudah ditetapkan ke _node_-nya.],
  )
]

#slide(kicker: "Konsep Kubernetes", title: [_Scheduling_: menentukan _node_ tempat _pod_ berjalan])[
  #flow(
    node("kubectl apply", sub: "Deployment", kind: "ext", width: 125pt, height: 52pt),
    arr(length: 28pt),
    node("controller", sub: "ReplicaSet → pod", kind: "infra", width: 135pt, height: 52pt),
    arr(label: "Pending", length: 56pt),
    node("scheduler", sub: "filter, score, bind", width: 135pt, height: 52pt),
    arr(label: "nodeName", length: 62pt),
    node("kubelet di node", sub: "pull, start, probe", kind: "infra", width: 140pt, height: 52pt),
    arr(length: 28pt),
    node("Running", sub: "Ready", kind: "ext", width: 90pt, height: 52pt),
  )
  #v(6pt)
  #grid(columns: (1fr, 1fr, 1fr), column-gutter: 14pt,
    card([1. _Filter_])[
      #set text(size: 11pt)
      Buang _node_ yang tidak memenuhi syarat _pod_:
      - _requests_ CPU dan memori melebihi sisa _allocatable_
      - `nodeSelector` atau _affinity_ tidak cocok
      - _taint_ tanpa _toleration_ yang sesuai
      - _node_ di-_cordon_ (`SchedulingDisabled`)
    ],
    card([2. _Score_])[
      #set text(size: 11pt)
      Beri nilai _node_ yang tersisa:
      - menyebar _replica_ satu Deployment ke _node_ berbeda
      - menyeimbangkan pemakaian _resource_
      - mengutamakan _node_ yang sudah memiliki _image_
    ],
    card([3. _Bind_], accent: gold.darken(15%))[
      #set text(size: 11pt)
      Tulis `spec.nodeName` _pod_ ke API server. Kubelet _node_ tersebut melihatnya, lalu menjalankan _container_.
      #v(2pt)
      Tidak ada _node_ yang lolos: _pod_ tetap `Pending` dengan _event_ `FailedScheduling`.
    ],
  )
  #v(6pt)
  #note[_Scheduling_ dilakukan sekali per _pod_. _Pod_ yang sudah berjalan tidak dipindahkan ke _node_ lain. Bila _node_ di-_drain_ atau mati, _pod_ di sana dihapus, ReplicaSet membuat _pod_ pengganti, lalu _scheduler_ memilihkan _node_ untuk _pod_ baru tersebut.]
]

#slide(kicker: "Konsep Kubernetes", title: [Arti _schedule_ di Kubernetes])[
  #{
    show table.cell: set text(size: 11pt)
    table(
      columns: (0.9fr, 1.3fr, 1.5fr),
      [Istilah], [Arti], [Yang terlihat di _cluster_],
      [_Scheduling_, _scheduler_], [Memilih _node_ untuk _pod_ (di mana), bukan menentukan waktu (kapan)], [_Event_ `Scheduled`: `Successfully assigned bank/transfer-… to k3d-bank-server-0`. Kolom `NODE` di `kubectl get pods -o wide`],
      [`Pending`, `FailedScheduling`], [Belum ada _node_ yang memenuhi syarat _pod_], [`0/1 nodes are available: 1 Insufficient cpu.`],
      [`cordon`, `SchedulingDisabled`], [_Node_ tidak menerima _pod_ baru. _Pod_ yang sudah ada tetap berjalan], [STATUS `Ready,SchedulingDisabled` di `kubectl get nodes`],
      [`drain`], [`cordon` lalu _evict_ semua _pod_ di _node_ tersebut. Penggantinya di-_schedule_ ke _node_ lain], [`pod/web-… evicted`, `node/… drained`],
      [CronJob `schedule`], [Satu-satunya arti berdasarkan waktu: ekspresi cron untuk menjalankan Job], [`schedule: "0 1 * * *"`. Pod dari Job tersebut tetap melalui _scheduling_ biasa],
    )
  }
  #v(6pt)
  #note[Uji coba di _cluster_ k3d dengan 3 _node_: 6 _replica_ tersebar 2/2/2. Setelah satu _node_ di-_cordon_ dan Deployment di-_scale_ ke 9, _pod_ baru tidak masuk ke _node_ tersebut, tetapi 2 _pod_ lamanya tetap di sana. Setelah _node_ lain di-_drain_, 4 _pod_-nya diganti _pod_ baru di _node_ yang tersisa.]
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

#slide(kicker: "Objek Kubernetes", title: [Jenis _workload_: Deployment, StatefulSet, DaemonSet, Job, CronJob])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (0.8fr, 1.7fr, 1.5fr),
      inset: (x: 6pt, y: 4.5pt),
      [Objek], [_Pod_ yang dibuat], [Contoh],
      [Deployment], [Sejumlah _replica_ yang identik dan dapat saling menggantikan. Nama acak (`transfer-6998cc98fb-2w7zm`), dibuat dan dihapus tanpa urutan, mendukung _rolling update_], [Ketiga service studi kasus, Traefik, CoreDNS],
      [StatefulSet], [_Replica_ dengan identitas tetap: nama berurutan (`db-0`, `db-1`), nama DNS per _pod_ lewat _headless_ Service, dan PVC sendiri per _pod_ yang tetap terpasang walaupun _pod_ dibuat ulang], [PostgreSQL dan Kafka di server pelatihan Lab 10, _broker_ dan database dengan _operator_],
      [DaemonSet], [Tepat satu _pod_ di setiap _node_ (atau _node_ tertentu). _Node_ baru otomatis mendapat _pod_-nya], [_Agent_ log (Fluent Bit, Alloy), `kube-proxy`, `svclb-traefik` di k3s],
      [Job], [_Pod_ yang berjalan sampai selesai (_exit_ 0). Gagal diulang sampai `backoffLimit`], [Migrasi database, pembuatan _topic_ Kafka, impor data satu kali],
      [CronJob], [Membuat Job sesuai jadwal cron di _field_ `schedule`, satu-satunya arti _schedule_ berdasarkan waktu. `concurrencyPolicy` mengatur Job yang masih berjalan saat jadwal berikutnya tiba], [Rekonsiliasi harian, laporan, pembersihan data],
    )
  }
  #v(6pt)
  #note[Semua objek ini membuat _pod_ yang melalui _scheduling_ yang sama. Bedanya ada pada jumlah _pod_, identitasnya, dan kapan _pod_ dianggap selesai. Lab 9 hanya menggunakan Deployment.]
]

#slide(kicker: "Objek Kubernetes", title: [_Stateless_ dengan Deployment, _stateful_ dengan StatefulSet])[
  #two-col(
    card([Deployment (_stateless_)])[
      - _Pod_ pengganti mendapat nama dan IP baru
      - Semua _replica_ sama, Service membagi _request_ ke _replica_ mana pun
      - _Scale down_ menghapus _pod_ mana saja
      - Bila ada PVC, semua _replica_ menggunakan PVC yang sama, sehingga _replica_ di _node_ berbeda membutuhkan `ReadWriteMany`
      - Cocok untuk service yang menyimpan _state_ di database atau _broker_
    ],
    card([StatefulSet (_stateful_)], accent: gold.darken(15%))[
      - `db-0` yang dihapus dibuat ulang dengan nama `db-0` dan PVC `data-db-0` yang sama, sehingga datanya tetap ada
      - `db-1.db.<namespace>.svc` menunjuk satu _pod_ tertentu
      - Dibuat berurutan dari `db-0`, _scale down_ dimulai dari nomor terbesar
      - PVC `data-db-1` tetap ada setelah _scale down_, sampai dihapus manual
    ],
  )
  #v(8pt)
  #note(kind: "warn")[StatefulSet hanya memberi identitas dan _storage_ yang tetap. Replikasi data, pemilihan _primary_, dan _failover_ tetap tugas aplikasi atau _operator_-nya. Tiga _pod_ PostgreSQL dalam satu StatefulSet adalah tiga database terpisah, bukan satu _cluster_. Perilaku di atas diuji di k3d dengan StatefulSet `db` dua _replica_.]
]

#slide(kicker: "Objek Kubernetes", title: [PersistentVolume, PersistentVolumeClaim, dan StorageClass])[
  #flow(
    node("pod", sub: "volumeMounts /data", width: 130pt, height: 52pt),
    arr(label: "claimName", length: 70pt),
    node("PVC", sub: "1Gi, RWO, local-path", kind: "infra", width: 150pt, height: 52pt),
    arr(label: "bound", length: 60pt),
    node("PV", sub: "volume nyata", kind: "db", width: 130pt, height: 56pt),
    arr(label: "dibuat oleh", dir: "l", length: 80pt),
    node("StorageClass", sub: "provisioner", kind: "infra", width: 140pt, height: 52pt),
  )
  #v(4pt)
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (0.8fr, 2fr),
      inset: (x: 6pt, y: 4pt),
      [Objek atau _field_], [Arti],
      [PersistentVolumeClaim], [Permintaan _storage_ dari aplikasi: ukuran, _access mode_, dan StorageClass. Ditulis di _namespace_ aplikasi],
      [PersistentVolume], [_Volume_ yang benar-benar ada (disk _cloud_, LUN SAN, NFS, direktori lokal). Objek tingkat _cluster_, dibuat admin atau otomatis oleh StorageClass],
      [StorageClass], [Jenis _storage_ dan _provisioner_-nya. k3s: `local-path` (direktori di _node_). _Cloud_: disk blok milik _provider_. _On-premise_: Ceph, vSphere, atau SAN lewat _driver_ CSI],
      [_Access mode_], [`ReadWriteOnce` (satu _node_), `ReadWriteOncePod` (satu _pod_), `ReadOnlyMany`, `ReadWriteMany` (banyak _node_, misalnya NFS atau CephFS)],
      [`reclaimPolicy`], [`Delete` (bawaan untuk PV dinamis): PV dan datanya ikut terhapus saat PVC dihapus. `Retain`: PV tetap ada untuk dipulihkan manual],
    )
  }
  #v(4pt)
  #text(size: 10.5pt, fill: slate)[`local-path` k3s menggunakan `WaitForFirstConsumer`: PV baru dibuat di _node_ tempat _pod_ pertama di-_schedule_, lalu _pod_ terikat ke _node_ tersebut. Data di `emptyDir` hilang bersama _pod_. Ketiga service studi kasus tidak menggunakan _volume_ sama sekali (`readOnlyRootFilesystem: true`).]
]

#slide(kicker: "Objek Kubernetes", title: [Objek lain yang sering ditemui])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (0.9fr, 1.6fr, 1.4fr),
      inset: (x: 6pt, y: 4pt),
      [Objek], [Fungsi], [Di training],
      [Namespace], [Pemisah nama dan batas RBAC, _quota_, serta NetworkPolicy], [`bank` di k3d, satu _namespace_ per peserta di server pelatihan],
      [ServiceAccount, Role, RoleBinding], [Identitas _pod_ atau _pipeline_ dan haknya di API Kubernetes], [`deployer` dengan ClusterRole `edit` di _namespace_ peserta (Lab 10)],
      [Service: ClusterIP, NodePort, LoadBalancer, _headless_], [Alamat stabil di dalam _cluster_, port di setiap _node_, IP dari _load balancer_, atau DNS langsung ke setiap _pod_], [ClusterIP untuk ketiga service dan infrastruktur server pelatihan, LoadBalancer untuk Traefik],
      [Ingress, Gateway API], [_Routing_ HTTP dari luar _cluster_. Gateway API adalah penerus Ingress dengan pemisahan peran yang lebih jelas], [Ingress `transfer` lewat Traefik],
      [ResourceQuota, LimitRange], [Batas total _resource_ per _namespace_ dan nilai bawaan per _container_], [_Quota_ per peserta di server pelatihan],
      [NetworkPolicy], [_Firewall_ antar-_pod_ berdasarkan label dan _namespace_], [_Pod_ peserta hanya menerima koneksi dari _namespace_ sendiri dan Traefik],
      [PodDisruptionBudget], [Batas jumlah _pod_ yang boleh dihentikan bersamaan saat `drain` atau _upgrade_ _node_], [Belum digunakan. Dibutuhkan untuk service dengan beberapa _replica_ di _production_],
      [HorizontalPodAutoscaler], [Menambah dan mengurangi _replica_ berdasarkan metrik], [`k8s/hpa/transfer.yaml` (Lab 9, opsional)],
    )
  }
]

#slide(kicker: "Pilihan platform", title: [Satu VPS bersama, VPS per aplikasi, dan Kubernetes])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (0.75fr, 1.2fr, 1.1fr, 1.25fr),
      inset: (x: 6pt, y: 4pt),
      [Aspek], [Satu VPS untuk beberapa aplikasi], [Satu VPS per aplikasi], [Kubernetes],
      [Isolasi], [Batas proses dan _user_ dalam satu OS. Aplikasi yang menghabiskan memori atau disk mengganggu aplikasi lain], [Batas VM. Gangguan satu aplikasi tidak menyebar], [_Requests_/_limits_ per _container_, _namespace_, ResourceQuota, NetworkPolicy],
      [Dependensi OS dan _runtime_], [Digunakan bersama. _Upgrade_ untuk satu aplikasi ikut mengubah aplikasi lain, kecuali setiap aplikasi dijalankan sebagai _container_], [Bebas per aplikasi], [Dibawa di _image_ masing-masing],
      [Rilis dan _rollback_], [Skrip atau manual, biasanya dengan _downtime_ singkat], [Sama dengan VPS bersama], [_Rolling update_ dan `rollout undo` bawaan],
      [Saat gagal], [systemd me-_restart_ proses. Bila _host_ mati, semua aplikasi berhenti], [Bila _host_ mati, aplikasi tersebut berhenti sampai VM dipulihkan], [_Container_ di-_restart_. Bila _node_ mati, _pod_ pengganti di-_schedule_ ke _node_ lain],
      [Skala], [Vertikal: memperbesar VPS], [Vertikal, atau menambah VPS dan _load balancer_ secara manual], [Menambah _replica_ atau HPA. _Node_ ditambah manual atau oleh _cluster autoscaler_],
      [Pemakaian _resource_], [Padat, tetapi aplikasi saling berebut], [Banyak VM yang sebagian besar menganggur], [_Pod_ ditempatkan ke _node_ berdasarkan _requests_],
      [Biaya tetap], [Paling rendah: satu server, satu admin], [Naik sebanding jumlah aplikasi. Setiap OS di-_patch_ sendiri], [_Control plane_, minimal 3 _node_ untuk HA, dan tim platform. Versi _managed_ mengurangi beban tim],
    )
  }
  #v(6pt)
  #text(size: 11pt, fill: slate)[Hari 1 membandingkan VM dan Kubernetes dari sisi _concern_ yang ditangani tim atau platform. Tabel ini membandingkannya dari sisi operasional: isolasi, rilis, kegagalan, skala, dan biaya.]
]

#slide(kicker: "Pilihan platform", title: [Memilih tempat menjalankan aplikasi])[
  #grid(columns: (1fr, 1fr, 1fr), column-gutter: 14pt,
    card([Satu VPS untuk beberapa aplikasi])[
      #set text(size: 11.5pt)
      Layak bila:
      - aplikasi kecil, beban rendah, dan dimiliki satu tim
      - _downtime_ singkat saat rilis masih dapat diterima
      - tidak ada aturan yang mewajibkan pemisahan data
      Jalankan setiap aplikasi sebagai _container_ (Docker Compose) dengan batas memori, di belakang satu _reverse proxy_.
    ],
    card([Satu VPS per aplikasi])[
      #set text(size: 11.5pt)
      Layak bila:
      - klasifikasi data atau regulasi mewajibkan pemisahan
      - aplikasi dimiliki tim atau vendor yang berbeda
      - aplikasi membutuhkan OS tertentu atau _resource_ besar, misalnya database atau aplikasi _legacy_
      - jumlah aplikasi sedikit dan jarang dirilis
    ],
    card([Kubernetes], accent: gold.darken(15%))[
      #set text(size: 11.5pt)
      Layak bila:
      - banyak service yang dirilis sering dan independen
      - service membutuhkan beberapa _replica_, HA, atau _autoscaling_
      - beberapa tim menggunakan satu platform yang sama
      - organisasi memiliki tim platform, atau menggunakan Kubernetes _managed_
    ],
  )
  #v(8pt)
  #note[Platform yang sudah ada mengubah perhitungannya. Bila organisasi sudah menjalankan OpenShift, menambah satu aplikasi kecil ke sana lebih murah dibanding menyiapkan VPS baru. Bila belum ada platform sama sekali, membangun _cluster_ untuk dua atau tiga aplikasi biasanya berlebihan. Pilihan di antaranya: k3s satu _node_ di satu VPS, seperti `studi-kasus/server/setup.sh` di Lab 10. Manifest dan _rolling update_-nya sama, tetapi tanpa HA.]
]

#slide(kicker: "Pilihan platform", title: [Aplikasi di dalam dan di luar Kubernetes])[
  #grid(columns: (1fr, 1fr, 1fr), column-gutter: 14pt,
    card([Cocok di dalam], accent: gold.darken(15%))[
      #set text(size: 11.5pt)
      - _Stateless_: _state_ ada di database atau _broker_
      - Boleh di-_restart_ dan dipindah kapan saja, _startup_ cepat
      - HTTP atau gRPC di belakang Service dan Ingress
      - Dirilis sering, diskalakan dengan _replica_
      - Konfigurasi dari _environment_ (12-factor)
      #v(2pt)
      _Contoh_: ketiga service studi kasus, API _gateway_, _consumer_ Kafka, _batch_ dengan CronJob, _frontend_ web
    ],
    card([Bisa di dalam, dengan syarat])[
      #set text(size: 11.5pt)
      - _Stateful_ dengan _operator_ yang matang untuk replikasi, _failover_, _backup_, dan _upgrade_
      - _Node_ khusus, _storage_ yang cepat, PodDisruptionBudget
      - Tim yang menguasai aplikasi tersebut dan Kubernetes sekaligus
      #v(2pt)
      _Contoh_: PostgreSQL (CloudNativePG), Kafka (Strimzi), Elasticsearch (ECK), Redis, Vault dengan Helm _chart_ resmi
    ],
    card([Lebih baik di luar], accent: amber)[
      #set text(size: 11.5pt)
      - Membutuhkan perangkat fisik: HSM, _dongle_ lisensi, modem GSM
      - Protokol di luar HTTP/TCP biasa: UDP dengan rentang port lebar, alamat IP yang harus tetap
      - Lisensi per _host_ atau vendor tidak mendukung _container_
      - Dibutuhkan untuk memulihkan _cluster_ itu sendiri: DNS, _registry_, git server GitOps, _secret manager_
    ],
  )
  #v(8pt)
  #note[Pertanyaan utamanya: apa yang terjadi bila Kubernetes menghentikan, memindahkan, atau membatasi CPU _pod_ ini kapan saja? Service _stateless_ tidak terganggu. Database, panggilan telepon yang sedang berlangsung, dan _secret manager_ yang ter-_seal_ ulang akan terganggu.]
]

#slide(kicker: "Pilihan platform", title: [Database relasional umumnya dijalankan di luar Kubernetes])[
  #two-col(ratio: (1.25fr, 1fr),
    [
      #bullets(size: 12pt,
        [*_Storage_ mengikat _pod_ ke tempatnya.* _Volume_ `ReadWriteOnce` hanya bisa dipasang di satu _node_ atau satu _zone_. _Pod_ pengganti harus menunggu _volume_ dilepas, atau tidak bisa berjalan di _node_ lain sama sekali bila menggunakan _local volume_.],
        [*Kubernetes tidak mengenal _primary_ dan _replica_.* Kubernetes hanya me-_restart_ _pod_. Replikasi, _failover_, _backup_ dengan PITR, dan _upgrade_ versi mayor tetap prosedur database, kecuali diserahkan ke _operator_.],
        [*Perilaku Kubernetes merugikan database.* _Memory limit_ memicu OOM _kill_ di tengah transaksi, _CPU limit_ menambah latensi, dan `drain` saat _upgrade_ _node_ memicu _failover_.],
        [*Organisasi dan vendor.* DBA sudah memiliki prosedur di VM. Dukungan vendor dan lisensi per _core_ (misalnya Oracle Database) umumnya menghitung semua _core_ _host_ tempat _pod_ bisa berjalan.],
      )
    ],
    [
      #card([Pilihan umum])[
        #set text(size: 11.5pt)
        - Layanan database _managed_ (RDS, Cloud SQL, Azure Database)
        - VM atau _bare metal_ khusus database yang dikelola DBA
      ]
      #v(8pt)
      #card([Bila tetap di dalam], accent: gold.darken(15%))[
        #set text(size: 11.5pt)
        - _Operator_: CloudNativePG, Crunchy PGO, Percona
        - _Node_ khusus dengan _taint_, _storage_ lokal yang cepat
        - _Backup_ ke _object storage_, uji _restore_ berkala
        - PodDisruptionBudget agar `drain` tidak menghentikan _primary_ dan _replica_ sekaligus
      ]
    ],
  )
  #v(6pt)
  #note[Lab 9 mengikuti pola ini: service di k3d, PostgreSQL dan Kafka tetap di Docker Compose. Server pelatihan Lab 10 menjalankan PostgreSQL sebagai StatefulSet satu _instance_ dengan _volume_ `local-path`, tanpa _replica_ dan _backup_: cukup untuk training, tidak untuk _production_.]
]

#slide(kicker: "Pilihan platform", title: [Contoh aplikasi yang sering dijalankan di luar Kubernetes])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (0.8fr, 1.7fr, 1.2fr),
      inset: (x: 6pt, y: 4pt),
      [Aplikasi], [Hambatan di Kubernetes], [Praktik umum],
      [Vault, OpenBao], [Kembali ter-_seal_ setiap kali _pod_ di-_restart_ atau dipindah, kecuali menggunakan _auto-unseal_ lewat KMS atau HSM. _Secret_ untuk memulihkan _cluster_ tidak boleh bergantung pada _cluster_ yang sedang dipulihkan. HSM fisik membutuhkan akses perangkat dari _node_], [_Cluster_ Vault di VM khusus, terpisah dari _cluster_ aplikasi. Aplikasi di Kubernetes membaca _secret_ lewat Vault Agent atau External Secrets Operator],
      [Asterisk, VoIP], [SIP dan RTP menggunakan UDP. RTP membutuhkan rentang port lebar (bawaan Asterisk 10000–20000) yang tidak praktis dibuka lewat Service. NAT `kube-proxy` mengubah alamat yang ditulis di SDP. _Rolling update_ memutus panggilan yang sedang berlangsung, dan _CPU throttling_ menambah _jitter_ audio], [VM atau _bare metal_ dengan IP publik tetap. Bila di Kubernetes: `hostNetwork: true` di _node_ khusus, yang menghilangkan sebagian besar isolasi],
      [Kafka], [_Broker_ _stateful_ dengan alamat yang harus bisa dijangkau _client_ secara langsung, bukan lewat _load balancer_], [Layanan _managed_, VM khusus, atau Strimzi dengan _node_ dan _storage_ khusus],
      [Aplikasi dengan HSM, _dongle_, atau modem], [Perangkat fisik terpasang di satu _host_, sehingga _pod_ tidak bisa di-_schedule_ ke _node_ lain], [VM atau _host_ fisik tempat perangkat terpasang],
      [Produk vendor berlisensi], [Lisensi terikat _host_, MAC, atau jumlah _core_. Vendor sering tidak mendukung instalasi di _container_], [Sesuai matriks dukungan vendor, umumnya VM],
      [Dependensi _cluster_], [DNS, _registry_ _image_, git server GitOps, IdP, dan _monitoring_ dibutuhkan untuk memulihkan atau memantau _cluster_. Bila ada di dalamnya, ikut mati bersama _cluster_], [Di luar _cluster_ yang dilayani, atau di _cluster_ manajemen terpisah],
    )
  }
]

#slide(kicker: "Production", title: [Pilihan _cluster_ Kubernetes untuk _production_])[
  #{
    show table.cell: set text(size: 10pt)
    table(
      columns: (1.45fr, auto, 1.1fr, 1fr, 1.9fr),
      inset: (x: 5pt, y: 3.5pt),
      [Pilihan], [Jenis], [Pengelola _Control Plane_], [Lisensi dan Dukungan], [Biaya Berjalan],
      [OpenShift Container Platform \ #text(size: 9pt)[#link("https://www.redhat.com/en/technologies/cloud-computing/openshift")[`redhat.com/openshift`]]], [_Self-managed_], [Tim bank], [Langganan Red Hat], [Langganan per _core_, server, dan tim platform],
      [OKD (versi komunitas OpenShift) \ #text(size: 9pt)[#link("https://okd.io")[`okd.io`]]], [_Self-managed_], [Tim bank], [Apache-2.0, dukungan komunitas], [Server dan tim platform, tanpa langganan],
      [RKE2 (SUSE Rancher) \ #text(size: 9pt)[#link("https://docs.rke2.io")[`docs.rke2.io`]]], [_Self-managed_], [Tim bank], [Apache-2.0, dukungan SUSE opsional], [Server dan tim platform, ditambah langganan SUSE bila membutuhkan dukungan vendor],
      [kubeadm (_vanilla_) \ #text(size: 9pt)[#link("https://kubernetes.io/docs/reference/setup-tools/kubeadm/")[`kubernetes.io/docs/…/kubeadm`]]], [_Self-managed_], [Tim bank], [Apache-2.0, tanpa vendor], [Server dan tim platform. CNI, Ingress, dan _storage_ dipilih dan dirawat sendiri],
      [k3s \ #text(size: 9pt)[#link("https://k3s.io")[`k3s.io`]]], [_Self-managed_], [Tim bank], [Apache-2.0], [Server kecil, cocok untuk _edge_ atau kantor cabang],
      [EKS, GKE, AKS \ #text(size: 9pt)[#link("https://aws.amazon.com/eks/pricing/")[`aws.amazon.com/eks/pricing`]] \ #text(size: 9pt)[#link("https://cloud.google.com/kubernetes-engine/pricing")[`cloud.google.com/kubernetes-engine/pricing`]] \ #text(size: 9pt)[#link("https://azure.microsoft.com/pricing/details/kubernetes-service/")[`azure.microsoft.com/…/kubernetes-service`]]], [_Managed_], [_Cloud provider_. Region Jakarta (AWS, Google Cloud) dan Indonesia Central (Azure)], [Bayar sesuai pemakaian], [_Control plane_ ± US\$0,10 per jam per _cluster_ (± US\$73 per bulan), ditambah _node_. AKS _tier_ Free tanpa biaya _control plane_. EKS pada versi Kubernetes _extended support_ US\$0,60 per jam],
      [ROSA (OpenShift di AWS) \ #text(size: 9pt)[#link("https://aws.amazon.com/rosa/pricing/")[`aws.amazon.com/rosa/pricing`]]], [_Managed_], [Red Hat dan AWS. Tersedia di region Jakarta], [Langganan melalui AWS], [US\$0,25 per jam per _cluster_, ditambah US\$0,171 per 4 vCPU _node_ per jam, ditambah EC2],
    )
  }
  #v(4pt)
  #text(size: 10.5pt, fill: slate)[Harga _managed_ per Oktober 2026 dari situs resmi masing-masing, belum termasuk _node_, _storage_, dan jaringan. Pada _self-managed_, biaya terbesar umumnya adalah tim platform yang melakukan _upgrade_, _patching_, dan pemulihan _cluster_, bukan lisensi. VMware Tanzu tidak dicantumkan karena Broadcom sedang menggabungkannya ke VMware Cloud Foundation dan tidak lagi menawarkannya sebagai produk terpisah.]
]

#decision(title: [k3d sebagai _cluster_ Kubernetes untuk training],
  [
    - _Cluster_ di laptop setiap peserta, mudah dibuat dan dihapus
    - Kebutuhan RAM kecil, berjalan di Docker yang sudah terpasang
    - _Image_ hasil _build_ lokal bisa langsung dijalankan tanpa _registry_
  ],
  [
    - minikube
    - kind (Kubernetes di dalam Docker)
    - Kubernetes bawaan Docker Desktop, yang tidak tersedia di Docker Engine Linux
    - k3d (k3s di dalam Docker)
  ],
  [
    - k3d dengan versi k3s yang di-_pin_ (`rancher/k3s:v1.36.5-k3s1`), dibuat dengan `make k3d-up` dan dihapus dengan `make k3d-down`. Setiap _node_ adalah satu _container_ Docker (`k3d-bank-server-0`)
    - Traefik Ingress bawaan k3s. _Port_ 28080 laptop diteruskan oleh _load balancer_ k3d ke Traefik (`-p 28080:80@loadbalancer`)
    - `k3d image import` menyalin _image_ dari Docker lokal ke _cluster_
  ],
  [
    - k3s berbeda dengan OpenShift: SCC dan Route dibahas di bagian OpenShift
    - Komponen bawaan k3s (Traefik, metrics-server) belum tentu ada di _cluster_ lain
    - Akses ke infrastruktur lewat `host.k3d.internal` hanya berlaku di lab laptop
    - k3d, kind, dan minikube hanya untuk pengembangan dan pengujian, bukan untuk _production_
  ],
)

#slide(kicker: "Lab 9", title: [Arsitektur _deployment_ di laptop])[
  #diagram(height: 330pt,
    at(150pt, 0pt, rect(width: 470pt, height: 325pt, radius: 6pt, fill: panel.lighten(40%),
      stroke: (paint: navy, thickness: 1pt, dash: "dashed"))),
    at(162pt, 8pt, text(size: 10.5pt, weight: "bold", fill: navy)[_cluster_ k3d · _namespace_ `bank`]),
    at(0pt, 135pt, node("klien", sub: "localhost:28080", kind: "ext", width: 110pt)),
    at(170pt, 135pt, node("Ingress", sub: "Traefik", kind: "infra", width: 110pt)),
    at(320pt, 135pt, node("transfer", sub: "Deployment")),
    at(485pt, 45pt, node("account", sub: "Deployment", width: 120pt)),
    at(485pt, 235pt, node("notification", sub: "Deployment", width: 120pt)),
    edge((110pt, 163pt), (170pt, 163pt)),
    edge((280pt, 163pt), (320pt, 163pt)),
    edge((440pt, 150pt), (485pt, 80pt), label: "gRPC", label-dx: -26pt),
    at(680pt, 0pt, text(size: 10.5pt, weight: "bold", fill: slate)[`compose.yaml` di _host_]),
    at(680pt, 22pt, node("PostgreSQL", sub: "3 database", kind: "db", width: 150pt, height: 60pt)),
    at(680pt, 98pt, node("Kafka", sub: ":19093", kind: "broker", width: 150pt)),
    at(680pt, 170pt, node("Hydra", sub: ":14444", kind: "infra", width: 150pt)),
    at(680pt, 242pt, node("otel-lgtm", sub: ":14317", kind: "infra", width: 150pt)),
    edge((620pt, 175pt), (680pt, 175pt), both: true),
    at(560pt, 300pt, text(size: 10pt, fill: slate)[`host.k3d.internal`]),
  )
]

#slide(kicker: "Konfigurasi terpusat", title: [Pilihan tempat menyimpan konfigurasi])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (1fr, 1.2fr, auto, 1.2fr),
      inset: (x: 6pt, y: 5pt),
      [Opsi], [Cara kerja], [Di studi kasus], [Layak digunakan ketika],
      [_Environment variable_], [Diisi oleh proses yang menjalankan service: Makefile, Docker Compose, atau Kubernetes], [Lab 1–10], [Selalu, sebagai antarmuka antara service dan platform],
      [ConfigMap dan Secret], [Objek Kubernetes, diteruskan ke _container_ sebagai _environment variable_ atau _file_], [Lab 9–10], [Service berjalan di Kubernetes dan nilainya berbeda per _cluster_],
      [_Config server_ (Spring Cloud Config, Consul KV)], [Service mengambil nilai dari server pusat saat _startup_. Nilai baru dapat dimuat tanpa _restart_ melalui _refresh_ (Spring Cloud Config) atau _watch_ (Consul)], [Tidak digunakan], [Banyak service berbagi nilai yang sering berubah, atau nilai harus berubah tanpa _restart_],
      [_Secret manager_ (Vault, _secret manager_ milik _cloud provider_)], [Penyimpanan terenkripsi dengan audit akses dan rotasi _credential_], [Tidak digunakan], [_Credential_ _production_ dengan kewajiban audit dan rotasi],
      [External Secrets Operator], [_Operator_ di _cluster_ menyalin nilai dari _secret manager_ ke Secret Kubernetes], [Tidak digunakan], [Sumber nilai di _secret manager_, sementara service tetap membaca _environment variable_],
    )
  }
  #v(8pt)
  #note(kind: "warn")[Secret Kubernetes disimpan di etcd dalam bentuk base64, tidak terenkripsi kecuali _encryption at rest_ diaktifkan di _cluster_. RBAC menentukan siapa yang boleh membacanya. Secret _overlay_ k3d di repositori hanya berisi _credential_ lab.]
]

#slide(kicker: "Konfigurasi terpusat", title: [Konfigurasi statis dan konfigurasi dinamis])[
  #two-col(
    card([Statis: dibaca sekali saat _startup_ (studi kasus)])[
      - `LoadConfig` membaca _environment variable_ satu kali. Perubahan ConfigMap tidak terlihat oleh _pod_ yang sedang berjalan
      - Nilai baru berlaku setelah `kubectl rollout restart`, yang berjalan sebagai _rolling update_ dengan _readiness probe_ seperti rilis kode
      - Nilai yang digunakan setiap _pod_ jelas, yaitu nilai saat _pod_ tersebut dibuat
      - Lab 9: setelah `KAFKA_GROUP_ID` dihapus dan `rollout restart`, _pod_ baru gagal _start_ dan _rollout_ tertahan, sementara _pod_ lama tetap melayani
    ],
    card([Dinamis: dimuat ulang tanpa _restart_], accent: gold.darken(15%))[
      - Service memantau sumber konfigurasi: _config server_, _watch_ Consul, atau _file_ dari ConfigMap yang di-_mount_ sebagai _volume_
      - Kode harus memvalidasi nilai baru dan menangani perubahan nilai di tengah _request_ yang sedang berjalan
      - Saat menyelidiki gangguan, nilai yang berlaku pada waktu kejadian lebih sulit dipastikan
      - Cocok untuk _feature flag_ dan batas operasional, misalnya _rate limit_
    ],
  )
  #v(10pt)
  #note[Aturan tanpa nilai _default_ berlaku untuk semua opsi. _Key_ yang hilang di sumber mana pun menghentikan _startup_ dengan pesan _error_. Service tidak berjalan dengan nilai tebakan.]
]

#code-slide(kicker: "Probe", title: [_Readiness_ dan _liveness probe_ di manifest],
  side: [
    - Konsepnya dibahas di Hari 1 (anatomi service): `/healthz` menjawab "apakah proses ini macet dan perlu di-_restart_?", `/readyz` menjawab "apakah _pod_ ini boleh menerima _traffic_ sekarang?"
    - `readinessProbe` gagal 2 kali berturut-turut (±10 detik): _pod_ dikeluarkan dari _endpoint_ Service, tidak di-_restart_
    - `livenessProbe` gagal 3 kali berturut-turut (±30 detik): kubelet me-_restart_ _container_
    - `startupProbe` untuk service yang _startup_-nya lama, misalnya memuat _cache_ besar. Selama belum lolos, _liveness_ dan _readiness_ belum dijalankan. Studi kasus tidak menggunakannya karena service siap dalam waktu kurang dari satu detik
    - _Health service_ gRPC account tidak memeriksa database, sehingga tidak digunakan sebagai _readiness probe_
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
    timeoutSeconds: 3
    failureThreshold: 2
  livenessProbe:
    httpGet: { path: /healthz, port: http }
    periodSeconds: 10
    failureThreshold: 3
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 256Mi }
```
#source(("studi-kasus/k8s/base/transfer/deployment.yaml", "lab-09"))
]

#slide(kicker: "Probe", title: [Tindakan Kubernetes pada setiap skenario])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (1fr, auto, auto, 1.6fr),
      inset: (x: 6pt, y: 5pt),
      [Kondisi], [`/healthz`], [`/readyz`], [Tindakan Kubernetes dan alasannya],
      [_Startup_, database belum bisa dihubungi], [Belum menjawab], [Belum menjawab], [_Ping_ database saat _startup_ gagal, sehingga proses berhenti dengan _error_. _Container_ di-_restart_ dengan jeda yang makin panjang (`CrashLoopBackOff`). _Pod_ belum pernah menerima _traffic_],
      [Database milik service mati setelah _startup_], [200], [503], [_Pod_ dikeluarkan dari _endpoint_ Service tanpa _restart_, lalu menerima _traffic_ lagi setelah _ping_ berhasil],
      [Proses macet, server HTTP tidak menjawab], [_Timeout_], [_Timeout_], [_Container_ di-_restart_ setelah 3 kegagalan _liveness_, karena hanya _restart_ yang bisa memperbaiki proses yang macet],
      [_Overload_], [Lambat], [Lambat, atau 503 bila _ping_ database melewati 2 detik], [Jawaban yang melewati `timeoutSeconds` dihitung gagal (_readiness_ 3 detik, _liveness_ 1 detik). _Readiness_ mengurangi _traffic_ ke _pod_ tersebut, tetapi _liveness_ yang terlalu ketat bisa me-_restart_ _pod_ yang sebenarnya hanya sibuk],
      [Account lambat atau mati (dilihat dari transfer)], [200], [200], [Tidak ada tindakan. _Readiness_ transfer tidak memeriksa account, karena gangguan account ditangani _circuit breaker_ (Hari 2)],
    )
  }
  #v(8pt)
  #note(kind: "warn")[Kesalahan umum: _liveness_ memeriksa database. Saat database mati, semua _pod_ di-_restart_ bersamaan, padahal _restart_ tidak memperbaiki database.]
]

#code-slide(kicker: "Security context", title: [_Security context_ yang memenuhi SCC `restricted-v2`],
  side: [
    - Tidak ada `runAsUser`: platform yang memilih UID, sesuai perilaku OpenShift
    - `readOnlyRootFilesystem` aman karena service tidak menulis _file_
    - Manifest yang sama berlaku di k3d dan di _cluster_ yang menerapkan kebijakan ketat
  ],
)[
```yaml
spec:
  securityContext:          # level pod
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
    # runAsUser sengaja tidak diisi
  containers:
  - name: transfer
    securityContext:        # level container
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```
#source(("studi-kasus/k8s/base/transfer/deployment.yaml", "lab-09"))
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
  ingressClassName: traefik
  rules:
  - http:
      paths:
      - path: /transfers
        pathType: Prefix
        backend:
          service:
            name: transfer
            port: { name: http }
```
#source(("studi-kasus/k8s/base/transfer/ingress.yaml", "lab-09"))
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
    targetPort: http
  tls:
    termination: edge
```
#source(ilustrasi: true)
    ],
  )
  #v(8pt)
  #text(size: 13pt)[Kedua objek mengarahkan _traffic_ HTTP ke Service yang sama. Perbedaannya hanya pada objek _routing_, sedangkan Deployment dan Service tetap sama.]
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
#source(("studi-kasus/k8s/base/transfer/deployment.yaml", "lab-09"))
]

#code-slide(kicker: "Scaling", title: [_Horizontal Pod Autoscaler_ (HPA)],
  side: [
    - HPA menambah atau mengurangi _replica_ berdasarkan metrik, umumnya CPU terhadap `requests`
    - Syarat: `resources.requests` terisi dan _metrics-server_ berjalan (k3s menyediakannya)
    - Service harus _stateless_ agar _replica_ bisa ditambah kapan saja
    - _Scaling_ transfer tidak menolong bila yang lambat adalah database account
    - Dicoba mandiri: `make hpa-apply`, `make hpa-watch`, `make hpa-load DURATION=180 CONCURRENCY=10` (panduan Lab 9)
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
  minReplicas: 1
  maxReplicas: 4
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```
#source(("studi-kasus/k8s/hpa/transfer.yaml", "lab-09"))
]

#slide(kicker: "Infra dari cluster", title: [_Pod_ mengakses infrastruktur di _host_])[
  #bullets(size: 13.5pt,
    [Hanya tiga service yang berjalan di k3d. PostgreSQL, Kafka, Hydra, dan `otel-lgtm` tetap berjalan dari `compose.yaml`.],
    [_Pod_ mengakses _host_ lewat nama `host.k3d.internal`.],
    [Kafka mengirim alamat _broker_ ke klien (_advertised listener_). _Listener_ tambahan pada _port_ 19093 mengirim alamat `host.k3d.internal`, sementara klien di _host_ tetap menggunakan `localhost:19092`.],
    [Token dari Hydra membawa `iss` = `http://localhost:14444/`. _Pod_ tetap memeriksa _issuer_ tersebut, tetapi mengambil JWKS dan token lewat `host.k3d.internal`.],
  )
  #v(8pt)
  #note(kind: "warn")[Di _cluster_ sungguhan, infrastruktur memiliki nama DNS sendiri sehingga perbedaan alamat _issuer_ seperti ini tidak muncul. Bagian ini khusus untuk lab di laptop.]
]

#code-slide(kicker: "Troubleshooting", title: [`kubectl debug` untuk _image_ tanpa _shell_],
  side: [
    - _Image_ `scratch` tidak berisi `sh`, sehingga `kubectl exec` gagal
    - `kubectl debug` menambah _ephemeral container_ berisi _tools_ ke _pod_ yang berjalan, tanpa _restart_
    - _Container_ debug berbagi jaringan dengan _pod_. `--target` menambah _process namespace_: proses service menjadi PID 1
    - `runAsNonRoot` di tingkat _pod_ menolak `busybox` (_root_). `root.yaml` mengizinkan _root_ khusus untuk _container_ debug, `--profile=general` menambah `SYS_PTRACE`
    - _Namespace_ `restricted` dan SCC `restricted-v2` menolak _container root_: hanya pemeriksaan jaringan dan DNS
  ],
)[
```bash
kubectl -n bank debug -it $POD --image=busybox:1.37.0 \
  --target=transfer --profile=general \
  --custom=k8s/debug/root.yaml -- sh

# nilai ConfigMap/Secret yang dibaca proses
tr '\0' '\n' < /proc/1/environ | sort
# file di container transfer
ls -l /proc/1/root/ /proc/1/root/etc/ssl/certs/
# name resolution
cat /etc/resolv.conf; nslookup account
# port service tujuan
nc -zv -w 2 account 9091
wget -qO- account:8081/readyz
```
#source(("studi-kasus/k8s/debug/root.yaml", "lab-09"))
]

#lab-slide("9", [Menjalankan seluruh sistem di k3d],
  [
    - Mengemas tiga service menjadi _image_ minimal dan _non-root_
    - Menerapkan manifest yang disediakan ke _cluster_ k3d
    - Melakukan _scaling_, perubahan konfigurasi, dan _rolling update_
  ],
  [
    - `make images VERSION=1.0.0`, `make k3d-up`, `make k3d-import VERSION=1.0.0`, `make k8s-apply`
    - Transfer lewat Ingress `localhost:28080`, cek di Grafana
    - Kolom `NODE`, _pod_ `Pending` karena `Insufficient cpu`
    - `kubectl scale` notification menjadi 3 dan 4 _replica_
    - Hapus `KAFKA_GROUP_ID` dari ConfigMap notification, _apply_, lalu `rollout restart`; kembalikan nilainya dan `rollout restart` lagi
    - `VERSION=1.0.1`, `set image`, `rollout status`, `rollout undo`
    - `kubectl debug`: konfigurasi, _file_, DNS, port; kasus port dan nama yang salah
  ],
  "lab-08",
  [#note[`no such host` setelah Docker di-_restart_: `k3d cluster stop bank`, lalu `k3d cluster start bank`. `Empty reply from server` dari `localhost:28080`: Traefik belum siap, tunggu `kubectl -n kube-system rollout status deploy/traefik`.]],
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
#source((".forgejo/workflows/transfer.yaml", "lab-10"))
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
#source(("studi-kasus/pipeline.mk", "lab-10"))
]

#slide(kicker: "Lab 10", title: [Arsitektur _pipeline_ di lab])[
  #diagram(height: 270pt,
    at(0pt, 30pt, node("laptop peserta", sub: "git push", kind: "ext", width: 130pt)),
    at(215pt, 30pt, node("git server", sub: "repositori", kind: "infra", width: 130pt)),
    at(450pt, 30pt, node("runner CI", sub: "pusat", kind: "infra", width: 130pt)),
    at(690pt, 30pt, node("server pelatihan", sub: "namespace per peserta", width: 160pt)),
    at(215pt, 190pt, node("container registry", sub: "di git server", kind: "infra", width: 150pt)),
    at(0pt, 190pt, node("k3d laptop", sub: "make pipeline-k3d", width: 130pt)),
    edge((130pt, 58pt), (215pt, 58pt), label: "push"),
    edge((345pt, 58pt), (450pt, 58pt), label: "trigger"),
    edge((580pt, 58pt), (690pt, 58pt), label: "deploy"),
    edge((480pt, 86pt), (365pt, 200pt), label: "push image", label-dx: 40pt),
    edge((65pt, 86pt), (65pt, 190pt), label: "k3d image import", dash: "dashed", label-dx: 55pt, label-dy: -6pt),
    edge((365pt, 230pt), (740pt, 86pt), label: "pull", dash: "dashed", label-dx: 50pt, label-dy: 10pt),
  )
  #note[Alamat server dan akses setiap peserta dibagikan saat lab.]
]

#slide(kicker: "Lab 10", title: [Lab 10 di server sendiri])[
  #diagram(height: 250pt,
    at(150pt, 0pt, rect(width: 700pt, height: 250pt, radius: 6pt, stroke: (paint: slate, thickness: 1pt, dash: "dashed"))),
    at(162pt, 8pt, text(size: 10pt, fill: slate)[VPS Ubuntu 24.04, 4 vCPU, 8 GB · `studi-kasus/server/setup.sh`]),
    at(0pt, 100pt, node("laptop", sub: "git push (HTTPS)", kind: "ext", width: 115pt)),
    at(185pt, 100pt, node("Caddy", sub: "80, 443, TLS", kind: "infra", width: 115pt)),
    at(370pt, 35pt, node("git server", sub: "git., registry, Actions", kind: "infra", width: 170pt)),
    at(640pt, 35pt, node("runner", sub: "label host", kind: "infra", width: 170pt)),
    at(370pt, 170pt, node("k3s", sub: "Traefik :8080, namespace service", width: 170pt)),
    at(640pt, 170pt, node("namespace infra", sub: "Postgres, Kafka, Hydra, otel", kind: "db", width: 170pt)),
    edge((115pt, 128pt), (185pt, 128pt)),
    edge((300pt, 118pt), (370pt, 70pt), label: "git.", label-dx: -10pt),
    edge((300pt, 138pt), (370pt, 190pt), label: "auth., app.", label-dx: -30pt, label-dy: 4pt),
    edge((540pt, 63pt), (640pt, 63pt), label: "job"),
    edge((680pt, 91pt), (500pt, 170pt), label: "make deploy", label-dx: 40pt),
    edge((420pt, 170pt), (420pt, 91pt), label: "pull image", dash: "dashed", label-dx: -45pt),
    edge((540pt, 198pt), (640pt, 198pt), both: true),
  )
  #v(4pt)
  #bullets(size: 12.5pt,
    [Satu _script_ memasang semua yang disediakan server pelatihan: git server dengan registry dan runner, k3s, infrastruktur lab, _namespace_, dan _kubeconfig_ untuk _pipeline_.],
    [Syaratnya: domain sendiri atau nama gratis dari DuckDNS, tiga _record_ DNS (`git.`, `auth.`, `app.`) ke IP VPS, dan port 80/443 terbuka. Langkah lengkapnya ada di Lab 10, Langkah 11.],
  )
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
      anyOf { triggeredBy 'UserIdCause'
              changeset 'studi-kasus/transfer/**'
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
#source(("studi-kasus/transfer/Jenkinsfile", "lab-10"))
    ],
  )
]

#slide(kicker: "Tiga runner", title: [Satu _pipeline_, tiga runner CI])[
  #table(
    columns: (0.8fr, 1fr, 1fr, 1.2fr),
    [Tahap], [Runner git server], [Jenkins], [GitHub Actions],
    [_Checkout_], [`git fetch`, _token_ _job_], [_Checkout_ SCM bawaan], [`git fetch`, `GITHUB_TOKEN`],
    [_Tools_], [Terpasang di host], [Terpasang di _agent_], [`install-tools.sh`, versi dan SHA-256 tetap],
    [Test], [`run: make test`], [`stage('Test')`], [`run: make test`],
    [Build image], [`run: make image`], [`stage('Build Image')`], [`run: make image`],
    [Push], [Registry git server], [`stage('Push')`], [`ghcr.io`, `GITHUB_TOKEN`],
    [Deploy], [`run: make deploy`], [`stage('Deploy')`], [`e2e-k3d.yaml`: `make pipeline-k3d` ke k3d di _runner_],
  )
  #v(8pt)
  #note[_Run_ GitHub Actions dapat dibuka publik di `github.com/artivisi/training-microservices-2026-01/actions`. `e2e-k3d` gagal bila ada respons selain 2xx selama _rolling update_ transfer.]
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
  #note[Contoh _drift_ di Lab 10: `make deploy` hanya menjalankan `kubectl set image`. Perubahan di `k8s/overlays/server/config.yaml` baru sampai ke _cluster_ setelah `make k8s-apply-server` dijalankan manual, dan `kubectl edit` oleh siapa pun bertahan sampai ada yang menimpanya.]
]

#slide(kicker: "GitOps", title: [Empat prinsip GitOps])[
  #table(
    columns: (0.9fr, 1.4fr, 1.4fr),
    [Prinsip], [Artinya], [Kondisi di Lab 10],
    [_Declarative_], [_State_ yang diinginkan ditulis sebagai manifest, bukan sebagai urutan perintah], [Manifest Kustomize sudah ada, tetapi _deploy_ menjalankan perintah imperatif `kubectl set image`],
    [_Versioned and immutable_], [_State_ disimpan di Git. Setiap perubahan menjadi _commit_ baru dan versi lama tetap bisa dipulihkan], [_Tag image_ yang sedang berjalan tidak tercatat di repositori, hanya di anotasi `change-cause` di _cluster_],
    [_Pulled automatically_], [_Agent_ di dalam _cluster_ mengambil _state_ dari repositori], [Runner mendorong perubahan ke _cluster_ dengan _kubeconfig_ milik peserta],
    [_Continuously reconciled_], [_Agent_ terus membandingkan _state_ di repositori dengan _state_ _cluster_ dan memperbaiki selisihnya], [Tidak ada pembanding. Selisih baru terlihat bila ada yang memeriksa manual],
  )
  #v(6pt)
  #text(size: 11pt, fill: slate)[Rumusan prinsip dari OpenGitOps (proyek CNCF), versi 1.0.0.]
]

#slide(kicker: "GitOps", title: [Repositori aplikasi dan repositori konfigurasi])[
  #diagram(height: 250pt,
    at(0pt, 20pt, node("developer", kind: "ext", width: 110pt)),
    at(180pt, 20pt, node("repo aplikasi", sub: "kode + Dockerfile", kind: "infra", width: 140pt)),
    at(400pt, 20pt, node("CI", sub: "test, image, push", kind: "infra", width: 140pt)),
    at(640pt, 20pt, node("registry", sub: "tag = SHA", kind: "infra", width: 150pt)),
    at(180pt, 175pt, node("reviewer", sub: "tim rilis", kind: "ext", width: 140pt)),
    at(400pt, 175pt, node("repo konfigurasi", sub: "manifest per environment", kind: "infra", width: 160pt)),
    at(640pt, 175pt, node("cluster", sub: "agent GitOps", width: 150pt)),
    edge((110pt, 48pt), (180pt, 48pt), label: "push"),
    edge((320pt, 48pt), (400pt, 48pt), label: "trigger"),
    edge((540pt, 48pt), (640pt, 48pt), label: "push image"),
    edge((470pt, 76pt), (470pt, 175pt), label: "commit tag image", label-dx: 60pt),
    edge((320pt, 203pt), (400pt, 203pt), label: "approve PR"),
    edge((640pt, 203pt), (560pt, 203pt), label: "pull"),
    edge((715pt, 175pt), (715pt, 76pt), label: "pull image", dash: "dashed", label-dx: 45pt),
  )
  #bullets(size: 12.5pt,
    [CI tidak lagi memegang _credential_ _cluster_. CI cukup memiliki akses tulis ke repositori konfigurasi.],
    [Promosi dev → staging → _production_ berupa _pull request_ yang menyalin _tag image_ ke _overlay_ berikutnya. Persetujuan rilis dicatat sebagai _review_ PR.],
  )
]

#code-slide(kicker: "GitOps", title: [Isi repositori konfigurasi dan _step_ CI],
  side: [
    - Struktur _base_ dan _overlay_ sama dengan `studi-kasus/k8s`. Setiap _environment_ menjadi satu _overlay_
    - Setiap rilis hanya mengubah baris `newTag`, sehingga _diff_ PR mudah dibaca
    - _Step_ `deploy` di _pipeline_ aplikasi diganti _commit_ ke repositori konfigurasi. Test, _build image_, dan _push_ tetap sama
    - Secret tidak disimpan sebagai teks biasa di Git. Pilihannya: Sealed Secrets, SOPS, atau External Secrets Operator yang membaca dari _secret manager_
  ],
)[
```yaml
# repo konfigurasi: transfer/overlays/prod/kustomization.yaml
resources:
  - ../../base
patches:
  - path: config.yaml
images:
  - name: studi-kasus/transfer
    newName: registry.example/bank/transfer
    newTag: 3f2a9c1e7b
```
```sh
# step pengganti `make deploy` di pipeline transfer
git clone "$CONFIG_REPO" config && cd config/transfer/overlays/dev
kustomize edit set image \
  studi-kasus/transfer=$REGISTRY/$IMAGE_OWNER/transfer:$VERSION
git commit -am "transfer $VERSION" && git push
```
#source(ilustrasi: true)
]

#code-slide(kicker: "GitOps", title: [_Agent_ GitOps dan pemetaannya ke OpenShift],
  side: [
    - Dua _agent_ yang umum: Argo CD dan Flux, keduanya proyek CNCF berstatus _graduated_
    - OpenShift menyediakan Red Hat OpenShift GitOps, _operator_ berbasis Argo CD dengan dukungan Red Hat
    - `selfHeal` mengembalikan perubahan manual di _cluster_. `prune` menghapus objek yang sudah dihapus dari repositori
    - Argo CD memeriksa repositori secara berkala (sekitar 3 menit) atau langsung saat menerima _webhook_ dari git server
    - Status `Synced`/`OutOfSync` dan `Healthy`/`Degraded` per aplikasi terlihat di UI dan CLI
  ],
)[
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: transfer-prod
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://git.example/bank/deploy-config.git
    targetRevision: main
    path: transfer/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: transfer-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```
#source(ilustrasi: true)
]

#slide(kicker: "GitOps", title: [Model _push_ dan GitOps per aspek])[
  #table(
    columns: (0.8fr, 1.3fr, 1.3fr),
    [Aspek], [Model _push_ (Lab 10, Jenkins)], [GitOps],
    [_Credential_ _cluster_], [Di runner atau Jenkins], [Hanya di _agent_ di dalam _cluster_],
    [Jalur perubahan], [_Pipeline_, ditambah `kubectl` manual], [Hanya _commit_ ke repositori konfigurasi],
    [_Drift_], [Tidak terdeteksi], [Dilaporkan `OutOfSync`, dikembalikan bila `selfHeal` aktif],
    [_Rollback_], [`kubectl rollout undo` atau menjalankan ulang _pipeline_ versi lama], [`git revert` di repositori konfigurasi],
    [Jejak audit], [_Log job_ CI], [Riwayat _commit_ dan persetujuan PR],
    [Peran Jenkins], [_Test_, _build_, _push_, _deploy_], [_Test_, _build_, _push_, _commit_ _tag image_],
    [Hasil _deploy_], [`rollout status` di _log pipeline_], [Status aplikasi di _agent_. _Pipeline_ selesai sebelum _rollout_ selesai],
  )
  #v(6pt)
  #note[Biaya GitOps: satu repositori tambahan per sistem, penanganan Secret di luar Git, dan urutan _deploy_ antarobjek (misalnya migrasi database sebelum Deployment) yang harus diatur di _agent_. Lab tidak memasang _tools_ GitOps. Konsepnya cukup dipahami agar organisasi dapat menilainya ketika sudah siap.]
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

#slide(kicker: "Peta concern microservices", title: [Peta _concern_ lengkap di studi kasus dan di _production_])[
  #concern-map(cols: ("concern",), size: 9.5pt, inset: (x: 6pt, y: 3.5pt), extra: (
    (header: [Yang diterapkan di studi kasus], width: 1.45fr, cells: (
      [Account, transfer, notification, masing-masing dengan database sendiri],
      [REST untuk _channel_, gRPC transfer ke account, Kafka `transfer-events`],
      [_Timeout_, _retry_, _circuit breaker_ (failsafe-go), _probe_, _rolling update_],
      [Saga dengan kompensasi, _outbox_, _idempotent consumer_],
      [OAuth2 _client credentials_ dari Hydra, JWT di _middleware_ dan _interceptor_],
      [`slog` + _correlation ID_, Prometheus, OTel, `otel-lgtm`],
      [_Environment variable_ tanpa _default_, ConfigMap dan Secret dari _overlay_],
      [Service DNS `account:9091`, Ingress Traefik],
      [Dockerfile _multi-stage_ `scratch`, Deployment, _probe_, _rolling update_ di k3d],
      [_Pipeline_ per service: _test_, _image_, _push_, _deploy_ (model _push_)],
    )),
    (header: [Yang ditambahkan di _production_], width: 1.45fr, cells: (
      [Kepemilikan service per tim, katalog service dan kontrak API],
      [API _gateway_, versi kontrak yang terkelola, Kafka multi-_broker_],
      [_Rate limiting_ di _gateway_, uji _fault_ berkala, _service mesh_ bila kebijakan ingin diseragamkan di platform],
      [Rekonsiliasi berkala, _monitoring_ saga yang tertahan, _dead letter topic_],
      [IdP organisasi, mTLS antar-service, rotasi kunci, API _gateway_],
      [_Stack_ terpisah dengan retensi sesuai klasifikasi data, _alerting_, kontrol akses],
      [_Secret manager_ + External Secrets Operator, enkripsi Secret di etcd],
      [_Load balancing_ gRPC per _request_ (_client-side_ atau _service mesh_), Route OpenShift],
      [Pemindaian dan penandatanganan _image_, PodDisruptionBudget, HPA],
      [Promosi antar-_environment_ dengan persetujuan, GitOps],
    )),
  ))
  #v(6pt)
  #text(size: 11pt, fill: slate)[Platform Spring Cloud menyediakan _discovery_ (Eureka), _load balancing_, _circuit breaker_, dan konfigurasi (Spring Cloud Config) sebagai _library_ ekosistem Java. Platform Kubernetes menyediakan _discovery_, _load balancing_, konfigurasi, _restart_, dan _rollout_ untuk service dalam bahasa apa pun. Service _standalone_ di VM tidak memiliki keduanya, sehingga tim menyediakan sendiri setiap _concern_ tersebut. Kebijakan _resiliency_, konsistensi data, pemeriksaan _security_, dan instrumentasi tetap di kode.]
]

#slide(kicker: "Keputusan desain", title: "Ringkasan keputusan desain empat hari")[
  #{
    show table.cell: set text(size: 11pt)
    table(
      columns: (auto, auto, 1.1fr, 1.5fr),
      inset: (x: 6pt, y: 4.5pt),
      [Hari], [Keputusan], [Pilihan], [Konsekuensi yang diterima],
      [H1], [Bahasa service], [Go], [Tidak ada _framework_ setara Spring Boot. Konfigurasi, _middleware_, dan telemetri dirangkai sendiri],
      [H1], [_Routing_ HTTP], [`ServeMux` standar (Go 1.22+)], [Tanpa pengelompokan _route_ serta _binding_ dan validasi otomatis],
      [H1], [Akses database], [pgx tanpa ORM], [_Query_ ditulis manual dan terikat ke PostgreSQL],
      [H1], [Kepemilikan data], [Database per service], [Tidak ada _join_ dan transaksi lintas service, sehingga dibutuhkan saga],
      [H2], [_Resiliency_], [failsafe-go], [Dependensi tambahan dengan API _generic_. _Policy_ ada di kode setiap service, perubahan parameter butuh _build_ dan rilis ulang],
      [H2], [Panggilan internal], [gRPC + protobuf], [Tidak bisa dicoba langsung dengan curl, _load balancing_ per koneksi, kontrak harus kompatibel],
      [H2], [API _channel_], [REST], [Dua gaya API dipelihara berdampingan],
      [H3], [Notifikasi], [_Asynchronous messaging_], [_Eventual consistency_, duplikat dan urutan harus ditangani],
      [H3], [_Broker_], [Kafka], [Jumlah _consumer_ aktif per _group_ dibatasi jumlah _partition_, _routing_ lebih terbatas dibanding RabbitMQ],
      [H3], [Otorisasi antar-service], [OAuth2 _client credentials_, Hydra], [Token bergantung pada Hydra. Ganti IdP: ubah `OAUTH_*` URL dan sesuaikan _claim_ _scope_],
      [H3], [_Observability_ lab], [`otel-lgtm`], [Tidak untuk _production_. Komponen dipisah saat naik ke _production_],
      [H4], [Artefak rilis], [_Container image_ `scratch`, _non-root_], [Membutuhkan _registry_ dan pemindaian, tanpa _shell_ untuk _debugging_],
      [H4], [Platform], [Kubernetes], [Kompleksitas operasional _cluster_],
      [H4], [_Cluster_ training], [k3d], [k3s berbeda dengan OpenShift (SCC, Route)],
    )
  }
]

#slide(kicker: "Kartu referensi", title: "Pola Hari 4 beserta syarat penggunaannya")[
  #table(
    columns: (auto, 1fr, 1fr),
    [Pola], [Masalah yang diselesaikan], [Layak digunakan ketika],
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
