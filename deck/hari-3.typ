// Day 3 deck: Messaging, Konsistensi Data, dan Security (Lab 5 - Lab 7).
// Build: make CLIENT="..." Deck-Hari-3-Microservices-2026-10.pdf
#import "../_template/deck.typ": *

#show: deck.with(
  title: "Messaging, Konsistensi Data, dan Security",
  subtitle: [Kafka, saga dengan kompensasi, _transactional outbox_, _idempotency_, serta OAuth2 dan JWT antar service],
  day-label: "Hari 3",
  client: sys.inputs.at("client"),
  date: "28 Oktober 2026",
)

// ── Pembuka ────────────────────────────────────────────────────────────────

#slide(kicker: "Hari 3", title: "Agenda hari ini")[
  #table(
    columns: (auto, 1fr, auto),
    [Waktu], [Topik], [Format],
    [09:00 – 09:45], [Komunikasi asinkron dengan Kafka, _at-least-once delivery_, _transactional outbox_], [Presentasi + demo],
    [09:45 – 11:15], [*Lab 5*: transfer sebagai saga, event ke Kafka melalui outbox, notification sebagai _consumer_], [_Hands-on_],
    [11:30 – 12:30], [*Lab 6*: _idempotent consumer_ dan _Idempotency-Key_ pada API transfer], [_Hands-on_],
    [13:30 – 14:15], [OAuth2 _client credentials_, validasi JWT, posisi API _gateway_], [Presentasi + demo],
    [14:30 – 15:30], [*Lab 7*: _middleware_ JWT pada REST dan _interceptor_ JWT pada gRPC], [_Hands-on_],
    [15:30 – 16:30], [Pengantar _observability_: log, metrik, _trace_], [Presentasi + demo],
  )
]

#slide(kicker: "Posisi studi kasus", title: "Kondisi sistem di akhir Hari 2")[
  #flow(
    node("klien", sub: "REST", kind: "ext"),
    arr(label: "POST /transfers", length: 110pt),
    node("transfer", sub: ":28082"),
    arr(label: "gRPC", length: 90pt),
    node("account", sub: ":28081 / :29091"),
  )
  #v(6pt)
  #flow(
    node("db-transfer", kind: "db", width: 120pt, height: 60pt),
    h(330pt),
    node("db-account", kind: "db", width: 120pt, height: 60pt),
  )
  #v(10pt)
  #two-col(
    card("Sudah ada")[
      - Panggilan transfer ke account melalui gRPC
      - _Timeout_, _retry_, dan _circuit breaker_ di _interceptor_ klien
    ],
    card("Celah yang ditutup hari ini", accent: amber)[
      - Debit berhasil, credit gagal: saldo sumber hilang tanpa dikembalikan
      - Debit belum idempoten, jadi _timeout_ belum boleh di-_retry_
      - Siapa pun di jaringan internal dapat memanggil Debit
    ],
  )
]

// ── 01 Kafka ───────────────────────────────────────────────────────────────

#section-slide(number: "01", title: "Komunikasi asinkron dengan Kafka", subtitle: [_Topic_, _partition_, _consumer group_, dan jaminan pengiriman])

#slide(kicker: "Konsep", title: "Panggilan sinkron dan asinkron")[
  #two-col(
    card("Sinkron (REST, gRPC)")[
      - Pemanggil menunggu jawaban
      - Penerima harus aktif saat dipanggil
      - Cocok untuk langkah yang hasilnya langsung dibutuhkan, misalnya debit
      - Kegagalan langsung terlihat oleh pemanggil
    ],
    card([Asinkron (event melalui _broker_)], accent: amber)[
      - Pengirim menulis event lalu melanjutkan proses
      - Penerima boleh mati sementara, event tetap tersimpan di _broker_
      - Cocok untuk reaksi atas fakta yang sudah terjadi, misalnya notifikasi
      - Event bisa terkirim lebih dari sekali
    ],
  )
  #v(10pt)
  #note[Transfer tidak perlu menunggu notifikasi terkirim. Jika notification mati, transfer tetap selesai dan notifikasi dikirim setelah notification aktif kembali.]
]

#let offsets(label) = box(width: 300pt, height: 40pt)[
  #place(left + horizon, text(size: 11pt, weight: "bold", fill: amber.darken(25%), label))
  #for i in range(0, 6) {
    place(left + top, dx: 34pt + i * 42pt, box(width: 38pt, height: 34pt,
      fill: amber.lighten(88%), stroke: 1pt + amber, radius: 2pt,
      align(center + horizon, text(size: 10pt, fill: amber.darken(25%), str(i)))))
  }
]

#slide(kicker: "Kafka", title: [_Topic_, _partition_, dan _offset_])[
  #diagram(height: 210pt,
    at(0pt, 70pt, node("transfer", sub: "producer")),
    at(200pt, 0pt, offsets("P0")),
    at(200pt, 70pt, offsets("P1")),
    at(200pt, 140pt, offsets("P2")),
    at(560pt, 30pt, node("notification-1", sub: "membaca P0, P1", width: 140pt)),
    at(560pt, 120pt, node("notification-2", sub: "membaca P2", width: 140pt)),
    edge((120pt, 90pt), (200pt, 20pt)),
    edge((120pt, 98pt), (200pt, 90pt)),
    edge((120pt, 106pt), (200pt, 160pt)),
    edge((482pt, 20pt), (560pt, 50pt)),
    edge((482pt, 90pt), (560pt, 62pt)),
    edge((482pt, 160pt), (560pt, 145pt)),
    at(720pt, 70pt, box(width: 140pt, text(size: 10.5pt, fill: slate)[_Consumer group_ `notification` membagi _partition_ di antara anggotanya])),
  )
  #bullets(size: 13pt,
    [_Topic_ `transfer-events` terdiri atas 3 _partition_; setiap _partition_ berupa _log_ yang hanya ditambah di ujungnya],
    [_Offset_ menandai posisi baca _consumer group_ di setiap _partition_, dan _broker_ menyimpannya per _group_],
    [Satu _partition_ hanya dibaca oleh satu anggota _group_, sehingga jumlah anggota yang aktif maksimal sama dengan jumlah _partition_],
  )
]

#slide(kicker: "Kafka", title: [_Key_ menentukan _partition_ dan urutan])[
  #two-col(
    [
      #bullets(size: 14pt,
        [_Producer_ mengirim _message_ dengan _key_ `transfer_id`],
        [Semua _message_ dengan _key_ yang sama masuk ke _partition_ yang sama, asalkan `kafka.Writer` diberi `Balancer: &kafka.Hash{}`; _balancer_ _default_ kafka-go adalah _round-robin_ yang mengabaikan _key_],
        [Urutan hanya dijamin di dalam satu _partition_, tidak di seluruh _topic_],
        [Akibatnya, event milik transfer yang sama selalu dibaca berurutan],
      )
    ],
    [
      #card([Isi satu _message_])[
        #table(
          columns: (auto, 1fr),
          [Bagian], [Isi],
          [_Key_], [`transfer_id`],
          [_Header_], [`event_type`, `event_id`],
          [_Value_], [_Payload_ JSON event],
        )
      ]
    ],
  )
  #v(8pt)
  #note(kind: "warn")[Tanpa _key_ dan tanpa `kafka.Hash`, event untuk satu `transfer_id` tersebar ke beberapa _partition_. Saat ini setiap transfer menghasilkan satu event akhir, tetapi urutan per transfer menjadi penting begitu satu transfer menghasilkan lebih dari satu event, misalnya `TransferDebited` lalu `TransferCompleted`.]
]

