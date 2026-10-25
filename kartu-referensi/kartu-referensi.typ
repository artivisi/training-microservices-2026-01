#import "../_template/panduan.typ": panduan

#show: panduan.with(
  label: "KARTU REFERENSI",
  title: "Kartu Referensi Pola Microservices",
  subtitle: "Training Arsitektur Microservices dan Cloud dengan Golang",
  client: sys.inputs.at("client"),
  date: "Oktober 2026",
  metadata: (
    ("Training", "26 – 29 Oktober 2026"),
    ("Isi", "Kapan setiap pola layak digunakan, beserta beban dan risikonya"),
    ("Studi kasus", "Sistem simulasi perbankan: account, transfer, notification"),
    ("Repositori", "github.com/artivisi/training-microservices-2026-01"),
  ),
)

#set page(flipped: true, margin: (top: 2cm, bottom: 1.8cm, x: 1.6cm))
// Baris tabel tidak terpotong di pergantian halaman.
#set table.cell(breakable: false)
#let cek = box(width: 7pt, height: 7pt, stroke: 0.6pt, baseline: 1pt)

// Kolom tabel pola: nama, masalah, layak, tidak perlu, beban/risiko, lab.
#let kolom = (1.05fr, 1.75fr, 1.75fr, 1.6fr, 1.9fr, 0.55fr)
#let pola(..baris) = {
  set text(size: 8pt)
  table(
    columns: kolom,
    inset: 4pt,
    table.header(
      [Pola], [Masalah yang Diselesaikan], [Layak Digunakan Bila],
      [Tidak Perlu Bila], [Beban dan Risiko], [Lab],
    ),
    ..baris,
  )
}

= Peta _Concern_ Microservices

Setiap sistem microservices harus menjawab sepuluh _concern_ berikut. Setiap _concern_ ditangani di kode, yaitu _library_ yang dipasang di setiap service, atau oleh platform (Kubernetes dan infrastruktur pendukung). Platform Spring Cloud menangani banyak _concern_ di _library_ ekosistem Java: Eureka untuk _service discovery_, Spring Cloud LoadBalancer (dulu Ribbon) untuk _load balancing_ di sisi klien, Resilience4j (dulu Hystrix) untuk _circuit breaker_, dan Config Server untuk konfigurasi. Dukungan ini hanya berlaku untuk service JVM. Platform Kubernetes menyediakan _service discovery_, _load balancing_, konfigurasi, _restart_, dan _rollout_ untuk service dalam bahasa apa pun. Service _standalone_ di VM, misalnya beberapa service Laravel atau Express.js, tidak memiliki keduanya, sehingga tim menyediakan sendiri setiap _concern_ dengan Nginx, `.env`, skrip _deploy_, dan PM2 atau supervisor. Kebijakan _resiliency_, konsistensi data, pemeriksaan _security_, dan instrumentasi tetap ditulis di kode. Service Go di studi kasus mengandalkan platform dan beberapa _library_ kecil, tanpa _framework_ microservices.

