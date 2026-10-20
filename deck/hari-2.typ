// Day 2 deck: synchronous call failures, resiliency (Lab 3), gRPC (Lab 4),
// distributed consistency (saga, idempotency) as the bridge to Day 3.
// Build: make CLIENT="..." Deck-Hari-2-Microservices-2026-10.pdf
#import "../_template/deck.typ": *

#show: deck.with(
  title: "Resiliency dan gRPC untuk Komunikasi Antarservice",
  subtitle: [_Timeout_, _retry_, dan _circuit breaker_ dengan failsafe-go; kontrak protobuf dan gRPC untuk panggilan internal; saga dan _idempotency_ sebagai fondasi Hari 3],
  day-label: "Hari 2",
  client: sys.inputs.at("client"),
  date: "Oktober 2026",
)

// Nested boxes for the policy order slide.
#let layer-box(label, accent, body) = block(
  width: 100%, fill: accent.lighten(92%), stroke: 1.2pt + accent, radius: 6pt,
  inset: (x: 14pt, top: 10pt, bottom: 12pt),
)[
  #text(size: 11pt, weight: "bold", fill: accent.darken(15%), label)
  #v(4pt)
  #body
]

// ════════════════════════════════════════════════════════════════════════════
#slide(kicker: "Hari 2", title: "Agenda hari ini")[
  #table(
    columns: (auto, 1fr, auto),
    [Waktu], [Sesi], [Format],
    [09:00 – 09:45], [Kegagalan komunikasi sinkron: _timeout_, _retry_ dengan _backoff_, dan _circuit breaker_], [Presentasi],
    [09:45 – 10:45], [*Lab 3*: failsafe-go pada panggilan transfer ke account, simulasi service lambat dan mati], [_Hands-on_],
    [11:00 – 12:30], [gRPC untuk komunikasi internal: kontrak protobuf, _code generation_, _unary call_, _error handling_, _interceptor_], [Presentasi + demo],
    [13:30 – 15:00], [*Lab 4*: memindahkan panggilan transfer ke account dari REST ke gRPC], [_Hands-on_],
    [15:15 – 16:30], [Konsistensi data terdistribusi: alasan 2PC dihindari, saga, _idempotency key_], [Presentasi + demo],
  )
  #v(8pt)
  #note[Hari 2 dimulai dari _checkpoint_ `lab-02`. Peserta yang belum menyelesaikan Lab 2 menjalankan `git checkout lab-02` sebelum Lab 3.]
]

#slide(kicker: "Titik awal", title: "Kondisi studi kasus di akhir Lab 2")[
  #flow(
    node("client", sub: "curl / channel", kind: "ext"),
    arr(label: "POST /transfers", length: 110pt),
    node("transfer", sub: ":28082"),
    arr(label: "REST debit/credit", length: 130pt),
    node("account", sub: ":28081"),
  )
  #v(-4pt)
  #grid(columns: (1fr, 1fr, 1fr), align: center,
    [],
    node("db-transfer", sub: "PostgreSQL", kind: "db", width: 120pt, height: 60pt),
    node("db-account", sub: "PostgreSQL", kind: "db", width: 120pt, height: 60pt),
  )
  #v(10pt)
  #two-col(
    card("Sudah berjalan")[
      - Dua service dengan database masing-masing
      - Transfer memanggil account melalui REST untuk debit lalu credit
      - Account sudah dilengkapi _fault injection_ di `/admin/fault`
    ],
    card("Celah yang ditutup hari ini dan besok", accent: amber)[
      - HTTP client di transfer belum memiliki _timeout_
      - Debit tidak dikembalikan bila credit sesudahnya gagal (Hari 3)
      - Kontrak REST internal hanya diperiksa saat program berjalan
    ],
  )
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "01", title: "Kegagalan Komunikasi Sinkron",
  subtitle: [_Timeout_, _retry_ dengan _backoff_, dan _circuit breaker_])

#slide(kicker: "Konsep", title: "Kegagalan parsial terjadi setiap hari")[
  #bullets(
    [Pada monolith, pemanggilan fungsi selalu sampai ke tujuannya. Pada microservices, setiap pemanggilan melewati jaringan dan dapat gagal di tengah jalan.],
    [Service tujuan bisa mati, lambat, kehabisan koneksi database, atau sedang di-_deploy_ ulang. Kondisi tersebut terjadi setiap hari, tidak hanya saat insiden besar.],
    [Pemanggil tidak dapat membedakan "service tujuan belum memproses" dari "service tujuan sudah memproses tetapi jawabannya hilang".],
    [Karena itu setiap panggilan keluar perlu keputusan eksplisit: berapa lama menunggu, kapan mengulang, dan kapan berhenti mencoba.],
  )
  #v(4pt)
  #note(kind: "tip")[Pertanyaan pertama saat meninjau kode panggilan antarservice: apa yang terjadi bila service tujuan tidak menjawab selama satu menit?]
]

#slide(kicker: "Konsep", title: "Service lambat lebih berbahaya dibandingkan service mati")[
  #two-col(
    card("Service tujuan mati")[
      - Koneksi langsung ditolak (_connection refused_)
      - Pemanggil menerima _error_ dalam hitungan milidetik
      - _Goroutine_ dan koneksi segera dilepas
      - Gejalanya jelas: _error rate_ naik, mudah terdeteksi
    ],
    card("Service tujuan lambat", accent: red)[
      - Koneksi diterima, jawaban tidak kunjung datang
      - Pemanggil menunggu tanpa batas bila tidak ada _timeout_
      - _Goroutine_, koneksi, dan memori tertahan selama menunggu
      - Gejalanya samar: semua _request_ ikut lambat, tidak ada _error_
    ],
  )
  #v(10pt)
  #note(kind: "warn")[`http.Client{}` tanpa _field_ `Timeout` dan tanpa _deadline_ pada `context` menunggu selamanya. Kondisi ini berlaku pada transfer service di akhir Lab 2.]
]

#slide(kicker: "Konsep", title: [_Cascading failure_ (kegagalan berantai)])[
  #flow(
    node("channel", sub: "menunggu transfer", kind: "ext", width: 130pt),
    arr(length: 60pt),
    node("transfer", sub: "goroutine menumpuk", width: 150pt),
    arr(label: "menunggu", length: 90pt),
    node("account", sub: "lambat 30 detik", width: 140pt),
    arr(length: 50pt),
    node("db-account", sub: "lock / I/O lambat", kind: "db", width: 120pt, height: 64pt),
  )
  #v(14pt)
  #enum(
    [Database account melambat, sehingga setiap _request_ ke account menunggu lebih lama.],
    [Transfer terus mengirim _request_ baru sementara _request_ lama belum selesai. _Goroutine_ dan koneksi HTTP di transfer bertambah tanpa batas.],
    [Transfer kehabisan memori atau koneksi, lalu ikut lambat bagi channel, termasuk untuk _endpoint_ yang tidak menyentuh account.],
    [Channel mengulang _request_ yang lambat, sehingga beban ke seluruh rantai bertambah.],
  )
]

