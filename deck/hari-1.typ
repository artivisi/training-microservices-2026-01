// Day 1 deck: architecture, Go essentials, service foundation (Labs 1-2).
// Build: make CLIENT="..." Deck-Hari-1-Microservices-2026-10.pdf
#import "../_template/deck.typ": *

#show: deck.with(
  title: "Arsitektur Microservices dan Fondasi Service Go",
  subtitle: [Hari 1: monolith dan microservices, penentuan _service boundary_, Go _essentials_, serta account service dan transfer service],
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
  #set table(inset: 5pt)
  #table(
    columns: (auto, 1fr, auto),
    [Waktu], [Topik], [Format],
    [08:00–08:45], [Peta _concern_ microservices dan penyedianya (tim, ekosistem, atau platform); ringkasan monolith dan microservices], [Presentasi],
    [08:45–09:30], [_Service decomposition_: kapabilitas bisnis, _bounded context_, dekomposisi studi kasus perbankan], [Presentasi dan diskusi],
    [09:30–10:00], [Ekosistem Go dibandingkan Java, Node.js, dan PHP; alasan memilih Go], [Presentasi],
    [10:15–11:30], [Go _essentials_ untuk service: _module_, _struct_, _interface_, _error handling_, _goroutine_ dan _channel_, `net/http`], [Presentasi dan demo],
    [11:30–12:00], [Anatomi service Go (1): struktur _project_, _routing_ dan perbandingan _router_, validasi, _12-factor_, konfigurasi], [Demo],
    [12:00–13:00], [Istirahat makan siang], [—],
    [13:00–13:30], [Anatomi service Go (2): _liveness_ dan _readiness_, _graceful shutdown_, pemetaan _error_], [Demo],
    [13:30–15:00], [*Lab 1*: account service dengan REST, PostgreSQL, dan _health check_], [_Hands-on_],
    [15:15–16:30], [*Lab 2*: transfer service sebagai service kedua, komunikasi REST pertama], [_Hands-on_],
    [16:30–17:00], [Ringkasan Hari 1 pada peta _concern_, tanya jawab], [Diskusi],
  )
]

#slide(kicker: "Peta training", title: "Materi dan lab selama empat hari")[
  #table(
    columns: (auto, 1fr, 1.3fr),
    [Hari], [Tema], [Lab],
    [1], [Arsitektur, Go _essentials_, fondasi service], [Lab 1 account service; Lab 2 transfer service dengan REST],
    [2], [_Resiliency_, gRPC, dan desain saga], [Lab 3 _timeout_, _retry_, _circuit breaker_; Lab 4 transfer ke account melalui gRPC],
    [3], [_Messaging_, konsistensi data, _security_, konsep _observability_], [Lab 5 saga, _outbox_, Kafka; Lab 6 _idempotent consumer_; Lab 7 JWT],
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
    [7], [Token OAuth2 dari _authorization server_, validasi JWT di REST dan gRPC],
    [8], [_Structured log_, _correlation ID_, metrik Prometheus, _trace_ OpenTelemetry, Grafana],
    [9], [Dockerfile _multi-stage_ dan _manifest_ Kubernetes, berjalan di k3d],
    [10], [_Pipeline_ CI/CD per service: _test_, _build image_, _push_, _deploy_],
  )
  #v(6pt)
  #text(size: 12.5pt)[Setiap kondisi akhir lab tersedia sebagai _git tag_ (`lab-01` … `lab-10`). Peserta yang tertinggal melanjutkan dari _tag_ lab sebelumnya dengan `git checkout lab-NN`.]
]

#slide(kicker: "Peta training", title: [Peta _concern_ microservices])[
  #concern-map(size: 11pt, inset: (x: 5pt, y: 4.5pt))
  #v(2pt)
  #text(size: 11pt, fill: slate)[H1–H4 = Hari 1–4. Setiap hari dibuka dengan peta ini: baris yang disorot adalah _concern_ yang dibahas hari itu.]
]

#let owner-points(..items) = grid(columns: (1fr,) * items.pos().len(), column-gutter: 18pt,
  ..items.pos().map(i => block(stroke: (left: 2pt + gold), inset: (left: 8pt, y: 2pt),
    text(size: 12.5pt, i))))

#slide(kicker: "Penyedia concern", title: [Tanpa platform: service _standalone_ di VM])[
  #grid(columns: (1fr, 1fr), column-gutter: 24pt,
    owner-host("VM 1", sub: "service Laravel", size: 13pt,
      ([Nginx: _load balancing_], "tim"),
      ("Kode bisnis (PHP)", "kode"),
      ([Ganesha: _circuit breaker_], "ekosistem"),
      ([`.env`: konfigurasi dan alamat service lain], "tim"),
      ([supervisor: _restart_], "tim")),
    owner-host("VM 2", sub: "service Express.js", size: 13pt,
      ([Nginx: _load balancing_], "tim"),
      ("Kode bisnis (Node.js)", "kode"),
      ([opossum: _circuit breaker_], "ekosistem"),
      ([`.env`: konfigurasi dan alamat service lain], "tim"),
      ([PM2: _restart_], "tim")),
  )
  #owner-band([Skrip _deploy_ dan prosedur operasional untuk setiap server], "tim", size: 13pt)
  #v(10pt)
  #owner-points(
    [Setiap _concern_ di luar kode bisnis disusun sendiri oleh tim, untuk setiap server],
    [Alamat service lain ditulis tetap di `.env`. Menambah atau memindahkan server berarti mengubah konfigurasi di banyak tempat],
    [Cara _restart_ dan _rollout_ berbeda per bahasa: PM2 untuk Node.js, supervisor untuk PHP],
  )
  #v(8pt)
  #owner-legend("tim", "ekosistem", "kode")
]