#{
  set text(size: 8pt)
  table(
    columns: (0.25fr, 1.35fr, 1.5fr, 1.9fr, 1.5fr, 1.7fr, 0.55fr),
    inset: 4pt,
    table.header([], [_Concern_], [Pertanyaan yang Dijawab], [Pola dan Teknik di Studi Kasus], [Di Kode (_Library_)], [Di Platform atau Infrastruktur], [Lab]),
    [1], [_Decomposition_ dan kepemilikan data], [_Service boundary_ dan pemilik data], [Service per domain bisnis, _database per service_, data milik service lain diambil melalui API atau _event_], [—], [_Database per service_], [1, 2],
    [2], [Komunikasi sinkron dan asinkron], [REST, gRPC, _messaging_], [REST untuk _channel_, gRPC untuk panggilan internal, Kafka untuk _event_], [`net/http`, grpc-go, kafka-go], [Kafka], [2, 4, 5],
    [3], [_Resiliency_], [Tetap berfungsi saat dependensi lambat atau mati], [_Timeout_, _retry_ dengan _backoff_, _circuit breaker_], [failsafe-go], [_Probe_, _restart_, _rolling update_], [3, 4, 9],
    [4], [Konsistensi data], [Perubahan data lintas database], [_Saga_ dengan kompensasi, _transactional outbox_, _idempotency key_, _idempotent consumer_], [Kode service (pgx, kafka-go)], [—], [5, 6],
    [5], [_Security_], [Siapa boleh memanggil apa], [OAuth2 _client credentials_, validasi JWT], [JWT _middleware_ (REST) dan _interceptor_ (gRPC)], [Hydra (_authorization server_), API _gateway_], [7],
    [6], [_Observability_], [Kondisi tiap service dan integrasi antarservice], [_Log_ terstruktur dengan _correlation ID_, metrik, _distributed tracing_], [`slog`, Prometheus _client_, OTel SDK], [Grafana, Loki, Tempo, Prometheus], [8],
    [7], [_Configuration_ (termasuk _centralized config_ dan _secret_)], [Nilai yang berbeda per _environment_], [_Environment variable_ wajib tanpa nilai _default_ (12-factor)], [`LoadConfig`], [ConfigMap, Secret, _secret manager_], [1, 9],
    [8], [_Service discovery_ dan _load balancing_], [Alamat service tujuan], [Alamat service dibaca dari konfigurasi], [— (alamat dari konfigurasi)], [Kubernetes Service (DNS), Ingress], [9],
    [9], [_Packaging_ dan _deployment_], [Cara service dijalankan dan diperbarui], [_Multi-stage_ Dockerfile, _image_ statis _non-root_, _rolling update_], [Dockerfile], [Kubernetes Deployment, _probe_, _rolling update_], [9],
    [10], [_Automation_ (CI/CD)], [Dari _commit_ ke _production_], [_Pipeline_ per service: _test_, _build image_, _deploy_], [Target `Makefile`], [_Pipeline_ (git server dan runner CI, Jenkins)], [10],
  )
}

= Cara Membaca

Setiap baris memuat satu pola. Kolom *Layak Digunakan Bila* dan *Tidak Perlu Bila* menjadi dasar keputusan. Kolom *Beban dan Risiko* mencatat pekerjaan tambahan yang muncul setelah pola diterapkan. Kolom *Lab* menunjuk lab studi kasus yang menerapkan pola tersebut. _Checkpoint_ setiap lab tersedia sebagai _tag_ `lab-NN` di repositori studi kasus.

Setiap pola menambah komponen yang harus dioperasikan. Pola yang tidak menjawab masalah yang sedang dihadapi sistem hanya menambah beban tanpa manfaat.

= Dekomposisi dan Komunikasi