#slide(kicker: "Konsep", title: "Tiga pola proteksi panggilan sinkron")[
  #table(
    columns: (auto, 1.3fr, 1fr),
    [Pola], [Fungsi], [Pertanyaan yang Dijawab],
    [_Timeout_], [Memberi batas waktu tunggu eksplisit pada setiap panggilan keluar], [Berapa lama pemanggil bersedia menunggu?],
    [_Retry_ + _backoff_], [Mengulang panggilan yang gagal karena gangguan sesaat, dengan jeda yang makin panjang dan jumlah percobaan terbatas], [Kapan mengulang aman, dan berapa kali?],
    [_Circuit breaker_], [Menghentikan sementara panggilan ke service yang terbukti gagal, lalu mencoba kembali secara bertahap], [Kapan berhenti mencoba agar service tujuan sempat kembali aktif?],
  )
  #v(10pt)
  #note[Ketiga pola saling melengkapi. _Timeout_ tanpa _circuit breaker_ tetap membuang dua detik untuk setiap _request_ ke service yang sudah jelas tidak menjawab. _Retry_ tanpa _timeout_ dapat menunggu selamanya pada percobaan pertama.]
]

#slide(kicker: "Pola 1", title: [_Timeout_ pada setiap panggilan keluar])[
  #two-col(ratio: (1.1fr, 1fr),
    [
      #bullets(size: 13.5pt,
        [*_Timeout_ per percobaan.* Batas waktu untuk satu panggilan HTTP atau gRPC. Pada studi kasus nilainya 2 detik.],
        [*_Timeout_ keseluruhan.* Batas waktu untuk seluruh panggilan beserta semua _retry_-nya. Nilai ini menentukan waktu tunggu yang dirasakan channel.],
        [Nilai _timeout_ diambil dari _latency_ normal service tujuan (misalnya p99) ditambah margin, lalu dicocokkan dengan batas waktu yang dijanjikan ke channel.],
        [Di Go, _timeout_ dibawa oleh `context.Context`. _Deadline_ dari pemanggil ikut membatasi semua panggilan turunannya.],
      )
    ],
    [
```go
// Satu percobaan dibatasi 2 detik
ctx, cancel := context.WithTimeout(
    r.Context(), 2*time.Second)
defer cancel()

req, _ := http.NewRequestWithContext(
    ctx, http.MethodPost, url, body)
resp, err := client.Do(req)
if errors.Is(err, context.DeadlineExceeded) {
    // jawaban tidak datang tepat waktu;
    // status di account TIDAK diketahui
}
```
    ],
  )
]

#slide(kicker: "Pola 2", title: [_Retry_ dengan _backoff_ dan _jitter_])[
  #flow(
    node("percobaan 1", kind: "infra", width: 110pt, height: 44pt),
    arr(label: "± 100 ms", length: 80pt),
    node("percobaan 2", kind: "infra", width: 110pt, height: 44pt),
    arr(label: "± 200 ms", length: 80pt),
    node("percobaan 3", kind: "infra", width: 110pt, height: 44pt),
    arr(label: "± 400 ms", length: 80pt),
    node("percobaan 4", kind: "infra", width: 110pt, height: 44pt),
  )
  #v(12pt)
  #two-col(
    card([_Backoff_])[
      Jeda antarpercobaan berlipat dua setiap kali, mulai 100 ms dengan batas atas 1 detik. Service tujuan yang sedang kewalahan mendapat waktu untuk kembali aktif.
    ],
    card([_Jitter_], accent: gold.darken(15%))[
      Jeda diacak ±25%. Tanpa _jitter_, ratusan transfer yang gagal bersamaan akan mengulang pada milidetik yang sama dan membebani account sekaligus.
    ],
  )
  #v(8pt)
  #note(kind: "warn")[Jumlah percobaan wajib dibatasi (studi kasus: maksimal 3 _retry_). _Retry_ tanpa batas mengubah gangguan sesaat menjadi beban berlipat bagi service yang sedang bermasalah.]
]

#slide(kicker: "Pola 2", title: [_Retry_ hanya aman bila operasinya _idempotent_])[
  #table(
    columns: (1.3fr, 1fr, auto),
    [Kondisi yang Diterima Transfer], [Apakah Debit Sudah Diterapkan?], [_Retry_ di Lab 3],
    [Koneksi ditolak saat _dial_], [Belum, _request_ tidak pernah terkirim], [Ya],
    [HTTP 503 dari account], [Belum, account menolak sebelum memproses], [Ya],
    [_Timeout_ setelah _request_ terkirim], [Tidak diketahui, bisa saja sudah], [*Tidak*],
    [HTTP 500 atau jawaban lain yang tidak dikenal], [Tidak diketahui], [*Tidak*],
    [HTTP 404 atau 422 (rekening tidak ada, saldo kurang)], [Ditolak oleh aturan bisnis], [Tidak, hasilnya akan sama],
  )
  #v(10pt)
  #note(kind: "warn")[Debit di account belum _idempotent_, sehingga _request_ yang dikirim dua kali akan mendebit dua kali. Selama kondisi itu berlaku, _timeout_ tidak boleh di-_retry_. Lab 5 menambahkan _reference_ unik pada setiap mutasi, dan sejak itu _timeout_ ikut di-_retry_.]
]

#slide(kicker: "Pola 3", title: [_State_ pada _circuit breaker_])[
  #diagram(height: 250pt,
    at(30pt, 160pt, node("CLOSED", sub: "panggilan diteruskan", kind: "infra", width: 150pt)),
    at(357pt, 10pt, node("OPEN", sub: "ditolak seketika", kind: "infra", width: 150pt)),
    at(684pt, 160pt, node("HALF-OPEN", sub: "percobaan terbatas", kind: "infra", width: 150pt)),
    edge((140pt, 160pt), (357pt, 50pt), label: "5 dari 10 terakhir gagal", label-dx: -60pt),
    edge((507pt, 25pt), (750pt, 160pt), label: "setelah 10 detik", label-dx: 50pt),
    edge((700pt, 160pt), (480pt, 66pt), label: "1 percobaan gagal", label-dx: -40pt, label-dy: 12pt),
    edge((684pt, 200pt), (180pt, 200pt), label: "3 percobaan berturut-turut sukses"),
  )
  #bullets(size: 13pt,
    [Selama OPEN, transfer tidak menunggu _timeout_ sama sekali. Panggilan langsung gagal dengan `circuitbreaker.ErrOpen`, dan account mendapat jeda untuk kembali aktif.],
    [Setiap perubahan _state_ dicatat di log, sehingga transisi CLOSED, OPEN, dan HALF-OPEN dapat diamati langsung di Lab 3.],
  )
]

#slide(kicker: "Pola 3", title: [Kegagalan yang dihitung oleh _circuit breaker_])[
  #two-col(
    card("Dihitung sebagai kegagalan", accent: red)[
      - _Error_ transport: koneksi ditolak, koneksi terputus
      - _Timeout_ per percobaan
      - HTTP 5xx, termasuk 503 dari _fault injection_
    ],
    card("Dihitung sebagai sukses", accent: gold.darken(15%))[
      - HTTP 2xx
      - HTTP 4xx: rekening tidak ditemukan (404), saldo tidak cukup (422)
    ],
  )
  #v(10pt)
  #note[HTTP 4xx berarti account sehat dan menjawab sesuai aturan bisnis. Bila 4xx ikut dihitung, nasabah yang berulang kali mencoba transfer dengan saldo kurang dapat membuka _circuit breaker_ dan menghentikan transfer semua nasabah lain.]
  #v(4pt)
  #note(kind: "tip")[Cukup satu _circuit breaker_ untuk seluruh account service karena debit dan credit berada pada service yang sama. Bila account mati, keduanya ikut gagal.]
]