#slide(kicker: "Kafka", title: "Tiga tingkat jaminan pengiriman")[
  #table(
    columns: (auto, 1.3fr, 1.3fr),
    [Jaminan], [Cara kerja di sisi _consumer_], [Akibat saat _consumer_ mati di tengah proses],
    [_At-most-once_], [_Commit offset_ dulu, lalu proses], [Event hilang dan tidak pernah diproses],
    [_At-least-once_], [Proses dulu, lalu _commit offset_], [Event diproses ulang, sehingga muncul duplikat],
    [_Exactly-once_], [Transaksi Kafka, hanya berlaku dari Kafka ke Kafka], [Tidak mencakup tulis ke PostgreSQL milik service],
  )
  #v(12pt)
  #note[Studi kasus memilih _at-least-once_. Kehilangan notifikasi transfer tidak dapat diterima, sedangkan duplikat dapat dicegah di sisi penerima dengan _idempotent consumer_ (Lab 6).]
]

#code-slide(kicker: "Kafka", title: [_Consumer_ dengan kafka-go],
  side: [
    - `FetchMessage` tidak melakukan _commit_ otomatis
    - _Offset_ di-_commit_ setelah baris notifikasi tersimpan di database
    - _Consumer_ mati sebelum _commit_: event yang sama dibaca lagi setelah _restart_
    - Di Lab 5 _handler_ ini sengaja belum idempoten
  ],
)[
```go
r := kafka.NewReader(kafka.ReaderConfig{
    Brokers: cfg.KafkaBrokers,
    Topic:   cfg.KafkaTopic,
    GroupID: "notification",
})

for {
    m, err := r.FetchMessage(ctx)
    if err != nil {
        return fmt.Errorf("fetch: %w", err)
    }
    if err := h.Handle(ctx, m); err != nil {
        return fmt.Errorf("handle %s: %w", m.Key, err)
    }
    if err := r.CommitMessages(ctx, m); err != nil {
        return fmt.Errorf("commit: %w", err)
    }
}
```
]

// ── 02 Saga ────────────────────────────────────────────────────────────────

#section-slide(number: "02", title: "Saga dengan kompensasi", subtitle: [Konsistensi data lintas database tanpa _two-phase commit_])

#slide(kicker: "Masalah", title: "Transfer menyentuh dua database")[
  #two-col(
    [
      #bullets(size: 14pt,
        [Debit dan credit dijalankan oleh account, sedangkan status transfer tersimpan di db-transfer],
        [Tidak ada satu transaksi database yang mencakup keduanya],
        [_Two-phase commit_ (2PC) mengikat semua service: satu peserta lambat menahan _lock_ di peserta lain],
        [Pengganti 2PC: rangkaian transaksi lokal yang masing-masing langsung di-_commit_],
      )
    ],
    [
      #card("Akibatnya", accent: amber)[
        Bila langkah ke-2 gagal, langkah ke-1 sudah di-_commit_ dan tidak bisa di-_rollback_. Pembatalannya harus berupa transaksi baru yang membalik efek langkah ke-1, yaitu *transaksi kompensasi*.
      ]
    ],
  )
  #v(10pt)
  #note[Hari 2 sudah membahas alasan tidak menggunakan 2PC. Hari ini membahas cara mengimplementasikan alternatifnya.]
]

#slide(kicker: "Saga", title: [_Orchestration_ dan _choreography_])[
  #two-col(
    card([_Orchestration_])[
      - Satu service (_orchestrator_) menentukan langkah berikutnya
      - Status saga tersimpan di satu tempat dan mudah ditelusuri
      - _Orchestrator_ mengetahui semua peserta
      - Studi kasus: *transfer* menjadi _orchestrator_
    ],
    card([_Choreography_], accent: amber)[
      - Setiap service bereaksi terhadap event service lain
      - Tidak ada koordinator pusat
      - Alur hanya terlihat dengan menggabungkan log semua service
      - Cocok untuk alur pendek dengan sedikit peserta
    ],
  )
  #v(10pt)
  #note(kind: "tip")[Transfer dana butuh status yang jelas setiap saat, misalnya untuk menjawab keluhan nasabah. Karena itu studi kasus memilih _orchestration_.]
]

#let state(label, width: 130pt) = node(label, kind: "infra", width: width, height: 46pt)

#slide(kicker: "Saga", title: "Status transfer dalam saga")[
  #diagram(height: 280pt,
    at(0pt, 110pt, state("PENDING")),
    at(270pt, 110pt, state("DEBITED")),
    at(580pt, 10pt, state("COMPLETED")),
    at(580pt, 110pt, state("COMPENSATED")),
    at(580pt, 210pt, state("COMPENSATION_FAILED", width: 200pt)),
    at(0pt, 230pt, state("FAILED")),
    edge((130pt, 133pt), (270pt, 133pt), label: "debit berhasil"),
    edge((65pt, 156pt), (65pt, 230pt), label: "debit gagal", label-dx: 70pt, label-dy: -6pt),
    edge((400pt, 120pt), (580pt, 33pt), label: "credit berhasil", label-dx: -20pt),
    edge((400pt, 133pt), (580pt, 133pt), label: "credit gagal, reversal OK", label-dy: -18pt),
    edge((400pt, 146pt), (580pt, 233pt), label: "reversal gagal", label-dx: -20pt, label-dy: 14pt),
  )
  #note(kind: "warn")[`COMPENSATION_FAILED` dicatat sebagai log _error_ dan ditangani manual oleh petugas operasional. Status ini tidak boleh diperbaiki otomatis tanpa pemeriksaan.]
]

#slide(kicker: "Saga", title: [Kode HTTP `POST /transfers` sejak Lab 5])[
  #table(
    columns: (1.6fr, auto, 1.3fr),
    [Hasil Saga], [HTTP], [Arti bagi Channel],
    [`COMPLETED`], [`201`], [Selesai],
    [Rekening tidak ada atau saldo kurang, termasuk `COMPENSATED` karena rekening tujuan tidak ada], [`422`], [Tidak ada uang yang berpindah. Data yang sama memberi hasil yang sama],
    [_Circuit breaker_ terbuka saat debit (`FAILED`), atau saat credit lalu debit dikembalikan (`COMPENSATED`)], [`503`], [Tidak ada uang yang berpindah, aman diulang setelah jeda],
    [_Dependency_ gagal (`FAILED` atau `COMPENSATED`)], [`502`], [Periksa `GET /transfers/{id}`],
    [`COMPENSATION_FAILED`], [`500`], [Dana tertahan di sisi transfer, ditangani petugas],
  )
  #v(8pt)
  #note[Berbeda dengan Lab 3 dan Lab 4: _breaker_ yang terbuka di antara debit dan credit kini menghasilkan `503`, karena debit sudah dikembalikan dan tidak ada uang yang berpindah.]
]

#slide(kicker: "Saga", title: "Kompensasi berupa transaksi baru")[
  #flow(
    node("Debit", sub: "ref = id transfer", kind: "infra", width: 150pt),
    arr(label: "commit", length: 60pt),
    node("Credit", sub: "gagal", kind: "infra", width: 120pt),
    arr(label: "kompensasi", length: 90pt, color: amber),
    node("Credit ke sumber", sub: "ref = id:reversal", kind: "infra", width: 170pt),
  )
  #v(14pt)
  #bullets(size: 13.5pt,
    [Kompensasi tidak menghapus mutasi debit; account mencatat mutasi credit baru dengan _reference_ `<transfer_id>:reversal`. Riwayat mutasi tetap lengkap untuk audit],
    [Credit yang `DeadlineExceeded` diulang lebih dulu dengan _reference_ yang sama, karena credit sudah idempoten. Bila semua percobaan berakhir _timeout_, hasilnya tidak pasti: lab tetap menjalankan kompensasi, sedangkan sistem _production_ menambahkan _reconciliation job_],
    [Kompensasi juga bisa gagal atau _timeout_, jadi kompensasi wajib aman untuk diulang. Kompensasi yang gagal berakhir di `COMPENSATION_FAILED`],
  )
  #v(4pt)
  #note[Kompensasi membalik efek bisnis, tidak membalik transaksi database. Istilahnya _semantic undo_.]
]