#pola(
  [*Dekomposisi service* dan _database per service_],
  [Tim dan fitur saling menunggu karena satu _codebase_ dan satu _database_ digunakan bersama. Perubahan skema untuk satu fitur ikut memengaruhi fitur lain],
  [Batas domain bisnis sudah jelas (rekening, transfer, notifikasi). Tiap bagian memiliki tim, jadwal rilis, atau kebutuhan skala yang berbeda],
  [Satu tim kecil mengelola seluruh aplikasi. Batas domain masih sering berubah. Pemisahan modul di dalam satu aplikasi (_modular monolith_) sudah cukup],
  [_Join_ lintas _database_ tidak tersedia, sehingga data diambil melalui API atau _event_. Data antarservice hanya mencapai _eventual consistency_. Jumlah _deployment_ dan _database_ yang dioperasikan bertambah],
  [1, 2],

  [*REST sinkron*],
  [Pemanggil membutuhkan jawaban saat itu juga, misalnya data rekening sebelum transfer diproses],
  [API untuk kanal (_mobile_, web, mitra). Klien beragam dan interoperabilitas lebih penting dibandingkan efisiensi],
  [Panggilan internal yang sering dengan kontrak ketat (gunakan gRPC). Pemanggil tidak menunggu hasil (gunakan _messaging_)],
  [Pemanggil ikut lambat atau gagal saat service tujuan bermasalah. Kontrak hanya tercatat di dokumentasi dan tidak diperiksa _compiler_],
  [1, 2, 3],

  [*gRPC*],
  [Kontrak antarservice internal tidak terdefinisi tegas. Serialisasi JSON boros untuk panggilan internal yang sering],
  [Panggilan antarservice internal. Kontrak perlu diperiksa saat kompilasi (protobuf). Autentikasi, log, dan _resiliency_ ditangani terpusat di _interceptor_],
  [Klien berupa _browser_ atau mitra eksternal. Tim belum siap mengelola protoc dan versi kontrak],
  [Kode hasil _generate_ harus dikelola. Perubahan kontrak wajib _backward compatible_, nomor _field_ tidak boleh digunakan ulang. _Debugging_ dengan grpcurl membutuhkan file `.proto` atau _reflection_ yang aktif di server. HTTP/2 menggunakan _persistent connection_, sehingga _Service_ Kubernetes (L4) mengarahkan semua panggilan ke satu _pod_. Penyebaran panggilan ke semua _pod_ membutuhkan _load balancing_ di sisi klien atau _proxy_ L7],
  [4],

  [*_Messaging_ asinkron* (Kafka)],
  [Pengirim bergantung pada ketersediaan semua penerima. Satu _event_ bisnis perlu diproses beberapa service],
  [Penerima tidak perlu menjawab saat itu juga (notifikasi, audit, analitik). Beberapa _consumer_ memproses _event_ yang sama. Lonjakan beban perlu diredam],
  [Pemanggil membutuhkan hasil untuk melanjutkan proses. Volume rendah dengan satu penerima saja],
  [Pengiriman _at-least-once_ menghasilkan duplikat. Urutan hanya terjamin di dalam satu _partition_ (per _key_). Broker menjadi infrastruktur tambahan. Alur sulit ditelusuri tanpa _tracing_],
  [5, 6],
)

= _Resiliency_

#pola(
  [*Timeout*],
  [Service tujuan yang lambat menahan _goroutine_, koneksi, dan _request_ pemanggil tanpa batas waktu],
  [Setiap panggilan jaringan, tanpa kecuali. Nilainya ditentukan dari latensi p99 service tujuan dan _deadline_ yang dijanjikan ke pemanggil],
  [Tidak ada pengecualian untuk panggilan jaringan],
  [Timeout yang terlalu pendek menggagalkan _request_ yang sebenarnya akan berhasil. Setelah timeout, pemanggil tidak tahu status di sisi tujuan, termasuk apakah debit sudah tercatat],
  [3, 4],

  [*Retry* dengan _backoff_],
  [Gangguan sesaat (koneksi ditolak, HTTP 503, _pod restart_) menggagalkan _request_ yang akan berhasil pada percobaan berikutnya],
  [Gangguan bersifat sementara, dan operasi _idempotent_ atau _request_ terbukti belum diproses (koneksi ditolak). HTTP 503 dan `Unavailable` hanya aman di-retry bila server menjamin status tersebut dikirim sebelum operasi dijalankan (di studi kasus: _fault injection_ di account). Bila tidak ada jaminan tersebut, operasi harus dibuat _idempotent_ lebih dahulu (Lab 5)],
  [Operasi tidak _idempotent_ setelah timeout (risiko debit ganda). _Error_ bisnis (4xx, saldo tidak cukup). _Circuit breaker_ sedang _open_],
  [Retry tanpa _backoff_ dan _jitter_ memperberat service yang sedang bermasalah (_retry storm_). Retry di beberapa tingkat panggilan membuat jumlah percobaan berlipat ganda. Latensi total bertambah],
  [3, 4, 5],

  [*Circuit breaker*],
  [Pemanggil terus mengirim _request_ ke service yang sedang gagal. _Request_ yang tertahan menumpuk dan kegagalan merambat ke pemanggil],
  [Ketergantungan sinkron ke service lain yang dapat gagal dalam waktu lama. _Fail fast_ dengan status jelas lebih baik dibandingkan menunggu. HTTP 503 hanya digunakan bila belum ada perubahan yang diterapkan, sehingga pemanggil aman mengulang],
  [_Database_ milik service sendiri (timeout dan _connection pool_ sudah cukup). Volume panggilan terlalu rendah sehingga ambang kegagalan tidak bermakna. Langkah kompensasi saga, karena _breaker_ yang baru berpindah ke _open_ justru menolak _reversal_. Untuk _reversal_, gunakan retry berbatas waktu tanpa _breaker_ (Lab 5)],
  [Ambang dan _delay_ perlu disetel berdasarkan data. Setiap _pod_ memiliki _breaker_ sendiri dengan state berbeda. Perubahan state wajib tercatat di log dan metrik],
  [3, 4, 8],
)