#slide(kicker: "failsafe-go", title: [Pengaruh urutan _policy_ terhadap perilaku])[
  #two-col(ratio: (1fr, 1fr),
    [
      #layer-box("retry policy", navy)[
        #layer-box("circuit breaker", amber)[
          #layer-box("timeout 2 detik", gold.darken(20%))[
            #align(center, text(size: 12pt, weight: "bold")[HTTP POST ke account])
          ]
        ]
      ]
    ],
    [
      #bullets(size: 13pt,
        [*_Timeout_ di dalam.* Setiap percobaan mendapat jatah 2 detik sendiri, tidak berbagi dengan percobaan sebelumnya.],
        [*_Circuit breaker_ di tengah.* Setiap percobaan, termasuk yang berakhir _timeout_, dicatat oleh _circuit breaker_.],
        [*_Retry_ di luar.* Bila _circuit breaker_ sudah OPEN, _retry_ dihentikan seketika karena percobaan berikutnya pasti ditolak.],
      )
    ],
  )
  #v(8pt)
  #note(kind: "warn")[Bila _timeout_ diletakkan di luar _retry_, batas 2 detik berlaku untuk seluruh percobaan sekaligus, dan _circuit breaker_ tidak pernah melihat _timeout_ sebagai kegagalan.]
]

#code-slide(kicker: "failsafe-go", title: [_Round tripper_ dengan tiga _policy_],
  side: [
    - `failsafehttp` membungkus `http.RoundTripper`, sehingga kode pemanggil tetap menggunakan `http.Client` biasa
    - Urutan argumen mengikuti urutan _wrapping_: _retry_, _circuit breaker_, _timeout_
    - Parameter disimpan di kode dalam struct `Settings`. Perubahan nilainya melalui _review_ dan _test_ seperti perubahan kode lain
  ],
)[
```go
breaker := circuitbreaker.NewBuilder[*http.Response]().
    HandleIf(countsAsFailure).
    WithFailureThresholdRatio(5, 10).
    WithDelay(10 * time.Second).
    WithSuccessThreshold(3).
    OnStateChanged(logStateChange).
    Build()

retry := retrypolicy.NewBuilder[*http.Response]().
    HandleIf(notProcessed).
    AbortOnErrors(circuitbreaker.ErrOpen).
    WithMaxRetries(3).
    WithBackoff(100*time.Millisecond, time.Second).
    WithJitterFactor(0.25).
    Build()

rt := failsafehttp.NewRoundTripper(nil,
    retry, breaker, timeout.New[*http.Response](2*time.Second))
client := &http.Client{Transport: rt}
```
]

#code-slide(kicker: "failsafe-go", title: "Klasifikasi kegagalan ditulis sebagai fungsi",
  side: [
    - `notProcessed` menjawab pertanyaan _retry_: apakah _request_ terbukti belum diproses?
    - `countsAsFailure` menjawab pertanyaan _circuit breaker_: apakah account sedang bermasalah?
    - Kedua fungsi diuji terpisah dengan `httptest`, tanpa account sungguhan
  ],
)[
```go
// Retry hanya bila request terbukti belum diproses.
// Timeout TIDAK di-retry: debit belum idempotent,
// account bisa saja sudah mendebit.
func notProcessed(resp *http.Response, err error) bool {
    if err != nil {
        var opErr *net.OpError
        return errors.As(err, &opErr) && opErr.Op == "dial"
    }
    return resp.StatusCode == http.StatusServiceUnavailable
}

// 4xx = account sehat yang menolak secara bisnis.
func countsAsFailure(resp *http.Response, err error) bool {
    return err != nil || resp.StatusCode >= 500
}
```
]

#slide(kicker: "Simulasi", title: [_Fault injection_ pada account service])[
  #table(
    columns: (auto, 1fr, 1.1fr),
    [Perintah], [Efek pada Account], [Yang Diamati di Transfer],
    [`make fault-slow`], [Setiap _request_ ke `/accounts*` ditunda 3 detik], [_Timeout_ 2 detik, tanpa _retry_, _circuit breaker_ terbuka setelah 5 kegagalan],
    [`make fault-error RATE=0.2`], [Seperlima _request_ dijawab 503 tanpa diproses], [_Retry_ dengan _backoff_, sebagian besar transfer tetap berhasil],
    [`make fault-error RATE=0.5`], [Separuh _request_ dijawab 503 tanpa diproses], [_Circuit breaker_ terbuka setelah dua atau tiga transfer, karena setiap _retry_ ikut dihitung],
    [`make fault-error RATE=1`], [Semua _request_ dijawab 503], [_Retry_ habis, _circuit breaker_ terbuka, transfer langsung gagal],
    [`make fault-clear`], [Account kembali normal], [HALF-OPEN setelah 10 detik, lalu CLOSED setelah 3 sukses],
    [`make breaker`], [Tidak ada], [`{"account":"closed|open|half-open"}`],
  )
  #v(8pt)
  #note[_Fault injection_ hanya berlaku untuk `/accounts*`. _Endpoint_ `/healthz`, `/readyz`, dan `/admin/fault` tetap cepat, sehingga kondisi account tetap dapat diperiksa selama simulasi.]
]

#slide(kicker: "Perilaku", title: [Transfer ketika _circuit breaker_ terbuka])[
  #flow(
    node("channel", kind: "ext", width: 100pt),
    arr(label: "POST /transfers", length: 110pt),
    node("transfer", sub: "breaker OPEN", width: 130pt),
    arr(label: "ErrOpen, < 1 ms", length: 120pt, dash: "dashed", color: red),
    node("account", sub: "tidak dipanggil", kind: "ext", width: 130pt),
  )
  #v(12pt)
  #two-col(
    [
      #bullets(size: 13.5pt,
        [Transfer dicatat dengan status `FAILED` beserta alasannya.],
        [Channel menerima HTTP 503 seketika, tidak menunggu 2 detik. Debit belum diterapkan, jadi _request_ aman diulang nanti.],
        [`GET /debug/circuit-breaker` pada transfer menampilkan _state_ saat itu.],
      )
    ],
    [
      #note(kind: "warn")[_Circuit breaker_ dapat terbuka di antara debit dan credit. Debit sudah diterapkan, credit ditolak, dan uang tertahan di luar kedua rekening. Channel menerima 502, tidak 503, karena _request_ ini tidak boleh diulang. Celah ini sudah ada sejak Lab 2 dan baru ditutup oleh saga di Lab 5.]
    ],
  )
]

#slide(kicker: "Perilaku", title: [Kode HTTP `POST /transfers` di Lab 3 dan Lab 4])[
  #table(
    columns: (1.5fr, auto, 1.4fr),
    [Hasil Transfer], [HTTP], [Arti bagi Channel],
    [Transfer selesai (`COMPLETED`)], [`201`], [Selesai],
    [Debit ditolak: rekening sumber tidak ada atau saldo kurang], [`422`], [Tidak ada mutasi. Mengulang dengan data yang sama memberi hasil yang sama],
    [_Circuit breaker_ terbuka saat debit], [`503`], [Tidak ada mutasi, aman diulang setelah jeda],
    [Debit gagal karena account _error_ atau _timeout_], [`502`], [Hasil debit tidak pasti, periksa `GET /transfers/{id}`],
    [Credit gagal setelah debit, termasuk rekening tujuan tidak ada dan _breaker_ yang baru terbuka], [`502`], [Debit sudah diterapkan dan tidak boleh diulang. Log `ERROR` mencatat bahwa _reversal_ harus dilakukan manual],
  )
  #v(8pt)
  #note[Semua kegagalan credit setelah debit dibungkus `ErrCreditFailed` di `Service.Execute`, dan _handler_ memeriksanya sebelum kasus `422` dan `503`. Skenario demo yang selalu dapat diulang: transfer ke `to_account` yang tidak terdaftar menghasilkan `502` dengan `failure_reason` `credit failed after debit: ... account not found`.]
]