#code-slide(kicker: "Saga", title: [_Reversal_ dengan _policy_ sendiri tanpa _circuit breaker_],
  side: [
    - Credit biasanya gagal karena account mati atau _breaker_ baru terbuka. Bila _reversal_ lewat _breaker_ yang sama, _reversal_ langsung ditolak dan transfer berakhir `COMPENSATION_FAILED`
    - _Reversal_ berjalan di koneksi gRPC kedua: _retry_ dengan _backoff_ 200 ms–5 detik selama paling lama 30 detik
    - Setiap percobaan membawa _reference_ yang sama, sehingga saldo tidak bertambah dua kali
    - Log `retrying reversal` menandai setiap percobaan ulang
  ],
)[
```go
// transfer.Service
func (s *Service) compensate(ctx context.Context,
    t Transfer, cause error) (Transfer, error) {
    reason := fmt.Sprintf("credit failed: %v", cause)
    err := s.accounts.Reverse(ctx, t.FromAccount,
        t.Amount, t.ID+ReversalSuffix)
    if err != nil {
        reason = fmt.Sprintf("%s; reversal failed: %v",
            reason, err)
        return s.finish(ctx, t, Debited, CompensationFailed,
            reason, "", fmt.Errorf("%w: %w",
                ErrReversalFailed, errors.Join(cause, err)))
    }
    return s.finish(ctx, t, Debited, Compensated,
        reason, EventCompensated, cause)
}

// accountclient.New: tanpa breaker, dibatasi durasi
reversalRetry := retrypolicy.NewBuilder[any]().
    HandleIf(countsAsFailure).
    WithMaxRetries(-1). // dibatasi durasi, bukan jumlah
    WithMaxDuration(s.ReversalMaxDuration). // 30 s
    WithBackoff(s.ReversalBackoffMin, s.ReversalBackoffMax).
    WithJitterFactor(jitterFactor).
    Build()
```
]

#slide(kicker: "Saga", title: [Saga dan _graceful shutdown_])[
  #two-col(
    card([Durasi terburuk satu saga])[
      #table(
        columns: (1fr, auto),
        [Langkah], [Durasi],
        [Debit: 4 percobaan × 2 detik + 3 _backoff_ × 1,25 detik], [11,75 detik],
        [Credit, dengan perhitungan yang sama], [11,75 detik],
        [_Reversal_: jendela 30 detik + 1 percobaan terakhir], [32 detik],
        [*Total*], [*55,5 detik*],
      )
    ],
    card([Akibatnya], accent: gold.darken(15%))[
      - `shutdownGrace` transfer = 60 detik. `TestShutdownGrace` gagal bila _policy_ bertambah panjang melewati angka ini
      - Platform harus memberi waktu yang cukup sebelum `SIGKILL`: `terminationGracePeriodSeconds` di Kubernetes (Hari 4), `stop_grace_period` di Docker Compose
    ],
  )
  #v(10pt)
  #note(kind: "warn")[Celah yang tersisa: proses yang mati paksa (`SIGKILL`, _crash_) di antara dua langkah meninggalkan baris `PENDING` atau `DEBITED` yang tidak dilanjutkan siapa pun. Sistem _production_ menambahkan _recovery job_ yang melanjutkan atau mengompensasi baris tersebut.]
]

#slide(kicker: "Saga", title: "Mutasi account dibuat idempoten")[
  #two-col(
    [
      ```sql
      create unique index if not exists
        mutation_idempotency
        on mutation (account_number, type, reference);

      insert into mutation (...) values (...)
      on conflict (account_number, type, reference)
      do nothing;
      ```
      #v(6pt)
      #bullets(size: 13pt,
        [Tidak ada baris yang masuk: _reference_ sudah pernah diterapkan. Account membaca saldo dalam transaksi yang sama, menjawab sukses tanpa mutasi baru, dan mencatat log `mutation already applied, not repeated`],
        [_Reference_ debit = `transfer_id`, _reference_ reversal = `transfer_id:reversal`],
      )
    ],
    [
      #card("Dampak ke klien gRPC di transfer")[
        Sejak Hari 2, _retry_ hanya dilakukan untuk `Unavailable`. Setelah mutasi idempoten, `DeadlineExceeded` juga boleh di-_retry_.

        #v(4pt)
        Debit yang ternyata sudah diproses sebelum _timeout_ tidak akan dijalankan dua kali.
      ]
    ],
    ratio: (1.2fr, 1fr),
  )
  #v(8pt)
  #note(kind: "warn")[Lab 5 dimulai dengan `make infra-reset` lalu `make infra-up`. Database dari Lab 1–4 dapat berisi _reference_ ganda; _unique index_ gagal dibuat dan account berhenti saat _startup_ dengan _error_ `apply schema`.]
]

// ── 03 Outbox ──────────────────────────────────────────────────────────────

#section-slide(number: "03", title: [_Transactional outbox_], subtitle: [Status di database dan event di Kafka harus selalu sejalan])

#slide(kicker: "Masalah", title: [_Dual write_ ke database dan Kafka])[
  #two-col(
    card([Tulis DB dulu, lalu _publish_], accent: amber)[
      ```go
      tx.Commit(ctx)          // status COMPLETED
      w.WriteMessages(ctx, m) // proses mati di sini
      ```
      Transfer selesai, tetapi event tidak pernah terkirim. Nasabah tidak menerima notifikasi.
    ],
    card([_Publish_ dulu, lalu tulis DB], accent: red)[
      ```go
      w.WriteMessages(ctx, m) // event terkirim
      tx.Commit(ctx)          // gagal
      ```
      Notifikasi \"transfer berhasil\" terkirim, padahal status transfer di database tidak berubah.
    ],
  )
  #v(10pt)
  #note[Database dan Kafka tidak bisa digabung dalam satu transaksi. Urutan mana pun tetap menyisakan celah ketika proses mati di antara dua langkah tersebut.]
]

#slide(kicker: "Pola", title: [Alur _transactional outbox_])[
  #diagram(height: 250pt,
    at(0pt, 20pt, node("transfer", sub: "saga")),
    at(250pt, 20pt, node("account", sub: "gRPC")),
    at(0pt, 160pt, node("db-transfer", sub: "transfers + outbox", kind: "db", width: 150pt, height: 76pt)),
    at(250pt, 170pt, node("relay", sub: "goroutine")),
    at(470pt, 170pt, node("Kafka", sub: "transfer-events", kind: "broker", width: 150pt)),
    at(720pt, 170pt, node("notification", sub: "consumer")),
    at(720pt, 20pt, node("db-notification", kind: "db", width: 120pt, height: 66pt)),
    edge((120pt, 48pt), (250pt, 48pt), label: "debit / credit"),
    edge((60pt, 76pt), (60pt, 160pt), label: "1 transaksi", label-dx: 64pt, label-dy: -6pt),
    edge((250pt, 198pt), (150pt, 198pt), label: "poll 500 ms"),
    edge((370pt, 198pt), (470pt, 198pt), label: "publish"),
    edge((620pt, 198pt), (720pt, 198pt), label: "consume"),
    edge((780pt, 170pt), (780pt, 86pt)),
  )
  #bullets(size: 13pt,
    [Perubahan status transfer dan baris outbox ditulis dalam *satu transaksi database*: keduanya tersimpan, atau keduanya batal],
    [_Relay_ membaca outbox secara terpisah lalu mengirim ke Kafka],
  )
]