= Konsistensi Data

#pola(
  [*Saga*],
  [Satu transaksi bisnis mengubah data di beberapa _database_. _Two-phase commit_ membuat transaksi bergantung pada ketersediaan semua peserta sekaligus],
  [Proses bisnis lintas service dengan aksi kompensasi untuk setiap langkah (debit dibatalkan dengan kredit balik)],
  [Seluruh data berada dalam satu _database_ (transaksi lokal sudah cukup)],
  [State antara (`DEBITED`) terlihat oleh pembaca. Kompensasi dapat gagal dan membutuhkan penanganan manual (`COMPENSATION_FAILED`). Setiap langkah dan kompensasi harus _idempotent_. _Graceful shutdown_ dan _grace period_ platform harus mencakup durasi terburuk satu saga. Proses yang dihentikan paksa di antara langkah meninggalkan state antara, dan _recovery job_ harus menyelesaikannya. Langkah yang tidak dapat dikompensasi (misalnya pengiriman dana ke bank lain) diletakkan paling akhir (_pivot transaction_), dan langkah sesudahnya wajib dapat di-retry hingga berhasil],
  [5],

  [*Transactional outbox*],
  [Penulisan ke _database_ dan _publish_ ke broker terdiri dari dua operasi terpisah. _Crash_ di antara keduanya menghasilkan perubahan data tanpa _event_, atau _event_ tanpa perubahan data],
  [Perubahan state wajib diikuti _event_ yang tidak boleh hilang (status transfer, mutasi rekening)],
  [_Event_ bersifat informatif dan boleh hilang sesekali. Service tidak memiliki _database_ sendiri],
  [Tabel outbox terus bertambah dan perlu dibersihkan. _Relay_ menambah latensi sebesar interval _polling_. _Crash_ setelah _publish_ dan sebelum baris outbox ditandai terkirim menghasilkan duplikat. Menjalankan lebih dari satu _relay_ sekaligus membutuhkan `FOR UPDATE SKIP LOCKED`],
  [5],

  [*Idempotency key*],
  [Klien atau retry mengulang _request_ (timeout, tombol ditekan dua kali), dan server memprosesnya dua kali],
  [Operasi pengubah data yang dapat diulang oleh klien atau retry: transfer, debit, kredit, pembayaran],
  [Operasi baca. Operasi yang _idempotent_ secara alami (PUT dengan nilai absolut, DELETE)],
  [_Key_ disimpan dengan _unique constraint_. _Request_ dengan _key_ sama dan isi berbeda perlu aturan sendiri (HTTP 422). _Request_ ulang dijawab dengan kode HTTP yang sama seperti respons pertama, sehingga penyebab kegagalan harus tersimpan. Masa simpan _key_ harus ditetapkan],
  [5, 6],

  [*Idempotent consumer*],
  [Broker mengirim ulang _message_ (_rebalance_, _crash_ sebelum _commit offset_, _replay_) sehingga efeknya terjadi dua kali],
  [Setiap _consumer_ dengan pengiriman _at-least-once_ yang efeknya tidak boleh ganda (mutasi saldo, notifikasi ke nasabah)],
  [Efek _consumer_ sudah _idempotent_ secara alami (_upsert_ nilai terbaru, isi _cache_)],
  [ID _event_ wajib ditulis dalam transaksi yang sama dengan efeknya. Tabel `processed_event` perlu kebijakan retensi. Efek ke sistem luar (SMS, email) tidak dapat ikut transaksi _database_. _Event_ yang tidak mungkin diproses (_poison message_) dilewati dengan log `ERROR` atau dikirim ke _dead-letter topic_, agar _partition_ tidak tertahan],
  [6],
)

== Perbandingan _Orchestration_ dan _Choreography_ pada Saga