#slide(kicker: "Lab 3", title: "Resiliency pada panggilan transfer ke account")[
  #two-col(ratio: (1.2fr, 1fr),
    [
      #card("Tujuan")[
        Transfer tetap cepat merespons ketika account lambat atau mati, dan tidak pernah mendebit dua kali akibat _retry_.
      ]
      #v(8pt)
      #card("Yang dikerjakan")[
        - _Timeout_ 2 detik per percobaan di `transfer/internal/accountclient`
        - _Retry_ maksimal 3 kali dengan _backoff_ 100 ms hingga 1 detik dan _jitter_, hanya untuk _dial error_ dan 503
        - _Circuit breaker_ 5 dari 10, jeda 10 detik, 3 sukses untuk menutup kembali
        - `GET /debug/circuit-breaker` dan log perubahan _state_
        - _Unit test_ dengan `httptest`: _retry_ pada 503, tanpa _retry_ pada _timeout_, _circuit breaker_ menolak dengan cepat
      ]
    ],
    [
      #card("Rujukan", accent: gold.darken(15%))[
        - Panduan lab: bab *Lab 3*
        - Titik awal: `git checkout lab-02`
        - Hasil akhir: _checkpoint_ `lab-03`
        - Waktu: ± 60 menit
      ]
      #v(8pt)
      #note(kind: "tip")[Jalankan `make breaker` di terminal terpisah setiap beberapa detik selama simulasi untuk melihat transisi _state_.]
    ],
  )
]

#slide(kicker: "Lab 3", title: "Skenario pengamatan di akhir lab")[
  #enum(
    [`make fault-error RATE=0.2`, lalu kirim beberapa transfer. Log transfer menampilkan `retrying account call`, dan sebagian besar transfer berstatus `COMPLETED`.],
    [`make fault-slow`, lalu kirim 5 transfer. Setiap transfer gagal setelah ± 2 detik tanpa _retry_, kemudian log menampilkan `circuit breaker state changed` dari `closed` ke `open`.],
    [Kirim transfer berikutnya. Jawaban 503 datang seketika dan account tidak menerima _request_ apa pun.],
    [`make fault-clear`, tunggu 10 detik, lalu kirim 3 transfer. _State_ berpindah ke `half-open`, kemudian `closed`.],
    [Bandingkan saldo rekening dengan daftar transfer yang `COMPLETED`. Tidak ada debit ganda.],
  )
  #v(6pt)
  #note[Hasil langkah 5 menjadi bukti bahwa keputusan tidak me-_retry_ _timeout_ sudah tepat untuk debit yang belum _idempotent_.]
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "02", title: "gRPC untuk Komunikasi Internal",
  subtitle: [Kontrak protobuf, _code generation_, _unary call_, _error handling_, dan _interceptor_])

#slide(kicker: "Konsep", title: "Kebutuhan panggilan internal berbeda dengan API channel")[
  #two-col(
    card("API untuk channel")[
      - Dikonsumsi aplikasi _mobile_, web, dan pihak eksternal
      - Client beragam dan tidak dikendalikan tim yang sama
      - Butuh format yang mudah dibaca dan diuji: JSON melalui REST
      - Dokumentasi dan versi API dikelola untuk pihak luar
    ],
    card("Panggilan internal antarservice", accent: gold.darken(15%))[
      - Volume tinggi, karena satu _request_ channel memicu beberapa panggilan internal
      - Kedua sisi dikembangkan oleh tim internal
      - Kontrak harus tetap cocok setiap kali salah satu sisi berubah
      - Butuh satu titik terpusat untuk autentikasi, log, dan resiliency
    ],
  )
  #v(10pt)
  #note[Pola penempatan di studi kasus mengikuti praktik umum industri: gRPC antarservice internal, REST untuk API yang dikonsumsi channel dan pihak eksternal.]
]

#slide(kicker: "Studi kasus", title: "Penempatan REST dan gRPC setelah Lab 4")[
  #diagram(height: 230pt,
    at(0pt, 90pt, node("channel", sub: "mobile / web", kind: "ext", width: 130pt)),
    at(300pt, 20pt, node("transfer", sub: "HTTP :28082", width: 140pt)),
    at(300pt, 160pt, node("account", sub: "HTTP :28081", width: 140pt)),
    at(640pt, 90pt, node("account", sub: "gRPC :29091", width: 150pt)),
    edge((130pt, 108pt), (300pt, 48pt), label: "REST /transfers", label-dx: -20pt),
    edge((130pt, 132pt), (300pt, 188pt), label: "REST /accounts", label-dx: -20pt, label-dy: 8pt),
    edge((440pt, 48pt), (640pt, 108pt), label: "gRPC Debit, Credit", label-dx: 20pt),
    edge((440pt, 188pt), (640pt, 132pt), label: "satu proses yang sama", label-dx: 40pt, label-dy: 16pt, dash: "dashed", both: true),
  )
  #bullets(size: 13pt,
    [Account melayani dua _port_ dalam satu proses: REST untuk channel (buka rekening, cek saldo) dan gRPC untuk service internal (`GetAccount`, `Debit`, `Credit`).],
    [_Endpoint_ REST debit dan credit di account dihapus. Mutasi saldo hanya dapat dilakukan melalui gRPC oleh service internal.],
  )
]

#slide(kicker: "Konsep", title: "Komponen gRPC")[
  #grid(columns: (1fr, 1fr), column-gutter: 16pt, row-gutter: 14pt,
    card("Kontrak protobuf")[
      _File_ `.proto` mendefinisikan service, method, dan struktur data. _File_ ini menjadi acuan tunggal bagi server dan client.
    ],
    card([_Code generation_])[
      `protoc` menghasilkan kode Go yang _type-safe_. Ketidakcocokan nama method dan tipe tertangkap saat kompilasi.
    ],
    card([HTTP/2 dan _encoding_ biner])[
      Satu koneksi melayani banyak panggilan sekaligus. Ukuran data lebih kecil dan _parsing_ lebih cepat dibandingkan JSON.
    ],
    card([_Interceptor_])[
      Fungsinya seperti _middleware_, tetapi untuk setiap panggilan gRPC. Log, autentikasi, _fault injection_, dan resiliency cukup ditulis sekali untuk semua method.
    ],
  )
  #v(10pt)
  #note[gRPC mendukung empat jenis panggilan: _unary_, _server streaming_, _client streaming_, dan _bidirectional streaming_. Studi kasus hanya menggunakan _unary_ (satu _request_, satu _response_), jenis yang paling sering digunakan antarservice.]
]