#code-slide(kicker: "Outbox", title: "Status dan event dalam satu transaksi",
  side: [
    - `tx.Rollback` setelah `Commit` tidak berpengaruh, jadi aman di-`defer`
    - `and status = @from` menjaga urutan status: transfer yang sudah dipindahkan proses lain tidak ditimpa (`ErrStaleState`)
    - Tabel `outbox`: `id`, `aggregate_id`, `event_type`, `payload` (jsonb), `created_at`, `published_at`
    - Event hanya untuk status akhir: `TransferCompleted`, `TransferFailed`, `TransferCompensated`
  ],
)[
```go
func (s *PostgresStore) Transition(ctx context.Context,
    id string, from, to Status, reason string,
    event EventType) (Transfer, error) {
    tx, err := s.pool.Begin(ctx)
    // ...
    defer tx.Rollback(ctx) // no-op after Commit

    t, err := one(ctx, tx, `
        update transfer set status = @to, ...
        where id = @id and status = @from
        returning `+columns, pgx.NamedArgs{...})
    // ... tidak ada baris: ErrStaleState
    if event != "" {
        // e := Event{EventID: uuid.NewString(), ...}
        payload, err := json.Marshal(e)
        // ...
        err = outbox.Insert(ctx, tx, outbox.Message{
            ID: e.EventID, AggregateID: t.ID,
            EventType: string(event), Payload: payload})
        // ...
    }
    return t, tx.Commit(ctx)
}
```
]

#code-slide(kicker: "Outbox", title: [_Relay_ dari outbox ke Kafka],
  side: [
    - `for update skip locked`: beberapa _replica_ transfer dapat menjalankan _relay_ tanpa mengambil baris yang sama
    - _Key_ `transfer_id` dengan `Balancer: &kafka.Hash{}` di `kafka.Writer`, _header_ `event_type` dan `event_id`
    - Proses mati setelah _publish_ dan sebelum `published_at` diisi: event dikirim ulang
    - Itulah sebabnya outbox menghasilkan _at-least-once_
  ],
)[
```go
rows, err := tx.Query(ctx, `
    select id::text, aggregate_id::text, event_type, payload
    from outbox
    where published_at is null
    order by created_at
    limit @limit
    for update skip locked`,
    pgx.NamedArgs{"limit": BatchSize}) // 100
// ... baca baris menjadi msgs ([]kafka.Message)

if err := r.pub.WriteMessages(pubCtx, msgs...); err != nil {
    return 0, fmt.Errorf("publish %d events: %w",
        len(msgs), err)
}
// jendela duplikat: event sudah di Kafka,
// published_at belum tersimpan
_, err = tx.Exec(ctx, `update outbox
    set published_at = now()
    where id = any(@ids::uuid[])`,
    pgx.NamedArgs{"ids": ids})
```
]

#slide(kicker: "Kontrak event", title: [_Payload_ event transfer])[
  #two-col(
    [
      ```json
      {
        "event_id":     "8f0c...e1",
        "transfer_id":  "3b2a...9d",
        "from_account": "1001",
        "to_account":   "1002",
        "amount":       "250000.00",
        "status":       "COMPLETED",
        "reason":       "",
        "occurred_at":  "2026-10-28T10:15:00Z"
      }
      ```
    ],
    [
      #bullets(size: 13.5pt,
        [`event_id` unik per event, menjadi dasar deteksi duplikat di Lab 6],
        [`amount` berupa _string_ desimal, konsisten dengan kontrak protobuf Hari 2],
        [_Payload_ memuat semua data yang dibutuhkan notification, sehingga notification tidak perlu memanggil transfer],
        [Event menyatakan fakta yang sudah terjadi, karena itu nama event menggunakan bentuk _past tense_ bahasa Inggris, misalnya `TransferCompleted`],
      )
    ],
    ratio: (1fr, 1.1fr),
  )
]

#slide(kicker: [_Consumer_], title: [_Event_ yang tidak mungkin diproses (_poison message_)])[
  #two-col(
    card([Dicatat `ERROR` lalu dilewati], accent: red)[
      - JSON yang tidak dapat dibaca
      - `event_id` atau `transfer_id` yang bukan UUID 36 karakter
      - Ditolak PostgreSQL dengan SQLSTATE kelas 22 (data tidak valid, misalnya `22P02`) atau 23 (_constraint_, misalnya `23502`)
      - _Offset_ tetap di-_commit_, sehingga _event_ berikutnya di _partition_ yang sama tidak tertahan
    ],
    card([Diulang sampai berhasil], accent: gold.darken(15%))[
      - Database atau Kafka mati, koneksi putus, _timeout_
      - _Error_ skema (kelas 42, misalnya tabel tidak ada): semua _event_ gagal dengan cara yang sama. Melewatinya berarti membuang semua notifikasi, sedangkan mengulangnya hanya menahan konsumsi sampai perbaikan di-_deploy_
    ],
  )
  #v(10pt)
  #note[_Event_ yang terus gagal tanpa batas memblokir seluruh _partition_. Di _production_, _event_ seperti ini dikirim ke _dead-letter topic_ untuk diperiksa petugas.]
]

#slide(kicker: "Lab 5", title: "Transfer sebagai saga dengan outbox dan Kafka")[
  #two-col(
    card("Tujuan")[
      Transfer yang gagal di tengah jalan selalu berakhir di status yang jelas, dan setiap perubahan status menghasilkan event yang sampai ke notification.
    ],
    card("Yang dikerjakan", accent: gold.darken(15%))[
      - Kafka dan db-notification di `compose.yaml`
      - Mutasi account idempoten berdasarkan _reference_
      - Saga di transfer, termasuk reversal
      - Outbox dan _relay_ ke _topic_ `transfer-events`
      - Service notification sebagai _consumer_
    ],
  )
  #v(10pt)
  #bullets(size: 13pt,
    [Langkah pertama: `make infra-reset` lalu `make infra-up`. Kafka baru muncul di lab ini dan _unique index_ mutasi membutuhkan database kosong],
    [Uji kompensasi: transfer ke `to_account` yang tidak terdaftar menghasilkan `COMPENSATED` dan dua mutasi di db-account. Dengan `make fault-error RATE=0.6` dan ±20 transfer bersamaan, sebagian transfer menampilkan log `retrying reversal` lalu berakhir `COMPENSATED` dengan HTTP `503`],
    [Uji duplikat: hentikan notification, jalankan `make replay`, lalu lihat notifikasi ganda],
  )
  #note(kind: "tip")[Langkah lengkap: Panduan Lab, bab Lab 5. Titik awal: tag `lab-04`; hasil akhir: tag `lab-05`.]
]

// ── 04 Idempotency ─────────────────────────────────────────────────────────

#section-slide(number: "04", title: [_Idempotency_], subtitle: [Pemrosesan ulang tidak boleh menggandakan mutasi])