#{
  set text(size: 8pt)
  table(
    columns: (1fr, 2.2fr, 2.2fr),
    inset: 4pt,
    table.header([Aspek], [_Orchestration_], [_Choreography_]),
    [Pengendali alur], [Satu service (orkestrator) memanggil setiap langkah dan menyimpan state saga], [Setiap service bereaksi terhadap _event_ service lain, tanpa pengendali pusat],
    [Visibilitas], [State saga dapat dibaca di satu tabel orkestrator], [State tersebar, hanya terlihat melalui _tracing_ dan log _event_],
    [Ketergantungan], [Orkestrator mengenal semua peserta], [Peserta hanya mengenal _event_, tetapi alur bisnis tersirat di banyak service],
    [Cocok untuk], [Alur dengan urutan ketat dan kompensasi bertingkat, seperti transfer dana], [Alur pendek dengan sedikit peserta dan langkah yang saling lepas],
    [Risiko], [Orkestrator menampung terlalu banyak logika bisnis], [Siklus _event_ antarservice dan alur yang sulit diubah tanpa menyentuh semua peserta],
    [Di studi kasus], [Transfer sebagai orkestrator: `PENDING` → `DEBITED` → `COMPLETED`, atau `COMPENSATED` / `FAILED` (Lab 5)], [Tidak diterapkan. Notification hanya _consumer_ _event_ akhir transfer dan tidak menjadi langkah saga. Versi _choreography_: account mem-_publish_ `AccountDebited`, lalu service lain bereaksi terhadap _event_ tersebut dan melakukan kredit tanpa orkestrator],
  )
}

= Security dan Observability

#pola(
  [*OAuth2 client credentials* dan JWT],
  [Service tujuan tidak mengetahui identitas dan hak pemanggil. Jaringan internal dianggap aman tanpa verifikasi],
  [Panggilan service ke service dan kanal ke service yang membutuhkan identitas dan _scope_. Token divalidasi lokal dengan JWKS tanpa memanggil _authorization server_ di setiap _request_],
  [Identitas pemanggil sudah dijamin mTLS dari _service mesh_ dan otorisasi per _scope_ tidak dibutuhkan],
  [_Authorization server_ menjadi ketergantungan kritis (token dan JWKS). JWT tidak dapat dicabut sebelum kedaluwarsa, sehingga masa berlakunya harus pendek. Token tanpa TLS dapat disadap],
  [7],

  [*Correlation ID* dan _distributed tracing_],
  [Satu transaksi melewati beberapa service dan broker. Log tiap service tidak terhubung, sehingga sumber kelambatan atau kegagalan sulit ditemukan],
  [Sejak sistem memiliki dua service. Konteks diteruskan melalui _header_ HTTP, _metadata_ gRPC, dan _header_ Kafka],
  [Aplikasi tunggal tanpa panggilan ke service lain (log biasa sudah cukup)],
  [Setiap titik masuk dan keluar wajib meneruskan konteks. Satu titik yang terlewat memutus _trace_. Volume data _trace_ besar sehingga perlu _sampling_. _Baggage_ dari pemanggil luar tidak diteruskan ke service internal],
  [8],

  [*Metrics* (Prometheus)],
  [Laju _error_, latensi, state _breaker_, dan jumlah _event_ outbox yang belum terkirim baru diketahui setelah pengguna mengeluh],
  [Setiap service: _rate_, _error_, _duration_ per _route_, ditambah metrik bisnis (`transfers_total`) dan metrik pola (`circuit_breaker_state`, `outbox_pending`)],
  [Selalu diperlukan. Jumlah dan isi label harus dibatasi],
  [Label berkardinalitas tinggi (ID transfer, nomor rekening) membebani Prometheus. Metrik tanpa _alert_ dan _dashboard_ tidak pernah dibaca],
  [8],

  [*Health probe*: _liveness_ dan _readiness_],
  [Kubernetes mengirim trafik ke _pod_ yang belum siap, atau membiarkan _pod_ yang macet tetap berjalan],
  [Setiap service di Kubernetes atau di belakang _load balancer_. _Liveness_ (`/healthz`): proses masih merespons. _Readiness_ (`/readyz`): _dependency_ wajib seperti _database_ dapat dijangkau],
  [_Liveness_ tidak perlu memeriksa _dependency_ eksternal. _Liveness_ yang ikut memeriksa _database_ memicu _restart_ massal saat _database_ mati, padahal _restart_ tidak memperbaiki apa pun],
  [Ambang atau timeout _probe_ yang terlalu ketat memicu _restart_ berulang. _Readiness_ yang memeriksa service lain menghasilkan kegagalan berantai. _Health service_ gRPC yang tidak memeriksa _database_ tidak cocok sebagai _readiness_],
  [1, 9],
)