#code-slide(kicker: "Kontrak", title: [Cuplikan `account/v1/account.proto`],
  side: [
    - `package account.v1` memuat versi di nama _package_. Perubahan yang merusak kompatibilitas masuk ke `v2`
    - Yang dikirim lewat jaringan hanya nomor _field_ (`= 1`, `= 2`), tanpa nama _field_
    - Setiap RPC memiliki _message_ _request_ dan _response_ sendiri, sehingga masing-masing dapat ditambah _field_ tanpa memengaruhi yang lain
    - Nominal uang ditulis sebagai _string_ desimal, alasannya di _slide_ berikut
  ],
)[
```proto
syntax = "proto3";

package account.v1;

option go_package = ".../studi-kasus/proto/gen/account/v1;accountv1";

service AccountService {
  rpc GetAccount(GetAccountRequest) returns (GetAccountResponse);
  rpc Debit(DebitRequest) returns (DebitResponse);
  rpc Credit(CreditRequest) returns (CreditResponse);
}

// Format: digits with at most 2 decimal places
// ("150000.50"), no sign, no exponent; anything
// else is INVALID_ARGUMENT, never rounded.
message DebitRequest {
  string number = 1;
  string amount = 2;
  string reference = 3;
}
```
]

#slide(kicker: "Kontrak", title: [Nominal uang tidak dikirim sebagai `double`])[
  #two-col(
    [
```go
var a, b float64 = 0.1, 0.2
fmt.Println(a + b)
// 0.30000000000000004

x, _ := decimal.NewFromString("0.1")
y, _ := decimal.NewFromString("0.2")
fmt.Println(x.Add(y))
// 0.3
```
    ],
    [
      #bullets(size: 13.5pt,
        [`double` dan `float` adalah bilangan biner berpresisi terbatas. Nilai 0,1 tidak dapat disimpan secara tepat.],
        [Selisih kecil tersebut menumpuk pada penjumlahan saldo dan membuat rekonsiliasi tidak cocok.],
        [Kontrak mengirim _string_ desimal. Server dan client mengubahnya menjadi `decimal.Decimal` (shopspring/decimal), sama dengan kolom `numeric(19,2)` di database.],
        [Format yang diterima: angka dengan maksimal 2 desimal, tanpa tanda +/- dan tanpa eksponen, kurang dari $10^17$. Selain itu ditolak dengan `codes.InvalidArgument` (REST: `400`).],
        [Nilai `100.005` ditolak, tidak dibulatkan. Tanpa pemeriksaan ini, `numeric(19,2)` membulatkannya menjadi `100.01` tanpa _error_ maupun peringatan.],
      )
    ],
  )
]

#slide(kicker: "Code generation", title: [Dari `.proto` menjadi kode Go])[
  #flow(
    node("account.proto", sub: "kontrak", kind: "infra", width: 130pt),
    arr(label: "protoc", length: 80pt),
    node("protoc-gen-go", sub: "struct message", kind: "infra", width: 140pt),
    arr(length: 50pt),
    node("account.pb.go", kind: "infra", width: 140pt),
  )
  #flow(
    box(width: 130pt),
    box(width: 80pt),
    node("protoc-gen-go-grpc", sub: "server + client", kind: "infra", width: 140pt),
    arr(length: 50pt),
    node("account_grpc.pb.go", kind: "infra", width: 140pt),
  )
  #v(8pt)
  #bullets(size: 13pt,
    [Kontrak berada di modul tersendiri, `studi-kasus/proto`. Kode hasil _generate_ ada di `proto/gen/account/v1` (_package_ `accountv1`) dan ikut di-_commit_.],
    [`make -C proto generate` menjalankan `protoc` dengan kedua _plugin_. Pastikan `$(go env GOPATH)/bin` ada di `PATH`.],
    [Modul account dan transfer mengimpor modul proto dengan _directive_ `replace` ke `../proto`, sehingga `go mod tidy` dan _build_ Docker tetap berjalan.],
  )
]

#code-slide(kicker: "Server", title: "Account melayani HTTP dan gRPC sekaligus",
  side: [
    - `GRPC_ADDR` wajib diisi. Bila kosong, account berhenti saat _startup_ dan log _error_-nya menyebut nama variabel tersebut
    - _Health service_ standar gRPC (`grpc.health.v1`) tidak memeriksa database, jadi statusnya `SERVING` sejak _startup_ hingga _shutdown_. _Readiness_ _pod_ tetap diperiksa melalui HTTP `/readyz`
    - _Reflection_ memungkinkan client generik membaca daftar method tanpa _file_ `.proto`
    - HTTP dan gRPC berjalan di _goroutine_ terpisah dalam satu proses
    - `notAccountService` bernilai `true` untuk method di luar `AccountService` (_health_, _reflection_), sehingga method tersebut tidak terkena _fault injection_. Di kode Lab 4 fungsi ini ditulis langsung sebagai argumen, dan variabel dengan nama ini baru muncul di Lab 7
  ],
)[
```go
grpcSrv := grpc.NewServer(grpc.ChainUnaryInterceptor(
    interceptor.Logging(log),
    faults.UnaryServerInterceptor(notAccountService),
))
accountv1.RegisterAccountServiceServer(grpcSrv,
    account.NewGRPCServer(store, log))
healthSrv := health.NewServer()
healthpb.RegisterHealthServer(grpcSrv, healthSrv)
reflection.Register(grpcSrv)

lis, err := net.Listen("tcp", cfg.GRPCAddr)
if err != nil {
    return fmt.Errorf("listen on GRPC_ADDR %s: %w",
        cfg.GRPCAddr, err)
}
go func() { errCh <- grpcSrv.Serve(lis) }()
```
]

#slide(kicker: "Error handling", title: [Pemetaan _error_ ke _status code_ gRPC])[
  #table(
    columns: (1.1fr, auto, 1.3fr),
    [Kondisi di Account], [_Status Code_], [Tindakan Pemanggil],
    [Rekening tidak ditemukan], [`NotFound`], [Transfer gagal, tidak di-_retry_],
    [Saldo tidak cukup], [`FailedPrecondition`], [Transfer gagal, tidak di-_retry_],
    [Nominal atau nomor rekening tidak valid], [`InvalidArgument`], [Transfer gagal, tidak di-_retry_],
    [_Fault injection_ menolak sebelum memproses], [`Unavailable`], [Aman di-_retry_],
    [_Deadline_ pemanggil terlampaui saat _query_ masih berjalan], [`DeadlineExceeded`], [Mutasi mungkin sudah diterapkan, tidak di-_retry_ (hingga Lab 5)],
    [Pemanggil membatalkan panggilan], [`Canceled`], [Sama dengan `DeadlineExceeded`],
    [_Error_ lain yang tidak terduga], [`Internal`], [Tidak di-_retry_, dihitung oleh _circuit breaker_],
  )
  #v(8pt)
  #note[_Status code_ setara dengan HTTP _status_ pada REST. Kode `NotFound` dan `FailedPrecondition` adalah jawaban bisnis dari service yang sehat, sedangkan `Unavailable` dan `DeadlineExceeded` menandakan service yang bermasalah. Account mencatat `DeadlineExceeded` dan `Canceled` sebagai `WARN` `caller gave up before the request finished`, tidak sebagai `ERROR`.]
]