#slide(kicker: "Penyedia concern", title: [Dukungan ekosistem: platform Spring Cloud])[
  #grid(columns: (1fr, 1fr, 1fr), column-gutter: 18pt,
    owner-host("Service A", sub: "Java", size: 13pt,
      ("Kode bisnis", "kode"),
      ([Eureka _client_: _discovery_], "ekosistem"),
      ([Spring Cloud LoadBalancer], "ekosistem"),
      ([Config _client_], "ekosistem"),
      ([Resilience4j: _circuit breaker_], "ekosistem")),
    owner-host("Service B", sub: "Java", size: 13pt,
      ("Kode bisnis", "kode"),
      ([Eureka _client_: _discovery_], "ekosistem"),
      ([Spring Cloud LoadBalancer], "ekosistem"),
      ([Config _client_], "ekosistem"),
      ([Resilience4j: _circuit breaker_], "ekosistem")),
    owner-host("Server pendukung", sub: "Spring Cloud", size: 13pt,
      ([Eureka Server: _registry_ alamat service], "ekosistem"),
      ([Config Server: konfigurasi terpusat], "ekosistem")),
  )
  #owner-band([VM: _restart_ dan _rollout_ tetap lewat skrip dan prosedur operasional], "tim", size: 13pt)
  #v(10pt)
  #owner-points(
    [Spring Cloud menyediakan _discovery_, _load balancing_, konfigurasi, dan _circuit breaker_ sebagai _library_ beserta server pendukungnya],
    [Dukungan ini hanya bisa digunakan oleh service JVM. Service dalam bahasa lain harus menulis sendiri _client_ untuk Eureka dan Config Server],
    [_Restart_ dan _rollout_ tidak termasuk, sehingga tetap menjadi pekerjaan tim],
  )
  #v(8pt)
  #owner-legend("tim", "ekosistem", "kode")
]

#slide(kicker: "Penyedia concern", title: [Dukungan platform: Kubernetes])[
  #grid(columns: (1fr, 1fr, 1fr), column-gutter: 18pt,
    owner-host("transfer", sub: "Go", size: 13pt,
      ("Kode bisnis", "kode"),
      ([failsafe-go, OTel SDK, JWT], "ekosistem")),
    owner-host("account", sub: "Go", size: 13pt,
      ("Kode bisnis", "kode"),
      ([OTel SDK, JWT], "ekosistem")),
    owner-host("Service lain", sub: "Java, Node.js, PHP", size: 13pt,
      ("Kode bisnis", "kode"),
      ([_Library_ bahasa masing-masing], "ekosistem")),
  )
  #owner-band("Kubernetes", "platform", size: 13pt,
    [DNS: _discovery_],
    [Service: _load balancing_],
    [ConfigMap dan Secret],
    [_Probe_ dan _restart_],
    [_Rolling update_])
  #v(10pt)
  #owner-points(
    [Platform menyediakan _discovery_, _load balancing_, konfigurasi, _restart_, dan _rollout_ untuk service dalam bahasa apa pun],
    [Kode service hanya memuat kebijakan yang memerlukan pengetahuan bisnis: _resiliency_ per panggilan, konsistensi data, pemeriksaan _token_, dan instrumentasi],
    [Studi kasus menggunakan model ini. Lab 9 dan Lab 10 menjalankannya di k3d dan di server pelatihan],
  )
  #v(8pt)
  #owner-legend("platform", "ekosistem", "kode")
]

#slide(kicker: "Penyedia concern", title: [Service makin tipis ketika platform menangani lebih banyak _concern_])[
  #let col(head, svc, outside) = stack(spacing: 6pt,
    align(center, text(size: 13pt, weight: "bold", fill: navy, head)),
    svc,
    ..outside)
  #grid(columns: (1fr, 1fr, 1fr), column-gutter: 20pt,
    col([_Standalone_ di VM],
      owner-host("Satu service", size: 11pt,
        ("Kode bisnis", "kode"),
        ([_Library_ _circuit breaker_], "ekosistem")),
      (owner-band([Disusun tim untuk setiap server], "tim", size: 11pt, cols: 2,
        [Nginx], [`.env`], [PM2 atau supervisor], [Skrip _deploy_]),)),
    col([Platform Spring Cloud],
      owner-host("Satu service", size: 11pt,
        ("Kode bisnis", "kode"),
        ([Eureka _client_], "ekosistem"),
        ([LoadBalancer], "ekosistem"),
        ([Config _client_], "ekosistem"),
        ([Resilience4j], "ekosistem")),
      (owner-band([Server ekosistem], "ekosistem", size: 11pt, cols: 2, [Eureka Server], [Config Server]),
       owner-band([Disusun tim], "tim", size: 11pt, [_Restart_ dan _rollout_]))),
    col([Platform Kubernetes],
      owner-host("Satu service", size: 11pt,
        ("Kode bisnis", "kode"),
        ([_Resiliency_, _token_, instrumentasi], "ekosistem")),
      (owner-band("Disediakan platform", "platform", size: 11pt, cols: 2,
        [_Discovery_], [_Load balancing_], [Konfigurasi], [_Restart_], [_Rollout_]),)),
  )
  #v(6pt)
  #text(size: 12.5pt)[Pada platform Kubernetes, _concern_ yang sama untuk semua service ditangani platform. Kode service hanya memuat hal yang memerlukan pengetahuan bisnis, termasuk _resiliency_ per panggilan.]
  #v(2pt)
  #owner-legend("tim", "ekosistem", "platform", "kode")
]