#slide(kicker: "Masalah", title: "Sumber duplikat dalam studi kasus")[
  #table(
    columns: (1fr, 1.4fr),
    [Sumber], [Kejadian],
    [_Relay_ outbox], [Proses mati setelah _publish_, sebelum `published_at` tersimpan],
    [_Consumer_ Kafka], [Proses mati setelah tulis ke database, sebelum _commit offset_],
    [_Rebalance_ _consumer group_], [_Partition_ pindah ke anggota lain sebelum _offset_ terakhir di-_commit_],
    [_Replay_], [_Offset_ sengaja dikembalikan ke awal untuk memproses ulang],
    [Klien API], [Aplikasi kanal mengirim ulang `POST /transfers` karena _timeout_],
  )
  #v(10pt)
  #note[Duplikat tidak bisa dicegah di sisi pengirim. Pertahanannya ada di sisi penerima: penerima harus mengenali permintaan yang sudah pernah diproses.]
]

#code-slide(kicker: "Lab 6", title: [_Idempotent consumer_ di notification],
  side: [
    - Tabel `processed_event` dengan `event_id` sebagai _primary key_
    - Tanda \"sudah diproses\" dan notifikasi ditulis dalam satu transaksi
    - Duplikat dilaporkan ke _consumer_ (`inserted` = `false`), dicatat di log `duplicate event skipped`, lalu dilewati; _offset_ tetap di-_commit_
    - Setelah ini, `make replay` tidak lagi menghasilkan notifikasi ganda; `make duplicates` menampilkan daftar kosong
  ],
)[
```go
func (s *PostgresStore) Insert(ctx context.Context,
    n Notification) (Notification, bool, error) {
    tx, err := s.pool.Begin(ctx)
    if err != nil {
        return Notification{}, false, err
    }
    defer tx.Rollback(ctx) // no-op after Commit

    tag, err := tx.Exec(ctx, `insert into processed_event
        (event_id) values (@event_id)
        on conflict (event_id) do nothing`,
        pgx.NamedArgs{"event_id": n.EventID})
    if err != nil {
        return Notification{}, false, err
    }
    if tag.RowsAffected() == 0 {
        return Notification{}, false, nil // duplikat
    }
    rows, err := tx.Query(ctx, `insert into notification
        (event_id, transfer_id, event_type, message)
        values (...) returning `+columns, ...)
    // ... stored dari rows
    return stored, true, tx.Commit(ctx)
}
```
]

#slide(kicker: "Lab 6", title: [_Idempotency-Key_ pada `POST /transfers`])[
  #two-col(
    [
      ```http
      POST /transfers
      Idempotency-Key: 7d1e4c2a-...
      Content-Type: application/json

      {"from_account":"1001",
       "to_account":"1002",
       "amount":"250000.00"}
      ```
    ],
    [
      #table(
        columns: (1fr, 1fr),
        [Permintaan], [Hasil],
        [_Key_ baru], [Transfer baru, saga dijalankan],
        [_Key_ sama, _body_ sama], [Transfer asli, kode HTTP sama dengan respons pertama, _header_ `Idempotent-Replayed: true`],
        [_Key_ sama, transfer pertama masih berjalan], [`202`, periksa `GET /transfers/{id}`],
        [_Key_ sama, _body_ berbeda], [`422`],
        [Format _key_ salah], [`400`],
      )
    ],
    ratio: (1fr, 1.1fr),
  )
  #v(8pt)
  #bullets(size: 13pt,
    [_Key_ dibuat oleh aplikasi kanal dan disimpan dengan _unique index_ di db-transfer. _Replay_ transfer yang selesai menjawab `201`, bukan `200`],
    [Kode yang sama membuat klien yang kehilangan respons pertama mengambil keputusan yang sama. Penyebab `FAILED` dan `COMPENSATED` dibaca ulang dari teks `failure_reason`; desain _production_ menyimpannya di kolom kode tersendiri],
    [Baris `PENDING` atau `DEBITED` yang tertinggal karena _crash_ tidak dilanjutkan, sehingga _replay_-nya terus menjawab `202`],
  )
]

#slide(kicker: "Ringkasan", title: [Tiga titik _idempotency_ dalam studi kasus])[
  #table(
    columns: (auto, 1fr, 1fr, 1fr),
    [Titik], [Penanda keunikan], [Penyimpanan], [Hasil saat duplikat],
    [Mutasi account (Lab 5)], [`account_number`, `type`, `reference`], [_Unique constraint_ di tabel mutasi], [Saldo saat ini, tanpa mutasi baru],
    [_Consumer_ notification (Lab 6)], [`event_id`], [Tabel `processed_event`], [Dilewati dan dicatat di log],
    [API transfer (Lab 6)], [_Header_ `Idempotency-Key`], [Kolom unik di tabel transfer], [Transfer asli dengan kode HTTP respons pertama, atau `422` bila _body_ berbeda],
  )
  #v(12pt)
  #note(kind: "tip")[Penanda keunikan dan perubahan data selalu ditulis dalam satu transaksi database. Bila ditulis terpisah, celah duplikatnya hanya berpindah tempat.]
]

#slide(kicker: "Lab 6", title: [_Replay_ tanpa notifikasi ganda dan tanpa mutasi saldo ganda])[
  #two-col(
    card("Tujuan")[
      Event dan perintah mutasi yang sama boleh diterima berkali-kali tanpa menghasilkan notifikasi ganda atau mutasi saldo ganda, dan permintaan transfer yang dikirim ulang tidak membuat transfer kedua.
    ],
    card("Yang dikerjakan", accent: gold.darken(15%))[
      - Tabel `processed_event` di db-notification
      - _Handler_ notification yang idempoten
      - _Header_ `Idempotency-Key` di `POST /transfers`
      - _Test_ untuk duplikat dan _body_ berbeda
    ],
  )
  #v(10pt)
  #enum(
    [Hentikan notification, tunggu 10–30 detik hingga sesi _consumer group_ berakhir, jalankan `make replay`, lalu jalankan notification kembali. `make replay` yang terlalu cepat gagal dengan pesan `group ... is Stable`],
    [`make duplicates` menampilkan daftar kosong: tidak ada _event_ dengan lebih dari satu notifikasi],
    [Kirim `POST /transfers` dua kali dengan _key_ yang sama: jawaban kedua `201` dengan `Idempotent-Replayed: true`, saldo kedua rekening hanya berubah satu kali. Dengan _body_ berbeda: `422`],
  )
  #note(kind: "tip")[Langkah lengkap: Panduan Lab, bab Lab 6. Titik awal: tag `lab-05`; hasil akhir: tag `lab-06`.]
]

// ── 05 Security ────────────────────────────────────────────────────────────

#section-slide(number: "05", title: "Security antar service", subtitle: [OAuth2 _client credentials_, JWT, _middleware_ REST, dan _interceptor_ gRPC])

#slide(kicker: "Masalah", title: "Jaringan internal tidak otomatis aman")[
  #two-col(
    [
      #bullets(size: 14pt,
        [Saat ini setiap proses yang bisa menjangkau port 29091 dapat memanggil Debit],
        [Satu service yang disusupi membuka akses ke semua service lain],
        [Account perlu tahu *siapa* pemanggilnya dan *apa* yang boleh dilakukan pemanggil tersebut],
      )
    ],
    card("Yang dibutuhkan")[
      - Identitas untuk setiap service (_client_)
      - Hak akses terbatas per operasi (_scope_)
      - Bukti identitas yang dapat diperiksa tanpa memanggil server pusat di setiap _request_
    ],
  )
  #v(12pt)
  #note[Prinsip ini dikenal sebagai _zero trust_: setiap panggilan diperiksa, termasuk panggilan dari dalam jaringan sendiri.]
]