#code-slide(kicker: "Error handling", title: [_Status code_ di sisi server dan client],
  side: [
    - Server mengubah _error_ domain menjadi `status.Error` dengan kode yang sesuai. _Context_ yang berakhir dipetakan oleh `status.FromContextError`
    - Client membaca kode dengan `status.Code(err)` lalu mengembalikan _error_ domain transfer yang sama seperti versi REST
    - Kode di _package_ `transfer` tidak berubah. Hanya `accountclient` yang diganti
  ],
)[
```go
// account: error domain -> status gRPC
switch {
case errors.Is(err, context.Canceled),
    errors.Is(err, context.DeadlineExceeded):
    st := status.FromContextError(err)
    s.log.Warn("caller gave up before the request finished",
        "code", st.Code().String(), "error", err)
    return st.Err()
case errors.As(err, &v): // ValidationError
    return status.Error(codes.InvalidArgument, v.describe())
case errors.Is(err, ErrNotFound):
    return status.Error(codes.NotFound, err.Error())
case errors.Is(err, ErrInsufficientFunds):
    return status.Error(codes.FailedPrecondition, err.Error())
default:
    s.log.Error("grpc request failed", "error", err)
    return status.Error(codes.Internal, "internal error")
}

// transfer: status gRPC -> error domain
switch status.Code(err) {
case codes.NotFound:
    return fmt.Errorf("%s %s: %w", kind, number,
        transfer.ErrAccountNotFound)
// ...
```
]

#slide(kicker: [_Interceptor_], title: [_Interceptor_ membungkus setiap panggilan gRPC])[
  #diagram(height: 130pt,
    at(0pt, 30pt, node("transfer", sub: "Debit()", width: 120pt)),
    at(180pt, 30pt, node("client interceptor", sub: "retry + breaker", kind: "infra", width: 150pt)),
    at(400pt, 30pt, node("server interceptor", sub: "log, fault", kind: "infra", width: 150pt)),
    at(620pt, 30pt, node("handler", sub: "account.Debit", width: 130pt)),
    edge((120pt, 58pt), (180pt, 58pt)),
    edge((330pt, 58pt), (400pt, 58pt), label: "HTTP/2"),
    edge((550pt, 58pt), (620pt, 58pt)),
  )
  #two-col(
    card([_Unary server interceptor_])[
      - Dipasang dengan `grpc.ChainUnaryInterceptor`, dijalankan berurutan
      - Log setiap panggilan: method, _status code_, durasi
      - _Fault injection_ yang sama dengan versi REST, menjawab `codes.Unavailable`
      - Lab 7 menambahkan pemeriksaan JWT di posisi yang sama
    ],
    card([_Unary client interceptor_], accent: gold.darken(15%))[
      - Dipasang saat membuat koneksi dengan `grpc.WithUnaryInterceptor`
      - _Policy_ failsafe-go dari Lab 3 dipindahkan ke sini
      - Berlaku untuk `GetAccount`, `Debit`, dan `Credit` tanpa mengubah kode pemanggil
    ],
  )
]

#code-slide(kicker: [_Interceptor_], title: [Bentuk _unary server interceptor_],
  side: [
    - `handler` adalah method service yang sesungguhnya
    - Kode sebelum pemanggilan `handler` berjalan sebelum method, sedangkan kode sesudahnya dapat membaca hasil method
    - `info.FullMethod` berisi nama lengkap, contoh `/account.v1.AccountService/Debit`
    - Jawaban bisnis dicatat `INFO`, kode lain yang gagal dicatat `WARN`
    - Pola yang sama dengan _middleware_ `http.Handler` dari Hari 1
  ],
)[
```go
func Logging(log *slog.Logger) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any,
        info *grpc.UnaryServerInfo,
        handler grpc.UnaryHandler) (any, error) {

        start := time.Now()
        resp, err := handler(ctx, req)
        code := status.Code(err)
        level := slog.LevelInfo
        switch code {
        case codes.OK, codes.NotFound,
            codes.FailedPrecondition, codes.InvalidArgument:
        default:
            level = slog.LevelWarn
        }
        log.Log(ctx, level, "grpc request",
            "method", info.FullMethod, "code", code.String(),
            "duration_ms", time.Since(start).Milliseconds())
        return resp, err
    }
}
```
]

#slide(kicker: "Resiliency", title: [_Policy_ Lab 3 dalam bentuk _status code_ gRPC])[
  #table(
    columns: (auto, auto, auto, 1fr),
    [_Status Code_], [_Retry_], [_Circuit Breaker_], [Alasan],
    [`Unavailable`], [Ya], [Gagal], [Account menolak sebelum memproses, atau koneksi tidak terbentuk],
    [`DeadlineExceeded`], [Tidak (hingga Lab 5)], [Gagal], [Debit mungkin sudah diterapkan],
    [`Internal`, `Unknown`], [Tidak], [Gagal], [Account bermasalah, status mutasi tidak diketahui],
    [`NotFound`, `FailedPrecondition`, `InvalidArgument`], [Tidak], [Sukses], [Jawaban bisnis dari service yang sehat],
  )
  #v(10pt)
  #two-col(
    note[Parameter _policy_ tetap sama dengan Lab 3: _timeout_ 2 detik per percobaan, maksimal 3 _retry_ dengan _backoff_ 100 ms hingga 1 detik, _circuit breaker_ 5 dari 10.],
    note(kind: "tip")[`GET /debug/circuit-breaker` dan `make fault-*` tetap berfungsi, sehingga skenario Lab 3 dapat diulang pada jalur gRPC.],
  )
  #v(6pt)
  #note(kind: "warn")[`Unavailable` juga muncul bila koneksi terputus setelah _request_ terkirim. Risiko debit ganda ini sengaja dibiarkan sampai Lab 5 membuat mutasi account menjadi _idempotent_.]
]

#code-slide(kicker: "Client", title: "Koneksi gRPC di transfer service",
  side: [
    - `ACCOUNT_GRPC_ADDR` menggantikan `ACCOUNT_SERVICE_URL` dan wajib diisi
    - `grpc.NewClient` tidak langsung membuka koneksi. Koneksi dibuat saat panggilan pertama dan dibuat ulang otomatis bila terputus, dengan jeda maksimal 5 detik
    - `insecure.NewCredentials()` hanya untuk lab. Di _production_, koneksi antarservice wajib TLS
  ],
)[
```go
// accountclient.New
resilience := failsafegrpc.NewUnaryClientInterceptor[any](
    retry, breaker, timeout.New[any](s.AttemptTimeout))

conn, err := grpc.NewClient(target,
    grpc.WithTransportCredentials(insecure.NewCredentials()),
    grpc.WithUnaryInterceptor(resilience),
    grpc.WithConnectParams(grpc.ConnectParams{
        Backoff: backoff.Config{BaseDelay: time.Second,
            Multiplier: 1.6, Jitter: 0.2,
            MaxDelay: 5 * time.Second},
        MinConnectTimeout: 5 * time.Second,
    }),
)

// Deadline per percobaan berasal dari policy timeout
// dan ikut terkirim ke server (header grpc-timeout).
_, err := c.api.Debit(ctx, &accountv1.DebitRequest{
    Number: number, Amount: amount.String(),
    Reference: reference})
return mapError("debit", number, err)
```
]