#slide(kicker: "Penyedia concern", title: [Ringkasan _concern_ yang ditangani tim, ekosistem, atau platform])[
  #{
    show table.cell: set text(size: 11pt)
    table(
      columns: (auto, 1fr, 1fr, 1fr),
      inset: (x: 5pt, y: 4pt),
      [_Concern_], [_Standalone_ di VM (misalnya beberapa service Laravel atau Express.js)], [Platform Spring Cloud], [Platform Kubernetes],
      [_Service discovery_], [Alamat tetap di `.env` atau DNS internal], [Eureka: _registry server_ dan _client_ di setiap service], [Kubernetes Service dan DNS],
      [_Load balancing_], [Nginx atau HAProxy di depan setiap service], [Spring Cloud LoadBalancer di sisi pemanggil], [Kubernetes Service (kube-proxy)],
      [_Configuration_], [`.env` per server, disalin oleh skrip _deploy_], [Spring Cloud Config Server dan _client_-nya], [ConfigMap dan Secret],
      [_Restart_ dan _rollout_], [PM2 atau supervisor, skrip _deploy_ per server], [Di luar _framework_: skrip dan prosedur operasional], [Deployment: _probe_, _restart_ otomatis, _rolling update_],
      [_Circuit breaker_], [_Library_ per bahasa: opossum (Node.js), Ganesha (PHP)], [Resilience4j], [Tetap di kode: failsafe-go (Go), Resilience4j (Java)],
      [Konsistensi, pemeriksaan token, instrumentasi], [_Library_ di setiap service], [_Library_ di setiap service], [Tetap di kode],
      [*Disediakan oleh*], [Tim sendiri, untuk setiap service], [Ekosistem Java, hanya untuk service JVM], [Platform, untuk service dalam bahasa apa pun],
    )
  }
  #v(6pt)
  #note[Platform Spring Cloud adalah dukungan ekosistem satu _tech stack_. Platform Kubernetes adalah dukungan platform yang bisa digunakan untuk semua bahasa. Studi kasus menggunakan platform Kubernetes, sehingga kode Go hanya memuat kebijakan _resiliency_, konsistensi data, pemeriksaan token, dan instrumentasi.]
]

#slide(kicker: "Peta concern microservices", title: [_Concern_ yang dibahas di Hari 1])[
  #let day1 = (
    [Lab 1–2: _service boundary_ dari kapabilitas bisnis, satu database per service],
    [Lab 2: panggilan REST pertama dari transfer ke account],
    [Lab 2: celah _client_ tanpa _timeout_ dicatat, ditangani Hari 2],
    [Lab 2: celah credit gagal setelah debit dicatat, ditangani Hari 2–3],
    [Hari 3],
    [Hari 3–4],
    [Lab 1: konfigurasi wajib dari _environment variable_ (faktor III)],
    [Hari 4],
    [Konsep _liveness_, _readiness_, dan _graceful shutdown_; YAML di Hari 4],
    [Target `Makefile` per service sudah disiapkan; _pipeline_ di Hari 4],
  )
  #concern-map(highlight: (1, 2, 7, 9), cols: ("concern",), size: 12pt, inset: (x: 6pt, y: 6pt),
    extra: ((header: [Cakupan di Hari 1], cells: day1, width: 1.8fr),))
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
      - Pemanggilan antarmodul tanpa latensi jaringan
    ],
  )
  #v(10pt)
  #note[Untuk banyak sistem, monolith modular dengan batas modul yang rapi tetap menjadi pilihan yang wajar.]
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
    [Kegagalan], [Bila proses mati, seluruh aplikasi ikut berhenti], [Kegagalan parsial, perlu _timeout_ dan _circuit breaker_ (Hari 2)],
    [_Debugging_], [_Stack trace_ dalam satu proses], [_Distributed tracing_ lintas service (Hari 3–4)],
    [Beban operasional], [Satu aplikasi, satu database], [Banyak _deployable unit_, _pipeline_, dan database],
  )
]

#slide(kicker: "Konsep", title: "Kondisi yang membuat microservices merugikan")[
  #bullets(
    [*Tim kecil.* Bila semua service dikelola satu tim, pemecahan service tidak mengurangi koordinasi antartim, sedangkan beban operasionalnya tetap bertambah.],
    [*_Domain boundary_ belum jelas.* _Service boundary_ yang salah jauh lebih sulit diperbaiki dibandingkan _module boundary_ di dalam satu aplikasi.],
    [*Belum ada otomasi.* Tanpa _pipeline_ dan _observability_, setiap service tambahan menambah pekerjaan manual.],
    [*Beban merata.* Bila semua fitur menerima beban yang serupa, pemecahan service tidak meningkatkan skalabilitas.],
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
        [Bila satu service mati, seluruh alur bisnis ikut berhenti],
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

#section-slide(number: "02", title: "Service Decomposition", subtitle: [_Service boundary_ menurut kapabilitas bisnis dan _bounded context_])

#slide(kicker: "Konsep", title: [Kapabilitas bisnis dan _bounded context_])[
  #two-col(
    card("Kapabilitas bisnis")[
      Hal yang dikerjakan organisasi, terlepas dari cara aplikasi mengerjakannya: mengelola rekening, memindahkan dana, memberi tahu nasabah.

      Kapabilitas bisnis jarang berubah, sehingga menjadi acuan _service boundary_ yang stabil.
    ],
    card([_Bounded context_], accent: gold.darken(15%))[
      Batas berlakunya model domain. Di dalam batas tersebut, setiap istilah hanya memiliki satu arti.

      Contoh: bagi account service, transfer hanyalah dua mutasi saldo. Bagi transfer service, transfer memiliki status, alasan gagal, dan riwayat.
    ],
  )
]