= Deployment dan Operasi

#pola(
  [*12-factor config*],
  [Konfigurasi tertanam di kode atau _image_, sehingga _image_ yang sama tidak dapat dipindahkan antar-_environment_],
  [Service yang di-_deploy_ ke lebih dari satu _environment_. Nilai rahasia dipisahkan ke Secret, nilai lain ke ConfigMap],
  [Konstanta bisnis yang sama di semua _environment_ tetap ditulis di kode],
  [Variabel wajib yang hilang harus menghentikan _startup_ dengan pesan _error_ yang menyebut nama variabelnya. Nilai _default_ menyembunyikan konfigurasi yang terlewat hingga _production_],
  [1, 9],

  [*Container image*: _multi-stage_, _static_, _non-root_],
  [_Image_ yang memuat _compiler_ dan _shell_ berukuran besar dan memperluas _attack surface_. Proses _root_ ditolak platform dengan kebijakan ketat (OpenShift _restricted SCC_)],
  [Setiap service yang berjalan di Kubernetes atau OpenShift. Go dengan `CGO_ENABLED=0` menghasilkan _binary_ statis yang cukup dijalankan di `FROM scratch`],
  [Aplikasi membutuhkan _library_ C (CGO) atau _tools_ di dalam _container_. Gunakan _base image_ minimal sebagai pengganti `scratch`],
  [_Shell_ untuk _debugging_ tidak tersedia (gunakan `kubectl debug`). Sertifikat CA harus disalin manual. Aplikasi wajib berjalan dengan UID acak dan _filesystem read-only_],
  [9],

  [*Rolling update*],
  [Mengganti semua _pod_ sekaligus menghentikan layanan selama versi baru dijalankan],
  [Versi baru kompatibel dengan versi lama selama masa transisi, baik API maupun skema _database_],
  [Perubahan skema yang tidak kompatibel: gunakan migrasi _expand/contract_ (kolom baru ditambahkan lebih dahulu, kolom lama dihapus setelah versi lama berhenti), atau strategi _recreate_ dengan _downtime_. API yang tidak kompatibel: gunakan _blue-green_, karena trafik dipindahkan sekaligus],
  [Dua versi melayani trafik bersamaan. _Readiness_ yang keliru meloloskan _pod_ yang rusak. _Rollback_ membutuhkan _tag image_ yang tidak berubah, sehingga _tag_ `latest` harus dihindari. _Build_ ulang dengan _tag_ yang sama juga tidak memicu _rollout_. _Pod_ yang dihentikan masih menerima _request_ beberapa detik (`preStop` _sleep_), dan `terminationGracePeriodSeconds` harus mencakup batas _shutdown_ service],
  [9, 10],

  [*Horizontal Pod Autoscaler*],
  [Beban berfluktuasi. Dengan jumlah replika yang tetap, kapasitas berlebih saat sepi dan tidak mencukupi saat ramai],
  [Service _stateless_ dengan beban naik turun dan metrik yang sejalan dengan beban (CPU, _request_ per detik)],
  [_Bottleneck_ berada di _database_ atau service lain, sehingga tambahan replika hanya menambah koneksi. _Consumer_ Kafka melebihi jumlah _partition_. Beban stabil],
  [_Resource requests_ harus akurat. _Scale-up_ membutuhkan waktu (_startup_ dan _readiness_). Batas koneksi _database_ harus menampung replika maksimum],
  [Konsep (hari 4)],

  [*CI/CD per service*],
  [Rilis satu service menunggu service lain. _Deployment_ manual tidak seragam dan tidak tercatat],
  [Service dirilis independen. Setiap _commit_ diuji, dijadikan _image_ dengan _tag_ berupa _commit hash_, lalu di-_deploy_ otomatis. _Pipeline_ hanya memanggil target `make`, sehingga dapat dipetakan ke Jenkinsfile],
  [Service selalu dirilis bersamaan. Kondisi ini menandakan _distributed monolith_, sehingga _service boundary_ perlu diperbaiki lebih dahulu],
  [Jumlah _pipeline_ sebanding dengan jumlah service. Perubahan modul bersama (`proto`) memicu _pipeline_ beberapa service. _Credential_ _registry_ dan _cluster_ harus dikelola di _runner_],
  [10],

  [*GitOps*],
  [State _cluster_ menyimpang dari _manifest_ di repositori. Perubahan langsung di _cluster_ tidak tercatat],
  [Banyak _cluster_ atau _environment_. Audit perubahan wajib. _Pipeline_ tidak boleh menyimpan _credential_ _cluster_],
  [Satu _cluster_ kecil dengan _pipeline push_ yang sudah tercatat. Tim belum terbiasa dengan _manifest_ dan CI],
  [Komponen tambahan (_controller_ di dalam _cluster_) dan repositori _manifest_ terpisah. Secret membutuhkan mekanisme enkripsi tersendiri],
  [Konsep (hari 4)],
)