#slide(kicker: "Konsep", title: [_Deadline_ ikut terkirim ke server])[
  #flow(
    node("transfer", sub: "deadline 2 detik", width: 150pt),
    arr(label: "grpc-timeout: 2S", length: 150pt),
    node("account", sub: "ctx.Done() setelah 2 detik", width: 190pt),
    arr(label: "query", length: 80pt),
    node("db-account", kind: "db", width: 110pt, height: 60pt),
  )
  #v(12pt)
  #bullets(
    [Pada REST, _deadline_ pemanggil tidak dikirim ke server. Server baru tahu pemanggil berhenti menunggu ketika koneksi diputus, dan hanya bila kode server memeriksa `r.Context()`.],
    [Pada gRPC, _deadline_ dari `context` pemanggil dikirim sebagai _header_ `grpc-timeout`. `ctx` di sisi server ikut berakhir pada waktu yang sama.],
    [Account meneruskan `ctx` tersebut ke pgx, sehingga _query_ yang tidak lagi ditunggu dibatalkan dan koneksi database segera dilepas.],
  )
]

#slide(kicker: "Kontrak", title: "Kompatibilitas perubahan kontrak protobuf")[
  #two-col(
    card("Aman (kompatibel)", accent: gold.darken(15%))[
      - Menambah _field_ baru dengan nomor baru
      - Menambah method baru pada service
      - Menambah nilai baru pada `enum`
      - Client lama tetap berjalan: _field_ yang tidak dikenal diabaikan
    ],
    card("Merusak kompatibilitas", accent: red)[
      - Mengubah nomor atau tipe _field_ yang sudah ada
      - Menggunakan kembali nomor _field_ yang sudah dihapus
      - Mengganti nama atau menghapus method
      - Sebagai gantinya, tandai nomor lama dengan `reserved` atau buat _package_ baru `account.v2`
    ],
  )
  #v(10pt)
  #note[Kompilasi hanya menangkap nama method atau _field_ yang diganti atau dihapus, pada service yang di-_build_ dari kontrak baru. Nomor _field_ yang diubah atau digunakan kembali tidak menimbulkan _compile error_, tetapi merusak data antara versi lama dan versi baru yang berjalan bersamaan. Karena itu nomor lama ditandai `reserved`, dan perubahan kontrak diperiksa dengan _breaking-change tool_ atau _review_.]
]

#code-slide(kicker: "Testing", title: [_Unit test_ gRPC dengan `bufconn`],
  side: [
    - `bufconn` menyediakan _listener_ di memori. Server dan client gRPC sungguhan berjalan tanpa membuka _port_
    - _Fake server_ di _test_ dapat mengembalikan `codes.Unavailable` atau menunda jawaban
    - Skenario _test_ Lab 3 diulang: _retry_ pada `Unavailable`, tanpa _retry_ pada `DeadlineExceeded`, _circuit breaker_ terbuka
  ],
)[
```go
fake := &fakeAccountService{answer: answer}
lis := bufconn.Listen(1 << 20)
srv := grpc.NewServer()
accountv1.RegisterAccountServiceServer(srv, fake)
go func() { _ = srv.Serve(lis) }()
t.Cleanup(srv.Stop)

// Client yang sama dengan production, ditambah
// dialer ke listener di memori.
c, err := New("passthrough:///bufnet", s, log,
    grpc.WithContextDialer(
        func(ctx context.Context, _ string) (net.Conn, error) {
            return lis.DialContext(ctx)
        }))
```
]

#slide(kicker: "Lab 4", title: "Panggilan transfer ke account berpindah ke gRPC")[
  #two-col(ratio: (1.2fr, 1fr),
    [
      #card("Tujuan")[
        Kontrak antara transfer dan account diperiksa saat kompilasi, dan resiliency Lab 3 tetap berlaku melalui _interceptor_.
      ]
      #v(8pt)
      #card("Yang dikerjakan")[
        - Modul `proto` dengan `account/v1/account.proto` dan kode hasil _generate_
        - Server gRPC di account (`GRPC_ADDR`): pemetaan _error_, _health_, _reflection_, _interceptor_ log dan _fault injection_
        - _Endpoint_ REST debit dan credit di account dihapus
        - Client gRPC di transfer (`ACCOUNT_GRPC_ADDR`) dengan _client interceptor_ failsafe-go
        - _Unit test_ dengan `bufconn`
      ]
    ],
    [
      #card("Rujukan", accent: gold.darken(15%))[
        - Panduan lab: bab *Lab 4*
        - Titik awal: `git checkout lab-03`
        - Hasil akhir: _checkpoint_ `lab-04`
        - Waktu: ± 90 menit
      ]
      #v(8pt)
      #note(kind: "tip")[Verifikasi akhir: transfer yang dikirim channel melalui REST tetap berhasil, dan `make fault-error RATE=1` kembali membuka _circuit breaker_, kali ini melalui `codes.Unavailable`.]
    ],
  )
]

// ════════════════════════════════════════════════════════════════════════════
#section-slide(number: "03", title: "Konsistensi Data Terdistribusi",
  subtitle: [Alasan 2PC dihindari, saga, dan _idempotency key_ untuk operasi finansial])

#slide(kicker: "Masalah", title: "Transfer mengubah data di dua database")[
  #flow(
    node("transfer", sub: "db-transfer", width: 130pt),
    arr(label: "1. Debit A: sukses", length: 150pt),
    node("account A", sub: "saldo berkurang", width: 140pt),
  )
  #flow(
    box(width: 130pt),
    arr(label: "2. Credit B: gagal", length: 150pt, color: red, dash: "dashed"),
    node("account B", sub: "saldo tetap", kind: "ext", width: 140pt),
  )
  #v(8pt)
  #bullets(size: 13.5pt,
    [Debit dan credit berjalan sebagai dua transaksi database terpisah di dua service yang berbeda. Tidak ada `BEGIN ... COMMIT` yang mencakup keduanya.],
    [Bila credit gagal setelah debit berhasil, saldo rekening A sudah berkurang tetapi rekening B tidak bertambah. Transfer di akhir Lab 2 hanya mencatat log untuk koreksi manual.],
    [Demo: transfer ke nomor rekening tujuan yang tidak ada. Debit berhasil, credit dijawab `NotFound`, channel menerima `502`, dan saldo sumber tidak kembali.],
  )
]

#slide(kicker: "Konsep", title: [Alasan _distributed transaction_ (2PC) dihindari])[
  #two-col(ratio: (1fr, 1.2fr),
    [
      #diagram(height: 220pt,
        at(110pt, 0pt, node("coordinator", sub: "prepare / commit", kind: "infra", width: 150pt)),
        at(0pt, 150pt, node("db-transfer", kind: "db", width: 120pt, height: 60pt)),
        at(250pt, 150pt, node("db-account", kind: "db", width: 120pt, height: 60pt)),
        edge((160pt, 56pt), (70pt, 150pt), both: true),
        edge((210pt, 56pt), (300pt, 150pt), both: true),
      )
    ],
    [
      #bullets(size: 13.5pt,
        [*_Tight coupling_.* Semua database yang terlibat harus mendukung protokol yang sama (XA) dan aktif bersamaan.],
        [*_Availability_ turun.* Database yang lambat menahan _lock_ di semua database hingga _coordinator_ memutuskan.],
        [*_Coordinator_ menjadi _single point of failure_.* Bila _coordinator_ mati setelah _prepare_, database yang terlibat tertahan menunggu.],
        [*Dukungan _tools_ minim.* Kafka, sebagian besar _managed database_ di _cloud_, dan API HTTP/gRPC tidak ikut dalam 2PC.],
      )
    ],
  )
]