#slide(kicker: "Konsep", title: [Tiga acuan penentuan _service boundary_])[
  #enum(
    spacing: 14pt,
    [*Service memiliki datanya sendiri.* Service lain hanya boleh mengakses data tersebut melalui API, tanpa _query_ langsung ke tabelnya.],
    [*Service dapat dirilis tanpa koordinasi lintas tim.* Rilis account service tidak menunggu jadwal rilis transfer service.],
    [*Perubahan satu kebutuhan bisnis idealnya cukup di satu service.* Bila setiap fitur baru menyentuh tiga service, _service boundary_ tersebut perlu ditinjau ulang.],
  )
  #v(10pt)
  #note[Ketiga acuan ini sekaligus menjadi kriteria uji: _service boundary_ yang melanggar salah satunya akan mengarah ke _distributed monolith_.]
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
    [notification], [Memberi tahu hasil transfer (Hari 3)], [Tabel `notification`], [Tidak dipanggil langsung, tetapi membaca _event_ dari Kafka],
  )
  #v(10pt)
  #note[Transfer dipisahkan dari account karena aturan transfer (status, kompensasi, _idempotency_) dan aturan pengelolaan rekening berubah dengan alasan dan jadwal yang berbeda. Walaupun transfer menjadi service sendiri, saldo rekening hanya boleh diubah oleh account service.]
]

#decision(title: [_Database per service_],
  [Setiap service dapat mengubah skema dan dirilis tanpa koordinasi dengan pemilik service lain (acuan pertama dan kedua penentuan _service boundary_).],
  [
    - Satu database bersama untuk semua service
    - Satu server database, dengan _schema_ dan kredensial terpisah per service
    - Satu server database per service
  ],
  [Setiap service memiliki _container_ PostgreSQL sendiri. Service lain hanya mengakses datanya melalui API atau _event_.

  Server bersama dengan database dan kredensial terpisah per service juga memenuhi prinsip ini, asalkan service tidak dapat membaca data milik service lain.],
  [
    - _Join_ lintas service tidak tersedia, sehingga data milik service lain diambil melalui API
    - Debit dan credit tidak dapat dibungkus satu transaksi database (saga, Hari 2–3)
    - Jumlah database yang harus di-_backup_ dan dipantau bertambah
  ],
)

#slide(kicker: "Studi kasus", title: [_Database per service_ di studi kasus])[
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
        [Transfer service tidak memiliki koneksi ke `db-account`, sehingga data rekening hanya dapat diperoleh melalui API account.],
        [Port PostgreSQL dimulai dari 15432 agar tidak bentrok dengan PostgreSQL lokal di port 5432.],
      )
    ],
  )
]

#code-slide(kicker: "Konsekuensi", title: "Debit dan credit tidak dapat dibungkus satu transaksi database",
  side: [
    Di monolith, debit dan credit cukup dibungkus satu transaksi: bila salah satu gagal, keduanya dibatalkan.

    Di microservices, debit dan credit menjadi dua panggilan jaringan ke account service. Bila credit gagal setelah debit berhasil, tidak ada _rollback_ otomatis.

    - Hari 1: transfer dicatat `FAILED` dan masuk _log_
    - Hari 2: desain saga dengan kompensasi dan _idempotency key_
    - Hari 3: implementasi saga di Lab 5
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

// ── 03 Ekosistem Go ────────────────────────────────────────────────────────

#section-slide(number: "03", title: "Ekosistem Go dibandingkan Java, Node.js, dan PHP", subtitle: [Ketersediaan _library_ per _concern_, karakter _runtime_, dan alasan memilih Go])

#slide(kicker: "Ekosistem", title: [_Library_ per _concern_ di empat ekosistem])[
  #set table(inset: (x: 5pt, y: 6pt))
  #show table.cell: set text(size: 12pt)
  #table(
    columns: (auto, 1fr, 1fr, 1fr, 1fr),
    [_Concern_], [Go], [Java], [Node.js], [PHP],
    [HTTP dan REST], [`net/http` (stdlib), chi, gin], [Spring Boot (Spring MVC, WebFlux)], [Express, Fastify, NestJS], [Laravel, Symfony],
    [gRPC], [grpc-go], [grpc-java], [`@grpc/grpc-js`], [_Client_: ekstensi `grpc`; _server_: RoadRunner],
    [Kafka], [kafka-go, franz-go, confluent-kafka-go], [Kafka _client_ dari Apache, Spring Kafka], [`@confluentinc/kafka-javascript`], [php-rdkafka (ekstensi)],
    [_Resiliency_], [failsafe-go, sony/gobreaker], [Resilience4j], [opossum], [Ganesha (_circuit breaker_)],
    [OAuth2 dan JWT], [golang-jwt, `x/oauth2`], [Spring Security (OAuth2 _resource server_)], [jose, openid-client], [firebase/php-jwt, lcobucci/jwt],
    [OpenTelemetry], [OTel Go SDK], [OTel Java agent, Micrometer], [OTel JS SDK], [OTel PHP],
    [Akses database], [pgx, `database/sql`], [JDBC, Spring Data JPA (Hibernate)], [node-postgres (`pg`), Prisma, TypeORM], [PDO, Doctrine, Eloquent],
  )
  #v(6pt)
  #note[Keempat ekosistem memiliki _library_ untuk setiap _concern_. Perbedaannya ada pada bentuk paket: Java menyediakan integrasi siap pakai melalui Spring, sedangkan Go merangkai _library_ kecil per _concern_. Tabel ini hanya memuat _library_ yang masih aktif dipelihara (diperiksa Oktober 2026).]
]