= Gejala _Distributed Monolith_

Sistem yang sudah dipecah menjadi beberapa service tetapi masih harus diubah, diuji, dan dirilis bersamaan memikul beban _microservices_ tanpa mendapatkan manfaatnya. Tiga gejala atau lebih yang tercentang menandakan _service boundary_ perlu ditinjau ulang.

#{
  set text(size: 8pt)
  table(
    columns: (0.25fr, 2.6fr, 2.2fr, 2.6fr),
    inset: 4pt,
    table.header([], [Gejala], [Penyebab Umum], [Arah Perbaikan]),
    [#cek], [Fitur baru hampir selalu mengubah beberapa service sekaligus], [_Service boundary_ mengikuti _layer_ teknis (API, logika, data) dan tidak mengikuti domain bisnis], [Tetapkan ulang _service boundary_ menurut domain. Gabungkan service yang selalu berubah bersamaan],
    [#cek], [Service harus dirilis bersamaan dengan urutan tertentu], [Kontrak API berubah tanpa _backward compatibility_], [Perubahan kontrak bersifat aditif. Versi kontrak lama tetap dilayani selama masa transisi],
    [#cek], [Beberapa service membaca atau menulis tabel yang sama], [_Database_ bersama dipertahankan setelah pemecahan service], [_Database per service_. Data milik service lain diambil melalui API atau _event_],
    [#cek], [Satu service mati menghentikan hampir semua alur], [Rantai panggilan sinkron panjang tanpa timeout dan _circuit breaker_], [Timeout dan _breaker_ di setiap panggilan. Langkah yang tidak perlu ditunggu dipindahkan ke _messaging_],
    [#cek], [Satu _request_ dari kanal memicu panggilan bolak-balik antarservice (A → B → A)], [Data dan logika yang saling membutuhkan ditempatkan di service berbeda], [Gabungkan logika tersebut ke satu service, atau salin data yang dibutuhkan melalui _event_],
    [#cek], [_Library_ bersama memuat model domain dan logika bisnis], [Kode bersama digunakan untuk menghindari duplikasi lintas service], [_Library_ bersama hanya berisi kode teknis (log, _tracing_, kontrak protobuf). Logika bisnis tetap di service pemiliknya],
    [#cek], [Satu service tidak dapat diuji tanpa menjalankan semua service lain], [Ketergantungan sinkron yang tidak diisolasi di kode], [Klien service lain dibungkus _interface_ agar dapat diganti saat pengujian dengan `httptest` atau `bufconn`],
    [#cek], [Seluruh service berbagi satu _pipeline_ dan satu nomor versi], [Repositori dan proses rilis tetap dikelola sebagai satu aplikasi], [_Pipeline_ per service dengan filter _path_. _Tag image_ per service],
  )
}