#slide(kicker: "OAuth2", title: [Alur _client credentials_])[
  #diagram(height: 250pt,
    at(0pt, 130pt, node("transfer", sub: "client: transfer-service", width: 150pt)),
    at(330pt, 0pt, node("Ory Hydra", sub: "authorization server", kind: "infra", width: 160pt)),
    at(680pt, 130pt, node("account", sub: "gRPC :29091", width: 150pt)),
    at(0pt, 0pt, node("channel-app", sub: "aplikasi kanal", kind: "ext", width: 150pt)),
    edge((150pt, 135pt), (330pt, 45pt), label: "1. client_id + secret", label-dx: -30pt),
    edge((345pt, 56pt), (165pt, 146pt), label: "2. access token (JWT)", dash: "dashed", label-dx: 40pt, label-dy: 10pt),
    edge((150pt, 165pt), (680pt, 165pt), label: "3. Debit + Bearer token"),
    edge((680pt, 140pt), (490pt, 40pt), label: "JWKS (di-cache)", dash: "dashed", label-dx: 40pt),
    edge((75pt, 56pt), (75pt, 130pt), label: "REST + Bearer", label-dx: -70pt, label-dy: -6pt),
  )
  #bullets(size: 13pt,
    [Tidak ada pengguna yang _login_: service mengautentikasi dirinya sendiri dengan `client_id` dan `client_secret`],
    [Account memeriksa token secara lokal dengan _public key_ dari JWKS, tanpa memanggil Hydra di setiap _request_],
  )
]

#slide(kicker: "JWT", title: [Isi _access token_ dari Hydra])[
  #two-col(
    [
      ```json
      // header
      { "alg": "RS256", "kid": "a1b2...", "typ": "JWT" }

      // payload (claims)
      {
        "iss": "http://localhost:14444/",
        "sub": "transfer-service",
        "client_id": "transfer-service",
        "scp": ["account:write"],
        "iat": 1793182500,
        "exp": 1793186100
      }
      ```
    ],
    [
      #table(
        columns: (auto, 1fr),
        [Bagian Token], [Diperiksa untuk],
        [`kid` (_header_)], [Memilih _public key_ dari JWKS],
        [`iss`], [Token berasal dari _issuer_ yang dipercaya],
        [`exp`], [Token belum kedaluwarsa],
        [`scp`], [Pemanggil punya _scope_ untuk operasi ini],
      )
    ],
    ratio: (1.25fr, 1fr),
  )
  #v(8pt)
  #note(kind: "warn")[JWT hanya ditandatangani, tidak dienkripsi. Siapa pun yang memegang token dapat membaca isinya, jadi data rahasia tidak boleh dimasukkan ke _claim_.]
]

#code-slide(kicker: "JWT", title: "Validasi token dengan keyfunc dan golang-jwt",
  side: [
    - keyfunc mengambil JWKS saat _startup_ dan setiap jam. Token dengan `kid` yang belum dikenal memicu unduhan baru, paling sering sekali per 5 detik
    - Tanda tangan, `iss`, dan `exp` diperiksa oleh _parser_ `jwt`
    - `WithValidMethods` menolak token dengan `alg` lain, termasuk `none`
    - _Scope_ diperiksa oleh pemanggil `Verify`, karena setiap operasi membutuhkan _scope_ berbeda
  ],
)[
```go
keys, err := keyfunc.NewDefaultOverrideCtx(ctx,
    []string{jwksURL}, keyfunc.Override{
        RefreshUnknownKID: rate.NewLimiter(
            rate.Every(5*time.Second), 1),
        // ...
    })

parser := jwt.NewParser(
    jwt.WithValidMethods([]string{"RS256"}),
    jwt.WithIssuer(issuer),
    jwt.WithExpirationRequired(),
    jwt.WithLeeway(30*time.Second),
)

func (v *Verifier) Verify(token string) (Claims, error) {
    var c Claims
    if _, err := v.parser.ParseWithClaims(token, &c,
        v.keys.Keyfunc); err != nil {
        return Claims{}, fmt.Errorf("%w: %w",
            ErrInvalidToken, err)
    }
    return c, nil
}
```
]

#code-slide(kicker: "Lab 7", title: [_Middleware_ JWT di REST transfer],
  side: [
    - `POST /transfers` butuh `transfer:write`, `GET /transfers/{id}` butuh `transfer:read`
    - Token tidak ada atau tidak valid: `401` dengan _header_ `WWW-Authenticate`
    - Token valid tanpa _scope_: `403`
    - `/healthz` dan `/readyz` terbuka untuk _probe_; `/debug/circuit-breaker` terbuka hanya untuk keperluan lab dan di _production_ tidak diekspos keluar
  ],
)[
```go
func (m *Middleware) Require(scope string,
    next http.Handler) http.Handler {
    return http.HandlerFunc(func(
        w http.ResponseWriter, r *http.Request) {
        token, ok := bearer(r.Header.Get("Authorization"))
        if !ok {
            w.Header().Set("WWW-Authenticate", `Bearer`)
            writeError(w, http.StatusUnauthorized,
                ErrNoToken.Error())
            return
        }
        claims, err := m.v.Verify(token)
        if err != nil { // detail hanya di log
            writeError(w, http.StatusUnauthorized,
                ErrInvalidToken.Error())
            return
        }
        if !claims.HasScope(scope) {
            writeError(w, http.StatusForbidden,
                "scope "+scope+" required")
            return
        }
        next.ServeHTTP(w, r.WithContext(context.WithValue(
            r.Context(), claimsKey{}, claims)))
    })
}
```
]

#code-slide(kicker: "Lab 7", title: [_Interceptor_ JWT di gRPC account],
  side: [
    - Token dibaca dari _metadata_ `authorization`
    - Predikat `public` meloloskan _method_ di luar `AccountService` (_health_, _reflection_) tanpa token
    - _Method_ `AccountService` tanpa _scope_ di peta ditolak (_fail closed_)
    - Kode gRPC: `Unauthenticated` dan `PermissionDenied`
    - Batasannya: hanya panggilan _unary_. RPC _streaming_ dan service lain yang kelak didaftarkan tidak terlindungi
  ],
)[
```go
// GRPCScopes: GetAccount -> account:read,
// Debit dan Credit -> account:write
return func(ctx context.Context, req any,
    info *grpc.UnaryServerInfo,
    handler grpc.UnaryHandler) (any, error) {
    if public(info.FullMethod) {
        return handler(ctx, req)
    }
    scope, ok := scopes[info.FullMethod]
    if !ok {
        return nil, status.Error(codes.PermissionDenied,
            "method not allowed")
    }
    token, err := bearerFromMetadata(ctx)
    // err: Unauthenticated, missing bearer token
    claims, err := v.Verify(token)
    if err != nil {
        return nil, status.Error(codes.Unauthenticated,
            ErrInvalidToken.Error())
    }
    if !claims.HasScope(scope) {
        return nil, status.Errorf(codes.PermissionDenied,
            "scope %s required", scope)
    }
    return handler(context.WithValue(ctx,
        claimsKey{}, claims), req)
}
```
]