#slide(kicker: "Ekosistem", title: [Karakter _runtime_ yang berpengaruh pada microservices])[
  #set table(inset: (x: 5pt, y: 7pt))
  #show table.cell: set text(size: 12.5pt)
  #table(
    columns: (auto, 1fr, 1fr, 1fr, 1fr),
    [Aspek], [Go], [Java], [Node.js], [PHP],
    [Artefak _deployment_], [Satu _binary_ statis; _image_ dapat berbasis `scratch`], [JVM dan file `jar`], [_Runtime_ Node dan direktori `node_modules`], [PHP-FPM dan _web server_, atau _worker_ persisten (RoadRunner, Swoole)],
    [Model konkurensi], [_Goroutine_ yang dijadwalkan _runtime_ Go], [_Thread_ JVM; _virtual thread_ sejak Java 21], [Satu _event loop_; komputasi berat menahan seluruh _request_], [Setiap _worker_ FPM melayani satu _request_ pada satu waktu; _state_ tidak bertahan antar-_request_],
    [_Startup_ dan memori], [_Startup_ cepat, memori kecil], [_Startup_ lebih lama karena JVM dan inisialisasi _framework_; dapat dipersingkat dengan GraalVM _native image_], [_Startup_ cepat], [_Bootstrap framework_ di setiap _request_, kecuali dengan _worker_ persisten],
  )
  #v(8pt)
  #note[Angka dari studi kasus: _image_ account service sekitar 8 MB terkompresi dan _startup_ di bawah 1 detik (diukur di Lab 9). Dalam praktik, pilihan bahasa paling sering ditentukan oleh bahasa yang sudah dikuasai tim dan sanggup dirawat tim selama bertahun-tahun.]
]

#decision(title: "Go untuk service di studi kasus",
  [Banyak service kecil yang berjalan di _container_ dan Kubernetes: _image_ kecil, _startup_ cepat, berjalan sebagai _non-root_, dan mudah dibaca peserta dari berbagai latar belakang bahasa.],
  [Java dengan Spring Boot dan Spring Cloud, Node.js, PHP, dan Go.],
  [Go dengan _standard library_ dan _library_ kecil per _concern_ (lihat tabel _library_). Service pendukung (_registry_, SSO, _log server_, _monitoring_) dan analisis _build_, _reuse_, _buy_ dibahas di Hari 4.],
  [
    - _Binary_ statis, _image_ `scratch`, dan konkurensi dengan _goroutine_
    - Go tidak memiliki _framework_ tunggal setara Spring Boot, sehingga konfigurasi, _middleware_, dan telemetri dirangkai sendiri dengan kode yang ringkas
    - Tim yang terbiasa dengan Java atau PHP perlu waktu belajar
  ],
)

// ── 04 Go essentials ───────────────────────────────────────────────────────

#section-slide(number: "04", title: "Go Essentials untuk Service", subtitle: [Fitur bahasa Go yang cukup untuk menulis dan membaca kode service di lab])

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
    - _Interface_ didefinisikan di sisi kode yang menggunakannya, yaitu _handler_.
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
    - `errors.Is` memeriksa seluruh _error chain_ yang dibungkus, sehingga _handler_ transfer tetap mengenali `ErrInsufficientFunds`.
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
    - `select` berhenti menunggu begitu salah satu dari dua hal berikut terjadi: server berhenti karena _error_, atau sistem operasi mengirim sinyal berhenti.
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
    - `context` membawa _deadline_ dan sinyal pembatalan ke seluruh rantai pemanggilan.
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
    - _Middleware_ berupa fungsi yang menerima _handler_ dan mengembalikan _handler_ baru. Pola ini digunakan kembali untuk _fault injection_ (Hari 2), JWT (Hari 3), dan metrik (Lab 8).
    - Padanan di Spring adalah Servlet `Filter`, yang membungkus seluruh _request_. `HandlerInterceptor` Spring berbeda, karena baru berjalan setelah _controller_ dipilih. Padanan _middleware_ untuk gRPC disebut _interceptor_ (Hari 2).
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
#v(10pt)
#text(size: 11pt, fill: slate)[Konsep yang sama di ekosistem lain: _middleware_ Koa (`await next()`) dan Laravel (`$next($request)`) juga membungkus _handler_, sehingga kode setelah `next` dipanggil berjalan setelah _response_ siap. _Middleware_ Express berbentuk _chain_ `next()`, sehingga kode sesudah _response_ membutuhkan `res.on('finish')`. Istilah _interceptor_ berbeda arti: _hook_ di Spring, _wrapper_ di NestJS, dan padanan _middleware_ di gRPC.]
]

// ── 05 Anatomi service Go ──────────────────────────────────────────────────

#section-slide(number: "05", title: "Anatomi Service Go", subtitle: [Struktur _project_, _routing_, validasi, _12-factor_, konfigurasi, dan _health check_])