#slide(kicker: "Konsep", title: "Saga sebagai rangkaian transaksi lokal dengan kompensasi")[
  #diagram(height: 250pt,
    at(0pt, 20pt, node("PENDING", sub: "transfer dicatat", kind: "infra", width: 150pt)),
    at(330pt, 20pt, node("DEBITED", sub: "saldo A berkurang", kind: "infra", width: 150pt)),
    at(660pt, 20pt, node("COMPLETED", sub: "saldo B bertambah", width: 160pt)),
    at(0pt, 180pt, node("FAILED", sub: "tidak ada mutasi", kind: "ext", width: 150pt)),
    at(330pt, 180pt, node("COMPENSATED", sub: "debit dikembalikan", kind: "broker", width: 160pt)),
    at(640pt, 180pt, node("COMPENSATION_FAILED", sub: "ditangani manual", kind: "ext", width: 200pt)),
    edge((150pt, 48pt), (330pt, 48pt), label: "debit sukses"),
    edge((480pt, 48pt), (660pt, 48pt), label: "credit sukses"),
    edge((75pt, 76pt), (75pt, 180pt), label: "debit gagal", label-dx: 50pt),
    edge((405pt, 76pt), (405pt, 180pt), label: "credit gagal, reversal sukses", label-dx: 80pt),
    edge((470pt, 76pt), (690pt, 180pt), label: "reversal gagal", label-dx: 70pt, label-dy: -14pt),
  )
  #bullets(size: 13pt,
    [Setiap langkah adalah transaksi lokal di satu service. Bila langkah berikutnya gagal, langkah yang sudah selesai dibatalkan dengan transaksi kompensasi, yaitu credit kembali ke rekening sumber (_reversal_).],
  )
]

#slide(kicker: "Konsep", title: [_Orchestration_ dan _choreography_])[
  #two-col(
    card([_Orchestration_])[
      - Satu service (_orchestrator_) menyimpan _state_ saga dan memanggil setiap langkah
      - Alur mudah dibaca di satu tempat dan mudah dilacak
      - _Orchestrator_ mengetahui semua service yang terlibat dalam saga
      - *Digunakan di studi kasus:* transfer sebagai _orchestrator_ untuk debit, credit, dan _reversal_
    ],
    card([_Choreography_], accent: amber)[
      - Tidak ada pengendali pusat. Setiap service bereaksi terhadap _event_ dari service lain
      - _Coupling_ antarservice lebih longgar
      - Alur tersebar di banyak service dan sulit dilacak ketika jumlah langkah bertambah
      - *Di studi kasus:* tidak ada saga _choreography_. Notification (Hari 3) hanya bereaksi terhadap _event_ transfer, dengan mekanisme seperti _choreography_ tetapi tanpa kompensasi
    ],
  )
  #v(10pt)
  #note(kind: "tip")[Untuk alur finansial dengan kompensasi, _orchestration_ umumnya lebih aman karena status setiap transfer dapat dibaca dari satu tabel.]
]

#slide(kicker: "Konsep", title: [Kompensasi berbeda dengan _rollback_])[
  #bullets(
    [_Rollback_ database menghapus jejak transaksi seolah tidak pernah terjadi. Kompensasi justru menambah mutasi baru: credit _reversal_ dengan _reference_ `<transfer_id>:reversal`.],
    [Kedua mutasi (debit asli dan _reversal_) tetap tercatat di riwayat mutasi rekening. Jejak ini dibutuhkan untuk audit dan rekonsiliasi.],
    [Di antara debit dan _reversal_, saldo rekening sumber sempat berkurang dan dapat terbaca oleh nasabah. Saga menjamin _eventual consistency_ (data akhirnya konsisten), tetapi tidak menjamin isolasi.],
    [Kompensasi juga dapat gagal. Status `COMPENSATION_FAILED` dicatat dengan log _error_ untuk ditangani manual, dan tidak boleh diabaikan.],
  )
  #v(4pt)
  #note(kind: "warn")[Setiap perubahan status saga dan _event_-nya ditulis dalam satu transaksi database (_transactional outbox_). Pola ini dibahas dan dipraktikkan di Hari 3.]
]

#slide(kicker: "Konsep", title: [_Idempotency key_ untuk operasi finansial])[
  #two-col(ratio: (1fr, 1fr),
    [
      #card("Masalah")[
        - Transfer mengirim debit, account memproses, jawabannya hilang karena _timeout_
        - Tanpa _idempotency_, _retry_ akan mendebit dua kali
        - Channel juga dapat mengirim ulang `POST /transfers` karena alasan yang sama
      ]
    ],
    [
      #card("Solusi di studi kasus", accent: gold.darken(15%))[
        - *Account (Lab 5).* _Unique constraint_ pada `(account_number, type, reference)`. _Reference_ yang sama tidak diterapkan ulang, account cukup mengembalikan kondisi rekening saat ini.
        - *Transfer (Lab 6).* _Header_ `Idempotency-Key` pada `POST /transfers`. _Key_ yang sama mengembalikan transfer asli dengan kode HTTP yang sama seperti _response_ pertama, sedangkan _key_ yang sama dengan isi berbeda ditolak (422).
      ]
    ],
  )
  #v(10pt)
  #note[Setelah debit dan credit _idempotent_, `DeadlineExceeded` aman di-_retry_. Pengecualian _timeout_ yang dipasang di Lab 3 dan Lab 4 dicabut di Lab 5.]
]

#slide(kicker: "Ringkasan", title: "Ringkasan pola Hari 2")[
  #table(
    columns: (auto, 1fr, 1.1fr),
    [Pola], [Masalah yang Diatasi], [Layak Digunakan Ketika],
    [_Timeout_], [Pemanggil menunggu tanpa batas], [Selalu, pada setiap panggilan jaringan],
    [_Retry_ + _backoff_], [Gangguan sesaat menggagalkan _request_], [Operasinya _idempotent_ atau terbukti belum diproses],
    [_Circuit breaker_], [Service yang mati terus dibebani dan pemanggil ikut lambat], [Panggilan sinkron ke service yang dapat gagal],
    [gRPC], [Kontrak internal hanya diperiksa saat program berjalan], [Panggilan internal bervolume tinggi antartim yang sama-sama mengendalikan kontrak],
    [Saga], [Transaksi lintas database tanpa 2PC], [Satu proses bisnis mengubah data di lebih dari satu service],
    [_Idempotency key_], [_Retry_ dan pengiriman ulang menggandakan mutasi], [Setiap operasi yang mengubah saldo],
  )
]

#slide(kicker: "Berikutnya", title: [Materi Hari 3])[
  #bullets(
    [*Kafka untuk _messaging_.* _Topic_, _partition_, _consumer group_, dan _at-least-once delivery_.],
    [*Lab 5.* Transfer menjadi saga dengan kompensasi, _event_ dikirim melalui _transactional outbox_, notification sebagai _consumer_.],
    [*Lab 6.* _Idempotent consumer_: _replay event_ tanpa notifikasi ganda, `Idempotency-Key` pada transfer.],
    [*Lab 7, _security_.* OAuth2 _client credentials_ dan validasi JWT pada REST _middleware_ dan gRPC _interceptor_.],
  )
  #v(8pt)
  #note(kind: "tip")[Pastikan _checkpoint_ `lab-04` berjalan di laptop masing-masing sebelum Hari 3 dimulai: `make test` lulus dan transfer melalui gRPC berhasil.]
]