#code-slide(kicker: "Lab 7", title: "Token dikirim otomatis oleh klien gRPC",
  side: [
    - Transfer meminta _scope_ `account:write` saja, sesuai kebutuhannya (_least privilege_)
    - `tokenCredentials` menyimpan token sampai 10 detik sebelum kedaluwarsa, lalu meminta token baru ke Hydra
    - Satu _cache_ token digunakan bersama oleh koneksi utama dan koneksi _reversal_
    - Di _production_, koneksi gRPC wajib TLS dan `RequireTransportSecurity` mengembalikan `true`
  ],
)[
```go
tokenCfg := clientcredentials.Config{
    ClientID:     cfg.OAuthClientID,
    ClientSecret: cfg.OAuthClientSecret,
    TokenURL:     cfg.OAuthTokenURL,
    Scopes:       []string{"account:write"},
}
accounts, err := accountclient.New(cfg.AccountGRPCAddr,
    accountclient.ProductionSettings, tokenCfg.Token, log)

func (c *tokenCredentials) GetRequestMetadata(
    ctx context.Context, _ ...string) (map[string]string, error) {
    c.mu.Lock()
    defer c.mu.Unlock()
    if !c.tok.Valid() {
        tok, err := c.fetch(ctx)
        if err != nil {
            return nil, &tokenFetchError{err: err}
        }
        c.tok = tok
    }
    return map[string]string{"authorization":
        c.tok.Type() + " " + c.tok.AccessToken}, nil
}

// Lab tanpa TLS. Production: TLS dan return true.
func (*tokenCredentials) RequireTransportSecurity() bool {
    return false
}
```
]

#code-slide(kicker: "Lab 7", title: "Token yang ditolak account diganti satu kali",
  side: [
    - Token dapat ditolak sebelum kedaluwarsa, misalnya Hydra mengganti _signing key_. Token di _cache_ dibuang dan panggilan diulang sekali dengan token baru
    - Gagal mengambil token (Hydra mati) menghasilkan `tokenFetchError` dengan kode `Unauthenticated`. Panggilan tidak sampai ke account, tidak diulang, tidak dihitung _circuit breaker_; transfer berakhir `FAILED` dengan `502`
    - _Interceptor_ ini dipasang paling luar, sebelum _policy_ resiliency, di kedua koneksi
  ],
)[
```go
func (c *tokenCredentials) refreshOnUnauthenticated(
    ctx context.Context, method string, req, reply any,
    cc *grpc.ClientConn, invoker grpc.UnaryInvoker,
    opts ...grpc.CallOption) error {
    err := invoker(ctx, method, req, reply, cc, opts...)
    var fetchErr *tokenFetchError
    if status.Code(err) != codes.Unauthenticated ||
        errors.As(err, &fetchErr) {
        return err
    }
    c.mu.Lock()
    c.tok = nil
    c.mu.Unlock()
    return invoker(ctx, method, req, reply, cc, opts...)
}

// dial(): untuk koneksi utama dan koneksi reversal
grpc.WithPerRPCCredentials(tokens),
grpc.WithChainUnaryInterceptor(
    tokens.refreshOnUnauthenticated, resilience),
```
]

#slide(kicker: "Arsitektur", title: [Posisi API _gateway_])[
  #flow(
    node("aplikasi kanal", kind: "ext", width: 130pt),
    arr(label: "token pengguna", length: 100pt),
    node("API gateway", sub: "di tepi jaringan", kind: "infra", width: 130pt),
    arr(label: "token", length: 70pt),
    node("transfer", width: 110pt),
    arr(label: "token service", length: 100pt),
    node("account", width: 110pt),
  )
  #v(14pt)
  #two-col(
    card([Tugas _gateway_])[
      - Satu pintu masuk dari luar
      - Validasi awal token, _rate limiting_, TLS
      - Menyembunyikan alamat service internal
    ],
    card("Tetap dikerjakan service", accent: gold.darken(15%))[
      - Validasi JWT dan _scope_ di setiap service
      - _Gateway_ tidak menggantikan pemeriksaan di service: panggilan antar service tidak melewati _gateway_
    ],
  )
  #v(8pt)
  #note[Studi kasus tidak menjalankan _gateway_. Pembahasan ini menunjukkan letaknya pada arsitektur _production_.]
]

#slide(kicker: "Security", title: "Alasan kegagalan untuk klien dibuat generik")[
  #two-col(
    card("Sebelum Lab 7", accent: red)[
      ```json
      {"status": "FAILED",
       "failure_reason": "debit failed: debit
        1111111111: rpc error: code = Unavailable
        desc = dial tcp 10.0.3.7:9091: ..."}
      ```
      Alamat internal dan detail error gRPC terbaca oleh klien.
    ],
    card("Sesudah Lab 7", accent: gold.darken(15%))[
      ```json
      {"status": "FAILED",
       "failure_reason": "debit failed:
        account service unavailable"}
      ```
      Detail lengkap tetap ditulis ke log service bersama `transfer_id`. Transfer yang tersimpan sebelum Lab 7 tetap memuat alasan lama.
    ],
  )
  #v(10pt)
  #note(kind: "tip")[Klien cukup tahu kategori kegagalan. Penelusuran penyebab dilakukan dari log, dan Hari 4 menambahkan _correlation ID_ serta _trace_ untuk mempercepatnya.]
]