#code-slide(kicker: "Anatomi service", title: [Struktur _project_],
  side: [
    - Kode dikelompokkan per fitur (_package-by-feature_) di bawah `internal/`.
    - _Package_ di `internal/` tidak dapat di-_import_ oleh _module_ lain.
    - `main.go` hanya merangkai komponen, sedangkan logika bisnis berada di _package_ domain.
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
    - Sejak Go 1.23, `r.Pattern` berisi pola yang cocok, misalnya `GET /accounts/{number}`. Lab 8 menggunakannya sebagai label metrik, sehingga nomor rekening tidak masuk ke label.
    - Sejak Go 1.26, _redirect_ untuk garis miring di akhir _path_ menggunakan `307`, sehingga _method_ `POST` tetap `POST`.
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

#slide(kicker: "Perbandingan", title: [`ServeMux`, chi, gin, echo, dan Fiber])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (1fr, 0.95fr, 0.85fr, 1fr, 1.05fr, 1fr),
      inset: (x: 5pt, y: 4pt),
      [Aspek], [`http.ServeMux`], [chi], [gin], [echo], [Fiber],
      [_HTTP engine_], [`net/http`], [`net/http`], [`net/http`], [`net/http`], [fasthttp],
      [Bentuk _handler_], [`http.Handler`], [`http.Handler`], [`func(*gin.Context)`], [`func(*echo.Context) error`], [`func(fiber.Ctx) error`],
      [_Middleware_ `net/http`], [Langsung digunakan], [Langsung digunakan], [Lewat _wrapper_], [Lewat _wrapper_], [Lewat _adaptor_, dengan _overhead_],
      [Grup _route_ dengan _middleware_ per grup], [Tidak ada, dirangkai sendiri], [Ada], [Ada], [Ada], [Ada],
      [_Binding_ dan validasi], [Ditulis sendiri], [Ditulis sendiri], [Bawaan (go-playground/validator)], [_Binding_ bawaan, _validator_ dipasang sendiri], [_Binding_ bawaan, _validator_ dipasang sendiri],
      [HTTP/2], [Ya], [Ya], [Ya], [Ya], [Belum didukung fasthttp],
      [Dependensi langsung], [Tidak ada], [Tidak ada], [15], [3], [15],
      [Versi dan lisensi (Okt 2026)], [Bagian dari Go], [v5.5, MIT], [v1.12, MIT], [v5.4, MIT], [v3.6, MIT],
    )
  }
  #v(5pt)
  #grid(columns: (1fr, 1fr, 1fr), column-gutter: 12pt,
    card([Pindah antar-_router_], text(size: 11pt)[_Handler_ `ServeMux` dan chi sama-sama `http.Handler`, sehingga pindah ke chi tidak mengubah _handler_. Pindah ke gin, echo, atau Fiber berarti menulis ulang setiap _handler_.]),
    card([Catatan Fiber], accent: amber, text(size: 11pt)[Nilai dari `fiber.Ctx` digunakan ulang setelah _handler_ selesai, sehingga tidak boleh disimpan. README fasthttp sendiri menyarankan `net/http` untuk sebagian besar kasus.]),
    card([Gunakan _framework_ bila], accent: gold.darken(15%), text(size: 11pt)[API memiliki banyak grup _route_ dengan _middleware_ berbeda per grup, membutuhkan _binding_ dan validasi deklaratif, atau tim sudah terbiasa dengan _framework_ tersebut.]),
  )
]

#decision(title: [_Routing_ dengan `ServeMux` dari _standard library_],
  [_Routing_ REST berdasarkan _method_ dan _path_, dengan parameter di _path_ (`/accounts/{number}`), serta _middleware_ untuk _logging_, JWT, dan metrik.],
  [
    - `http.ServeMux`: pola _method_ dan _path_ sejak Go 1.22
    - chi: _router_ yang kompatibel dengan `http.Handler`
    - gin, echo, Fiber: _framework_ dengan _binding_ dan validasi (Fiber di atas fasthttp, bukan `net/http`)
  ],
  [`http.ServeMux` tanpa _router_ pihak ketiga. _Middleware_ ditulis sebagai fungsi yang menerima dan mengembalikan `http.Handler`.],
  [
    - Tidak ada dependensi tambahan. _Handler_ tetap berupa `http.Handler` biasa, sehingga dapat dipasang di chi bila kelak dibutuhkan
    - Tidak tersedia pengelompokan _route_ dengan _middleware_ per grup, maupun _binding_ dan validasi otomatis seperti di gin
    - Validasi ditulis sendiri (slide "Validasi input")
  ],
)

#code-slide(kicker: "Anatomi service", title: "Validasi input",
  side: [
    - Validasi dijalankan sebelum data disimpan ke database.
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

#slide(kicker: "Anatomi service", title: [_12-factor app_])[
  #set table(inset: (x: 6pt, y: 4.5pt))
  #show table.cell: set text(size: 12pt)
  #text(size: 12.5pt)[Dua belas prinsip untuk aplikasi yang dijalankan di _cloud_ (12factor.net). Prinsip ini menjadi acuan sepanjang training.]
  #v(2pt)
  #table(
    columns: (auto, auto, 1fr, auto),
    [Faktor], [Nama], [Penerapan di studi kasus], [Dibahas di],
    [I], [_Codebase_], [Satu _module_ dan satu _pipeline_ per service; tidak dibahas khusus], [—],
    [II], [_Dependencies_], [Dependensi dideklarasikan di `go.mod` dan `go.sum`], [Lab 1],
    [III], [_Config_], [Konfigurasi hanya dari _environment variable_], [Lab 1, 9],
    [IV], [_Backing services_], [Database, account service, Kafka, Hydra, dan _collector_ diakses melalui alamat dari konfigurasi], [Lab 1–2, 5, 7, 8],
    [V], [_Build, release, run_], [_Image_ dibangun sekali, lalu dirilis dengan konfigurasi per _environment_], [Lab 9–10],
    [VI], [_Processes_], [Service tidak menyimpan _state_ di memori; semua data ada di database], [Lab 1, 9],
    [VII], [_Port binding_], [Service membuka port HTTP dan gRPC sendiri (`HTTP_ADDR`, `GRPC_ADDR`)], [Lab 1, 4],
    [VIII], [_Concurrency_], [Kapasitas ditambah dengan memperbanyak replika], [Lab 9],
    [IX], [_Disposability_], [_Startup_ cepat dan _graceful shutdown_], [Lab 1, 9–10],
    [X], [_Dev/prod parity_], [_Image_ dan _manifest_ _base_ yang sama di k3d dan di _server_ pelatihan], [Lab 9–10],
    [XI], [_Logs_], [_Log_ ditulis ke `stdout` sebagai aliran _event_; format JSON sejak Lab 8], [Lab 1, 8],
    [XII], [_Admin processes_], [Skema database diterapkan saat _startup_ service, tanpa proses admin terpisah; tidak dibahas khusus], [—],
  )
  #v(4pt)
  #text(size: 10pt, fill: slate)[Referensi: Adam Wiggins, _The Twelve-Factor App_, Heroku, #link("https://12factor.net")[`12factor.net`] (sumbernya terbuka di #link("https://github.com/twelve-factor/twelve-factor")[`github.com/twelve-factor/twelve-factor`]). Kevin Hoffman, _Beyond the Twelve-Factor App_, O'Reilly, 2016, menambah tiga faktor: _API first_, _telemetry_, serta _authentication_ dan _authorization_.]
]

