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
    [09:00 – 10:15], [*Lab 8*: melacak satu transfer lintas tiga service di Grafana], [_Hands-on_],
    [10:30 – 12:00], [_Containerization_, konfigurasi, Kubernetes, dan *Lab 9* (1): seluruh sistem berjalan di k3d], [Demo + _hands-on_],
    [12:00 – 13:00], [Istirahat makan siang], [—],
    [13:00 – 13:30], [*Lab 9* (2): _rolling update_, perubahan konfigurasi, _probe_], [_Hands-on_],
    [13:30 – 14:15], [CI/CD per service dan pemetaannya ke Jenkins dan GitHub Actions; GitOps sekilas], [Presentasi + demo],
    [14:15 – 15:45], [*Lab 10*: dari _commit_ hingga _rolling update_], [_Hands-on_],
    [16:00 – 17:00], [Operasional: HPA, penempatan _observability stack_, OpenShift. Peta _concern_ lengkap, ringkasan keputusan desain, diskusi dan tanya jawab], [Presentasi + diskusi],
  )
]

#slide(kicker: "Peta concern microservices", title: [_Concern_ yang dibahas di Hari 4])[
  #concern-map(highlight: (6, 7, 8, 9, 10))
  #v(8pt)
  #note[Hari 1–3 banyak membahas sisi kode. Hari 4 membahas _concern_ yang sebagian besar ditangani platform: Kubernetes dan _pipeline_. _Observability_ hanya muncul di Lab 8, yang mempraktikkan konsep dan kode dari akhir Hari 3.]
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
#section-slide(number: "02", title: "Lab 8: Observability lintas service", subtitle: [Melacak satu transfer lintas tiga service di Grafana])

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
      - OpenShift dengan SCC `restricted-v2` menjalankan _container_ dengan UID acak dari rentang milik _namespace_
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
#section-slide(number: "04", title: "Deployment ke Kubernetes", subtitle: [Deployment, Service, ConfigMap/Secret, konfigurasi terpusat, _probe_, dan _rolling update_ di k3d])

#decision(title: [Kubernetes sebagai platform _deployment_],
  [
    - Banyak service, masing-masing dengan beberapa _replica_
    - Penjadwalan ke _node_, _restart_ otomatis, _rolling update_
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
    - k3d dengan versi k3s yang di-_pin_ (`rancher/k3s:v1.36.5-k3s1`), dibuat dengan `make k3d-up` dan dihapus dengan `make k3d-down`
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

#code-slide(kicker: "Security context", title: [_Security context_ yang lolos SCC `restricted-v2`],
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

#lab-slide("9", [Menjalankan seluruh sistem di k3d],
  [
    - Mengemas tiga service menjadi _image_ minimal dan _non-root_
    - Menerapkan manifest yang disediakan ke _cluster_ k3d
    - Melakukan _scaling_, perubahan konfigurasi, dan _rolling update_
  ],
  [
    - `make images VERSION=1.0.0`, `make k3d-up`, `make k3d-import VERSION=1.0.0`, `make k8s-apply`
    - Transfer lewat Ingress `localhost:28080`, cek hasilnya di Grafana
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
    at(0pt, 190pt, node("k3d laptop", sub: "imagePullSecret", width: 130pt)),
    edge((130pt, 58pt), (215pt, 58pt), label: "push"),
    edge((345pt, 58pt), (450pt, 58pt), label: "trigger"),
    edge((580pt, 58pt), (690pt, 58pt), label: "deploy"),
    edge((480pt, 86pt), (365pt, 200pt), label: "push image", label-dx: 40pt),
    edge((215pt, 218pt), (130pt, 218pt), label: "pull", dash: "dashed"),
    edge((365pt, 230pt), (740pt, 86pt), label: "pull", dash: "dashed", label-dx: 50pt, label-dy: 10pt),
  )
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