#slide(kicker: "Lab 7", title: "Mengamankan transfer dan account dengan JWT")[
  #two-col(
    card("Tujuan")[
      Account hanya melayani panggilan dengan token yang valid dan _scope_ yang sesuai, dan REST transfer hanya melayani aplikasi kanal yang memegang token.
    ],
    card("Yang dikerjakan", accent: gold.darken(15%))[
      - Hydra dan _client_ dari konfigurasi yang sudah disediakan
      - _Interceptor_ JWT di account
      - Token _client credentials_ di klien gRPC transfer
      - _Middleware_ JWT di REST transfer
      - _Test_: token valid, kedaluwarsa, _scope_ salah, _issuer_ salah
    ],
  )
  #v(8pt)
  #bullets(size: 13pt,
    [Konfigurasi wajib: `OAUTH_ISSUER`, `OAUTH_JWKS_URL`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_TOKEN_URL`; service berhenti saat _startup_ bila salah satunya kosong],
    [`make token` mencetak token `channel-app` untuk dicoba dengan curl],
  )
  #note(kind: "tip")[Langkah lengkap: Panduan Lab, bab Lab 7. Titik awal: tag `lab-06`; hasil akhir: tag `lab-07`.]
]

// ── 06 Observability ───────────────────────────────────────────────────────

#section-slide(number: "06", title: [Pengantar _observability_], subtitle: [Log, metrik, dan _trace_ sebagai bekal Lab 8 di Hari 4])

#slide(kicker: "Konsep", title: [Tiga pilar _observability_])[
  #table(
    columns: (auto, 1.2fr, 1fr, auto),
    [Pilar], [Pertanyaan yang dijawab], [Contoh di studi kasus], [_Tools_],
    [Log], [Apa yang terjadi pada satu _request_ tertentu?], [`notification sent`, `duplicate event skipped`], [slog],
    [Metrik], [Seberapa sering, seberapa cepat, dan apa trennya?], [`transfers_total{status}`, latensi p95], [Prometheus],
    [_Trace_], [Di service mana waktu habis dalam satu transfer?], [_Span_ transfer, account, notification], [OpenTelemetry],
  )
  #v(12pt)
  #note[Ketiganya ditampilkan di Grafana. Pada monolith satu _stack trace_ cukup untuk menjelaskan kegagalan, sedangkan pada microservices satu transfer melewati tiga service dan sebuah _broker_.]
]

#slide(kicker: "Konsep", title: [_Correlation ID_ dan _trace context_ lintas service])[
  #flow(
    node("klien", kind: "ext", width: 90pt),
    arr(label: "X-Correlation-ID", length: 110pt),
    node("transfer", width: 110pt),
    arr(label: "gRPC metadata", length: 110pt),
    node("account", width: 110pt),
  )
  #v(4pt)
  #flow(
    node("transfer", sub: "outbox", width: 110pt),
    arr(label: "header Kafka", length: 110pt, dash: "dashed"),
    node("Kafka", kind: "broker", width: 110pt),
    arr(label: "header Kafka", length: 110pt),
    node("notification", width: 110pt),
  )
  #v(10pt)
  #bullets(size: 13.5pt,
    [ID yang sama ikut di setiap _hop_: _header_ HTTP, _metadata_ gRPC, dan _header_ Kafka],
    [Untuk jalur asinkron, _trace context_ disimpan di baris outbox saat ditulis, sehingga _relay_ dapat meneruskannya],
    [Hasilnya: satu transfer terlihat sebagai satu _trace_ di Grafana, dari REST hingga notifikasi],
  )
]

#slide(kicker: "Demo Grafana", title: [Membaca _trace_ di Tempo])[
  #let bar(y, x, w, label, c: navy, depth: 0) = (
    at(depth * 14pt, y, box(width: 250pt, height: 22pt, align(left + horizon, text(size: 11pt, label)))),
    at(260pt + x, y, box(width: w, height: 22pt, fill: c.lighten(70%), stroke: 0.8pt + c, radius: 2pt)),
  )
  #diagram(height: 200pt,
    at(260pt, 0pt, text(size: 10pt, fill: slate)[0 ms #h(250pt) 300 ms #h(210pt) 620 ms]),
    ..bar(24pt, 0pt, 560pt, [transfer `POST /transfers`]),
    ..bar(52pt, 14pt, 40pt, [transfer → account `Debit`], depth: 1),
    ..bar(80pt, 18pt, 32pt, [account `Debit`], depth: 2),
    ..bar(108pt, 62pt, 470pt, [transfer → account `Credit`], depth: 1),
    ..bar(136pt, 66pt, 462pt, [account `Credit`], c: red, depth: 2),
    ..bar(164pt, 536pt, 18pt, [transfer `insert outbox`], depth: 1),
  )
  #bullets(size: 13pt,
    [Setiap baris adalah satu _span_; baris yang menjorok berada di bawah _span_ induknya (_parent_/_child_)],
    [Panjang _bar_ menunjukkan durasi. `Credit` di account menghabiskan hampir seluruh waktu transfer, jadi penyelidikan dimulai dari account],
  )
  #note(kind: "tip")[Ilustrasi. Demo sesi ini dijalankan instruktur dari tag `lab-08`, karena `otel-lgtm` baru ditambahkan ke `compose.yaml` di Lab 8.]
]

#slide(kicker: "Demo Grafana", title: [Dari baris log ke _trace_])[
  ```json
  {"time":"2026-10-28T10:15:00.412Z","level":"WARN",
   "msg":"credit failed after debit, reversing the debit","transfer_id":"3b2a...9d",
   "correlation_id":"c7f3e1...","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736",
   "span_id":"00f067aa0ba902b7","error":"rpc error: code = DeadlineExceeded"}
  ```
  #v(6pt)
  #enum(
    [Di Grafana _Explore_, pilih Loki lalu saring log dengan `correlation_id` yang dikembalikan transfer di _header_ `X-Correlation-ID`],
    [Semua baris log dari transfer, account, dan notification untuk _request_ tersebut tampil berurutan menurut waktu],
    [Nilai `trace_id` pada baris log membuka _trace_ yang sama di Tempo],
  )
  #note[_Correlation ID_ digunakan untuk mencari log satu _request_; `trace_id` menghubungkan log tersebut ke _span_ yang menunjukkan durasi setiap langkah.]
]

#slide(kicker: "Demo Grafana", title: [Membaca metrik dengan PromQL])[
  #table(
    columns: (1fr, 1.3fr),
    [Panel], [PromQL],
    [Laju transfer per status], [`sum by (status) (rate(transfers_total[5m]))`],
    [_Latency_ p95 per _route_], [`histogram_quantile(0.95, sum by (le, route) (rate(http_server_request_duration_seconds_bucket[5m])))`],
  )
  #v(10pt)
  #bullets(size: 13.5pt,
    [`rate(...[5m])` mengubah _counter_ yang terus naik menjadi laju per detik dalam jendela 5 menit],
    [p95 dihitung dari _bucket_ histogram: 95% _request_ selesai di bawah angka tersebut],
    [Kenaikan `FAILED` atau `COMPENSATED` bersamaan dengan naiknya p95 mengarahkan penyelidikan ke _trace_ pada rentang waktu yang sama],
  )
]

#slide(kicker: "Hari 4", title: "Lanjutan di Lab 8")[
  #two-col(
    card("Yang ditambahkan ke ketiga service")[
      - slog JSON dengan `correlation_id`, `trace_id`, `span_id`
      - _Endpoint_ `/metrics` untuk Prometheus
      - _Trace_ OpenTelemetry melalui OTLP
      - _Dashboard_ Grafana yang sudah disediakan
    ],
    card("Latihan", accent: gold.darken(15%))[
      - Beri _delay_ pada account dengan `make fault-slow`
      - Temukan _span_ yang lambat di Tempo
      - Baca status _circuit breaker_ dari metrik
    ],
  )
  #v(12pt)
  #note(kind: "tip")[Event dan outbox yang dibuat hari ini menjadi bagian _trace_ paling menarik di Lab 8, karena _trace_ tetap tersambung walaupun melewati Kafka.]
]

// ── Penutup ────────────────────────────────────────────────────────────────

#slide(kicker: "Ringkasan", title: "Pola hari ini dan syarat penggunaannya")[
  #table(
    columns: (auto, 1fr, 1fr),
    [Pola], [Masalah yang diselesaikan], [Layak digunakan ketika],
    [Saga (_orchestration_)], [Transaksi bisnis lintas database], [Proses bisnis menyentuh lebih dari satu service dan butuh status yang jelas],
    [Kompensasi], [Langkah yang sudah di-_commit_ harus dibatalkan], [Ada langkah saga yang bisa gagal setelah langkah lain berhasil],
    [_Transactional outbox_], [Tulis DB dan _publish_ event tidak atomik], [Event wajib terkirim jika dan hanya jika data tersimpan],
    [_Idempotent consumer_], [Duplikat dari _at-least-once delivery_], [_Consumer_ mengubah data atau memicu efek ke luar],
    [_Idempotency-Key_], [Klien mengirim ulang _request_], [_Endpoint_ membuat transaksi finansial],
    [OAuth2 _client credentials_ + JWT], [Panggilan antar service tanpa identitas], [Setiap service internal yang mengubah data],
  )
]

#slide(kicker: "Penutup", title: "Pertanyaan untuk direnungkan")[
  #bullets(size: 15pt,
    [Pada sistem yang sedang dikerjakan, adakah proses yang menulis ke database lalu mengirim event atau memanggil sistem lain tanpa outbox?],
    [Saat _timeout_ terjadi, apakah pemanggil tahu permintaannya sudah diproses atau belum? Apa penanda keunikannya?],
    [Siapa yang menangani transfer berstatus `COMPENSATION_FAILED`, dan dari mana petugas tersebut tahu ada kasus baru?],
    [Service internal mana yang saat ini bisa dipanggil tanpa token?],
  )
  #v(12pt)
  #note[_Checkpoint_ hari ini: tag `lab-05`, `lab-06`, dan `lab-07` di repositori studi kasus. Peserta yang tertinggal dapat melanjutkan dari tag lab sebelumnya.]
]