#code-slide(kicker: "Anatomi service", title: [Konfigurasi dari _environment variable_],
  side: [
    - Konfigurasi hanya dibaca dari _environment variable_ (faktor III, _Config_), sehingga _image_ yang sama berjalan di laptop, CI, dan Kubernetes.
    - Semua variabel wajib diisi dan tidak ada nilai _default_.
    - Bila ada variabel yang kosong, service berhenti saat _startup_ dengan _error_ yang menyebut nama variabel tersebut.
    - Di proyek sungguhan, _library_ seperti caarlos0/env membaca _environment variable_ langsung ke _struct_ (`env:"DATABASE_URL,required"`), termasuk konversi tipe. Viper dan koanf menambahkan _file_ konfigurasi (YAML/TOML) dan _flag_, dan umum digunakan di aplikasi CLI.
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

#slide(kicker: "Anatomi service", title: [_Liveness_ dan _readiness_ menjawab pertanyaan yang berbeda])[
  #two-col(
    card([_Liveness_: `GET /healthz`])[
      *Pertanyaan:* apakah proses ini macet dan perlu di-_restart_?

      *Yang bertindak:* kubelet di _node_ tempat _pod_ berjalan.

      *Tindakan bila gagal:* _container_ di-_restart_.

      *Yang diperiksa di studi kasus:* tidak ada dependensi. _Endpoint_ menjawab `200` selama server HTTP masih melayani _request_.
    ],
    card([_Readiness_: `GET /readyz`], accent: gold.darken(15%))[
      *Pertanyaan:* apakah _pod_ ini boleh menerima _traffic_ sekarang?

      *Yang bertindak:* kubelet melaporkan hasilnya, lalu _pod_ dikeluarkan dari daftar _endpoint_ Service.

      *Tindakan bila gagal:* _pod_ tidak menerima _request_ baru, tetapi _container_ tidak di-_restart_. Begitu kembali `200`, _pod_ menerima _traffic_ lagi.

      *Yang diperiksa di studi kasus:* _ping_ ke database milik service sendiri dengan batas 2 detik, `503` bila gagal.
    ],
  )
  #v(8pt)
  #text(size: 11pt, fill: slate)[_startupProbe_ menunda _liveness_ dan _readiness_ untuk service yang _startup_-nya lama. Studi kasus tidak memerlukannya. YAML ketiga _probe_ dibahas di Lab 9.]
]

#slide(kicker: "Anatomi service", title: [Skenario _liveness_ dan _readiness_])[
  #set table(inset: (x: 5pt, y: 5pt))
  #show table.cell: set text(size: 11.5pt)
  #table(
    columns: (1fr, auto, auto, 1.15fr, 1.35fr),
    [Skenario], [`/healthz`], [`/readyz`], [Tindakan Kubernetes], [Alasan],
    [_Startup_, service sedang menghubungi database], [Belum menjawab], [Belum menjawab], [_Pod_ belum menerima _traffic_. Bila koneksi gagal, proses berhenti dengan _error_ dan _container_ di-_restart_], [Server HTTP baru dibuka setelah _ping_ ke database berhasil. Bila tahap ini lebih lama dari batas _liveness_, gunakan _startupProbe_],
    [Database mati sementara], [`200`], [`503`], [_Pod_ dikeluarkan dari Service, tanpa _restart_], [_Restart_ tidak memperbaiki database. Bila _liveness_ ikut memeriksa database, semua _pod_ di-_restart_ bersamaan],
    [Proses macet, server HTTP tidak menjawab], [_Timeout_], [_Timeout_], [_Container_ di-_restart_], [Hanya _restart_ yang mengembalikan proses yang macet],
    [_Overload_], [Lambat], [Lambat atau `503`], [_Pod_ dikeluarkan sementara dari Service], [Beban beralih ke replika lain. Batas _liveness_ dibuat longgar agar beban sesaat tidak memicu _restart_ yang menambah beban],
    [Account service lambat, dilihat dari transfer service], [`200`], [`200`], [Tidak ada], [_Readiness_ transfer hanya memeriksa database transfer. Gangguan account ditangani _timeout_ dan _circuit breaker_ (Hari 2)],
  )
  #v(6pt)
  #note(kind: "warn")[*Mengapa perlu dua _probe_?* Gangguan terbagi dua jenis. Sebagian hilang dengan sendirinya, misalnya database yang sementara mati: _pod_ cukup berhenti menerima _traffic_ sambil menunggu (_readiness_). Sebagian lagi hanya hilang dengan _restart_, misalnya proses yang macet (_liveness_). Tindakan untuk kedua jenis gangguan ini berlawanan, sehingga masing-masing membutuhkan _probe_ sendiri.]
]

#code-slide(kicker: "Anatomi service", title: [_Graceful shutdown_],
  side: [
    - Saat menerima `SIGTERM`, server berhenti menerima koneksi baru.
    - `srv.Shutdown` menunggu _request_ yang sedang berjalan selesai, dengan batas 10 detik.
    - Batas ini berbeda per service. Sejak Lab 5, transfer menunggu hingga 60 detik agar saga tidak terpotong di antara debit dan credit.
    - _Rolling update_ di Kubernetes (Hari 4) mengandalkan perilaku ini agar tidak ada transfer yang terputus di tengah proses (faktor IX, _Disposability_).
  ],
)[
```go
srv := &http.Server{
    Addr:              cfg.HTTPAddr,
    Handler:           mux,
    ReadHeaderTimeout: 5 * time.Second,
}
// ... server berjalan di goroutine (slide "Goroutine dan channel")

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
    [_Body_ berisi JSON yang tidak valid atau memuat _field_ tak dikenal], [Proses _decode_ gagal], [`400`],
    [Isi _field_ tidak memenuhi aturan], [`ValidationError`], [`400` beserta daftar _field_],
    [Nomor rekening sudah terdaftar], [`ErrAlreadyExists`], [`409`],
    [Rekening tidak ditemukan], [`ErrNotFound`], [`404`],
    [Saldo tidak mencukupi untuk debit], [`ErrInsufficientFunds`], [`422`],
    [_Method_ tidak terdaftar untuk _path_ tersebut], [Ditangani `ServeMux`], [`405`],
    [_Error_ lain saat melayani _request_ API, misalnya database terputus], [_Error_ apa pun], [`500`],
    [`GET /readyz` saat _ping_ ke database gagal], [_Ping_ gagal], [`503`],
  )
  #v(10pt)
  #note[`500` berarti satu _request_ gagal karena _error_ yang tidak terduga. Klien hanya menerima `"internal error"`, sedangkan detailnya, seperti alamat database atau isi _query_, hanya ditulis ke _log_. `503` dari `/readyz` berarti _instance_ ini belum siap menerima _traffic_, sehingga Kubernetes mengeluarkan _pod_ tersebut dari Service.]
]

// ── 06 Lab 1 ───────────────────────────────────────────────────────────────

#section-slide(number: "06", title: "Lab 1: Account Service", subtitle: [REST, PostgreSQL, validasi, dan _health check_])

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
      #note(kind: "tip")[Jalankan `make test` sebelum melanjutkan ke Lab 2. _Unit test_ untuk _handler_ menggunakan `httptest` tanpa database.]
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

#decision(title: "pgx tanpa ORM",
  [Akses PostgreSQL dengan SQL yang terlihat jelas, kendali penuh atas transaksi, dan kondisi saldo yang diperiksa di klausa `where` (slide "Mencegah saldo negatif saat dua debit bersamaan").],
  [
    - pgx langsung (`pgxpool`)
    - `database/sql` dengan _driver_ PostgreSQL
    - sqlc: kode Go dibangkitkan dari SQL
    - ORM: GORM, ent
  ],
  [pgx v5 dengan `pgxpool`. SQL ditulis langsung dengan `pgx.NamedArgs`, dan hasil _query_ dipetakan ke _struct_ dengan `pgx.RowToStructByPos`.],
  [
    - Setiap _query_ terbaca apa adanya, termasuk fitur khusus PostgreSQL
    - Urutan kolom di `returning` dan `select` harus sama dengan urutan _field_ di _struct_
    - Perubahan skema diikuti perubahan _query_ secara manual, dan kode terikat ke PostgreSQL
  ],
)

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

// ── 07 Lab 2 ───────────────────────────────────────────────────────────────

#section-slide(number: "07", title: "Lab 2: Transfer Service", subtitle: [Dua service, dua database, dan komunikasi REST pertama])

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
        - Variabel wajib baru: `ACCOUNT_SERVICE_URL` (faktor IV: account service diakses melalui alamat dari konfigurasi)
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
      Dana sudah keluar dari rekening sumber, tetapi tidak sampai di rekening tujuan. Transfer dicatat `FAILED` dan _log_ mencatat bahwa _reversal_ manual diperlukan.

      #v(4pt)
      *Ditangani di Lab 5* dengan saga: debit yang sudah terjadi dibatalkan melalui transaksi kompensasi.
    ],
  )
  #v(12pt)
  #note(kind: "tip")[Lab 3 diawali dengan _fault injection_ pada account service (`PUT /admin/fault`) untuk memunculkan _delay_ dan _error_ secara sengaja, sehingga kedua celah ini terlihat langsung.]
]

// ── Penutup ────────────────────────────────────────────────────────────────

#slide(kicker: "Penutup Hari 1", title: "Ringkasan dan persiapan Hari 2")[
  #two-col(
    card([Hasil Hari 1 pada peta _concern_])[
      - *\#1 _Decomposition_:* _service boundary_ dari kapabilitas bisnis, satu database per service
      - *\#2 Komunikasi:* transfer memanggil account melalui REST
      - *\#7 _Configuration_:* variabel wajib dari _environment variable_, tanpa nilai _default_ (faktor III)
      - *\#9 _Deployment_ (konsep):* _liveness_ dan _readiness_ dipisahkan sejak awal, _graceful shutdown_ (faktor IX)
      - Dua celah dicatat untuk \#3 _Resiliency_ dan \#4 Konsistensi data
      - Keputusan desain: Go, `ServeMux`, pgx tanpa ORM, _database per service_
    ],
    card("Persiapan Hari 2", accent: gold.darken(15%))[
      - Pastikan `make test` lulus dan kode sesuai _tag_ `lab-02`
      - Pastikan `protoc`, `protoc-gen-go`, dan `protoc-gen-go-grpc` terpasang (Lab 4)
      - _Concern_ Hari 2: \#3 _Resiliency_ (_timeout_, _retry_, _circuit breaker_), \#2 gRPC untuk panggilan internal, dan \#4 konsistensi data lintas service
    ],
  )
]
