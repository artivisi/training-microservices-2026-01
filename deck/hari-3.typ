// Day 3 deck: Messaging, Konsistensi Data, dan Security (Lab 5 - Lab 7).
// Build: make CLIENT="..." Deck-Hari-3-Microservices-2026-10.pdf
#import "../_template/deck.typ": *

#show: deck.with(
  title: "Messaging, Konsistensi Data, Security, dan Observability",
  subtitle: [Kafka, _transactional outbox_, saga dengan kompensasi di Lab 5, _idempotency_, OAuth2 dan JWT antar service, serta _observability_ lintas service],
  day-label: "Hari 3",
  client: sys.inputs.at("client"),
  date: "28 Oktober 2026",
)

// ── Pembuka ────────────────────────────────────────────────────────────────

#slide(kicker: "Hari 3", title: "Agenda hari ini")[
  #table(
    columns: (auto, 1fr, auto),
    [Waktu], [Topik], [Format],
    [08:00 – 08:15], [Rekap Hari 2 dan penyamaan posisi dari _checkpoint_ `lab-04` bagi peserta yang tertinggal], [Diskusi],
    [08:15 – 09:15], [Peta _concern_ Hari 3, komunikasi _asynchronous_ dengan Kafka, _at-least-once delivery_, _transactional outbox_], [Presentasi + demo],
    [09:15 – 11:15], [*Lab 5*: transfer sebagai saga, event ke Kafka melalui outbox, notification sebagai _consumer_], [_Hands-on_],
    [11:30 – 12:00], [_Idempotency_: _idempotent consumer_ dan _Idempotency-Key_], [Presentasi],
    [12:00 – 13:00], [Istirahat makan siang], [—],
    [13:00 – 13:45], [*Lab 6*: _idempotent consumer_ dan _Idempotency-Key_ pada API transfer], [_Hands-on_],
    [13:45 – 14:45], [OAuth2 _client credentials_, SSO dan _authorization server_ (_embedded_ atau _standalone_), validasi JWT, posisi API _gateway_, _grant_ OAuth2 dan OIDC untuk aplikasi dengan pengguna], [Presentasi + demo],
    [15:00 – 16:00], [*Lab 7*: _middleware_ JWT pada REST dan _interceptor_ JWT pada gRPC], [_Hands-on_],
    [16:00 – 17:00], [_Observability_ lintas service dan persiapan Lab 8. Ringkasan hari ini pada peta _concern_], [Presentasi + demo],
  )
]

#slide(kicker: "Peta concern microservices", title: [_Concern_ yang dibahas di Hari 3])[
  #concern-map(highlight: (2, 4, 5, 6))
  #v(8pt)
  #note[Baris berwarna dibahas hari ini. Sebagian besar jawabannya ada di kode setiap service: saga, outbox, _idempotency_, dan validasi JWT. Platform menyediakan Kafka, Hydra, dan _backend observability_. Untuk _observability_, hari ini membahas konsep dan kode instrumentasi yang dipasang di Lab 8. Lab 8 dikerjakan di awal Hari 4.]
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
      - Bila debit berhasil tetapi credit gagal, saldo rekening sumber berkurang tanpa dikembalikan
      - Debit belum _idempotent_, jadi _timeout_ belum boleh di-_retry_
      - Siapa pun di jaringan internal dapat memanggil Debit
    ],
  )
  #v(8pt)
  #note[Desain saga, kompensasi, dan mutasi _idempotent_ sudah dibahas di akhir Hari 2. Lab 5 hari ini mengimplementasikannya bersama outbox dan Kafka.]
]

// ── 01 Kafka ───────────────────────────────────────────────────────────────

#section-slide(number: "01", title: [Komunikasi _asynchronous_ dengan Kafka], subtitle: [_Topic_, _partition_, _consumer group_, dan jaminan pengiriman])

#slide(kicker: "Konsep", title: [Panggilan _synchronous_ dan _asynchronous_])[
  #two-col(
    card([_Synchronous_ (REST, gRPC)])[
      - Pemanggil menunggu jawaban
      - Penerima harus aktif saat dipanggil
      - Cocok untuk langkah yang hasilnya langsung dibutuhkan, misalnya debit
      - Kegagalan langsung terlihat oleh pemanggil
    ],
    card([_Asynchronous_ (event melalui _broker_)], accent: amber)[
      - Pengirim menulis event lalu melanjutkan proses
      - Penerima boleh mati sementara, event tetap tersimpan di _broker_
      - Cocok untuk reaksi atas fakta yang sudah terjadi, misalnya notifikasi
      - Event bisa terkirim lebih dari sekali
    ],
  )
  #v(10pt)
  #note[Debit dan credit tetap _synchronous_ karena hasilnya menentukan status transfer. Alasan notifikasi dikirim secara _asynchronous_ ada di _slide_ berikutnya.]
]

#decision(title: [_Messaging_ untuk notifikasi transfer],
  [
    - Nasabah menerima notifikasi untuk setiap transfer yang selesai atau gagal
    - Gangguan di notification tidak boleh menggagalkan transfer
    - Service lain, misalnya pencatatan audit, dapat ikut bereaksi atas transfer tanpa mengubah transfer
  ],
  [
    - Transfer memanggil notification secara _synchronous_ (REST atau gRPC) setelah saga selesai
    - Transfer menulis event ke _message broker_, lalu notification membacanya sebagai _consumer_
  ],
  [
    Event ke _topic_ `transfer-events`, dibaca oleh _consumer group_ `notification`:
    - _Temporal decoupling_: notification boleh mati, event menunggu di _broker_
    - _Load leveling_: lonjakan transfer ditampung _broker_, notification memproses sesuai kapasitasnya
    - _Fan-out_: _consumer_ baru cukup membuat _consumer group_ sendiri
  ],
  [
    - _Eventual consistency_: notifikasi tiba sesaat setelah status transfer berubah, bukan bersamaan
    - Duplikat dan urutan event harus ditangani penerima (_key_ `transfer_id`, Lab 6)
    - _Broker_ menjadi infrastruktur baru yang harus dioperasikan dan dipantau
    - Alur lintas _broker_ hanya terlihat utuh melalui _tracing_ (Lab 8)
  ],
)

#decision(title: [Kafka dibandingkan RabbitMQ],
  ratio: (1fr, 1.6fr),
  [
    - Event transfer dapat dibaca ulang (_replay_) setelah _bug_ di _consumer_ diperbaiki
    - Urutan event milik satu transfer terjaga
    - Beberapa _replica_ notification berbagi beban
  ],
  [
    #show table.cell: set text(size: 10.5pt)
    #table(
      columns: (auto, 1fr, 1fr),
      inset: (x: 5pt, y: 3.5pt),
      [Aspek], [Kafka], [RabbitMQ (_classic_ dan _quorum queue_)],
      [Penyimpanan], [_Log_ yang hanya ditambah, dibaca berdasarkan _offset_], [_Message_ dihapus dari _queue_ setelah _consumer_ mengirim _ack_],
      [_Replay_], [_Offset_ dikembalikan, selama masih dalam masa retensi], [_Producer_ harus mengirim ulang],
      [Urutan], [Per _partition_], [Per _queue_ (FIFO), dapat berubah bila terjadi _redelivery_ dan ada beberapa _consumer_],
      [_Routing_], [Berdasarkan _topic_ dan _key_], [_Exchange_ direct, topic, fanout, headers],
    )
  ],
  [
    Kafka (_mode_ KRaft, tanpa ZooKeeper) dengan _client_ kafka-go. Retensi dan _replay_ digunakan langsung di Lab 5 dan Lab 6 (`make replay`), urutan dijaga dengan _key_ `transfer_id`
  ],
  [
    - Jumlah _consumer_ aktif per _group_ dibatasi jumlah _partition_ (3 di studi kasus)
    - Pilihan _routing_ lebih sedikit dibanding _exchange_ RabbitMQ, sehingga penyaringan event dilakukan di _consumer_
    - Lab menggunakan satu _broker_ tanpa replikasi, sedangkan _production_ butuh beberapa _broker_ dan kebijakan retensi
    - RabbitMQ Streams juga menyediakan _log_ dengan _replay_. Tabel ini membandingkan _classic_ dan _quorum queue_
  ],
)

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
    [_Topic_ `transfer-events` terdiri atas 3 _partition_, dan setiap _partition_ berupa _log_ yang hanya ditambah di ujungnya],
    [_Offset_ menandai posisi baca _consumer group_ di setiap _partition_, dan _broker_ menyimpannya per _group_],
    [Satu _partition_ hanya dibaca oleh satu anggota _group_, sehingga jumlah anggota yang aktif maksimal sama dengan jumlah _partition_],
  )
]

#slide(kicker: "Kafka", title: [_Key_ menentukan _partition_ dan urutan])[
  #two-col(
    [
      #bullets(size: 14pt,
        [_Producer_ mengirim _message_ dengan _key_ `transfer_id`],
        [Semua _message_ dengan _key_ yang sama masuk ke _partition_ yang sama, asalkan `kafka.Writer` diberi `Balancer: &kafka.Hash{}`. Tanpa pengaturan ini, kafka-go menggunakan _balancer_ _default_ _round-robin_ yang mengabaikan _key_],
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
    [_At-most-once_], [_Commit offset_ terlebih dahulu, lalu proses], [Event hilang dan tidak pernah diproses],
    [_At-least-once_], [Proses terlebih dahulu, lalu _commit offset_], [Event diproses ulang, sehingga muncul duplikat],
    [_Exactly-once_], [Transaksi Kafka, hanya berlaku dari Kafka ke Kafka], [Tidak mencakup penulisan ke PostgreSQL milik service],
  )
  #v(12pt)
  #note[Studi kasus memilih _at-least-once_. Kehilangan notifikasi transfer tidak dapat diterima, sedangkan duplikat dapat dicegah di sisi penerima dengan _idempotent consumer_ (Lab 6).]
]

#code-slide(kicker: "Kafka", title: [_Consumer_ dengan kafka-go],
  side: [
    - `FetchMessage` tidak melakukan _commit_ otomatis
    - _Offset_ di-_commit_ setelah baris notifikasi tersimpan di database
    - Bila _consumer_ mati sebelum _commit_, event yang sama dibaca lagi setelah _restart_
    - Di Lab 5 _handler_ ini sengaja belum _idempotent_
  ],
)[
```go
r := kafka.NewReader(kafka.ReaderConfig{
    Brokers:        brokers,
    Topic:          topic,
    GroupID:        groupID, // KAFKA_GROUP_ID
    StartOffset:    kafka.FirstOffset,
    CommitInterval: 0, // commit saat CommitMessages
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
#source(("studi-kasus/notification/internal/notification/consumer.go", "lab-05"))
]

// ── 02 Outbox ──────────────────────────────────────────────────────────────

#section-slide(number: "02", title: [_Transactional outbox_], subtitle: [Status di database dan event di Kafka harus selalu sejalan])

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
  #source(ilustrasi: true)
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
    [Perubahan status transfer dan baris outbox ditulis dalam *satu transaksi database*, sehingga keduanya tersimpan bersama atau batal bersama],
    [_Relay_ membaca outbox secara terpisah lalu mengirim ke Kafka],
  )
]

#code-slide(kicker: "Outbox", title: "Status dan event dalam satu transaksi",
  side: [
    - `tx.Rollback` setelah `Commit` tidak berpengaruh, jadi aman di-`defer`
    - `and status = @from` menjaga urutan status, sehingga transfer yang statusnya sudah diubah proses lain tidak ditimpa (`ErrStaleState`)
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
#source(("studi-kasus/transfer/internal/transfer/store.go", "lab-05"))
]

#code-slide(kicker: "Outbox", title: [_Relay_ dari outbox ke Kafka],
  side: [
    - Dengan `for update skip locked`, beberapa _replica_ transfer dapat menjalankan _relay_ tanpa mengambil baris yang sama
    - _Key_ `transfer_id` dengan `Balancer: &kafka.Hash{}` di `kafka.Writer`, _header_ `event_type` dan `event_id`
    - Bila proses mati setelah _publish_ dan sebelum `published_at` diisi, event dikirim ulang
    - Karena itu, outbox hanya menjamin _at-least-once delivery_
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
#source(("studi-kasus/transfer/internal/outbox/outbox.go", "lab-05"))
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
      - _Offset_ tetap di-_commit_, sehingga event berikutnya di _partition_ yang sama tidak tertahan
    ],
    card([Diulang sampai berhasil], accent: gold.darken(15%))[
      - Database atau Kafka mati, koneksi putus, _timeout_
      - _Error_ skema (kelas 42, misalnya tabel tidak ada) membuat semua event gagal dengan cara yang sama. Melewatinya berarti membuang semua notifikasi, sedangkan mengulangnya hanya menunda pemrosesan event hingga perbaikan di-_deploy_
    ],
  )
  #v(10pt)
  #note[Event yang terus gagal tanpa batas memblokir seluruh _partition_. Di _production_, event seperti ini dikirim ke _dead-letter topic_ untuk diperiksa petugas.]
]

#slide(kicker: "Lab 5", title: "Transfer sebagai saga dengan outbox dan Kafka")[
  #two-col(
    card("Tujuan")[
      Transfer yang gagal di tengah jalan selalu berakhir di status yang jelas, dan setiap perubahan status menghasilkan event yang sampai ke notification.
    ],
    card("Yang dikerjakan", accent: gold.darken(15%))[
      - Kafka dan db-notification di `compose.yaml`
      - Mutasi account _idempotent_ berdasarkan _reference_
      - Saga di transfer, termasuk _reversal_
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
  #note(kind: "tip")[Langkah lengkap ada di Panduan Lab, bab Lab 5. Lab ini dimulai dari tag `lab-04` dan berakhir di tag `lab-05`.]
]

// ── 03 Idempotency ─────────────────────────────────────────────────────────

#section-slide(number: "03", title: [_Idempotency_], subtitle: [Pemrosesan ulang tidak boleh menggandakan mutasi])

#slide(kicker: "Masalah", title: "Sumber duplikat dalam studi kasus")[
  #table(
    columns: (1fr, 1.4fr),
    [Sumber], [Kejadian],
    [_Relay_ outbox], [Proses mati setelah _publish_, sebelum `published_at` tersimpan],
    [_Consumer_ Kafka], [Proses mati setelah menulis ke database, sebelum _commit offset_],
    [_Rebalance_ _consumer group_], [_Partition_ pindah ke anggota lain sebelum _offset_ terakhir di-_commit_],
    [_Replay_], [_Offset_ sengaja dikembalikan ke awal untuk memproses ulang],
    [Klien API], [Aplikasi kanal mengirim ulang `POST /transfers` karena _timeout_],
  )
  #v(10pt)
  #note[Duplikat tidak bisa dicegah di sisi pengirim. Karena itu, sisi penerima harus mengenali permintaan yang sudah pernah diproses.]
]

#code-slide(kicker: "Lab 6", title: [_Idempotent consumer_ di notification],
  side: [
    - Tabel `processed_event` dengan `event_id` sebagai _primary key_
    - Tanda \"sudah diproses\" dan notifikasi ditulis dalam satu transaksi
    - Untuk duplikat, _consumer_ menerima `inserted` = `false`, mencatat log `duplicate event skipped`, lalu melewati event tersebut, tetapi _offset_ tetap di-_commit_
    - Setelah ini, `make replay` tidak lagi menghasilkan notifikasi ganda, dan `make duplicates` menampilkan daftar kosong
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
#source(("studi-kasus/notification/internal/notification/store.go", "lab-06"))
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
    [Karena kode HTTP-nya sama dengan respons pertama, klien yang kehilangan respons pertama tetap mengambil keputusan yang sama. Penyebab `FAILED` dan `COMPENSATED` dibaca ulang dari teks `failure_reason`, sedangkan desain _production_ menyimpannya di kolom kode tersendiri],
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
      - _Handler_ notification yang _idempotent_
      - _Header_ `Idempotency-Key` di `POST /transfers`
      - _Test_ untuk duplikat dan _body_ berbeda
    ],
  )
  #v(10pt)
  #enum(
    [Hentikan notification, tunggu 10–30 detik hingga sesi _consumer group_ berakhir, jalankan `make replay`, lalu jalankan notification kembali. `make replay` yang terlalu cepat gagal dengan pesan `group ... is Stable`],
    [`make duplicates` menampilkan daftar kosong, artinya tidak ada event dengan lebih dari satu notifikasi],
    [Kirim `POST /transfers` dua kali dengan _key_ yang sama. Jawaban kedua berupa `201` dengan `Idempotent-Replayed: true`, dan saldo kedua rekening hanya berubah satu kali. Bila _body_ berbeda, jawabannya `422`],
  )
  #note(kind: "tip")[Langkah lengkap ada di Panduan Lab, bab Lab 6. Lab ini dimulai dari tag `lab-05` dan berakhir di tag `lab-06`.]
]

// ── 05 Security ────────────────────────────────────────────────────────────

#section-slide(number: "04", title: "Security antar service", subtitle: [OAuth2 _client credentials_, JWT, _middleware_ REST, _interceptor_ gRPC, serta _grant_ OAuth2 dan OIDC untuk aplikasi dengan pengguna])

#slide(kicker: "Glosarium", title: [Singkatan di sesi _security_])[
  #let gloss(..rows) = {
    show table.cell: set text(size: 10pt)
    table(
      columns: (auto, 1.1fr, 1.2fr),
      inset: (x: 5pt, y: 3.5pt),
      [Singkatan], [Kepanjangan], [Arti],
      ..rows.pos().flatten(),
    )
  }
  #grid(columns: (1fr, 1fr), column-gutter: 14pt,
    gloss(
      ([API], [_Application Programming Interface_], [Antarmuka yang dipanggil aplikasi lain]),
      ([BFF], [_Backend for Frontend_], [_Backend_ khusus satu _frontend_, penyimpan token]),
      ([CIBA], [_Client-Initiated Backchannel Authentication_], [Persetujuan nasabah di HP atas permintaan pihak lain]),
      ([CLI], [_Command-Line Interface_], [Aplikasi yang dijalankan dari terminal]),
      ([CSRF], [_Cross-Site Request Forgery_], [Situs lain memicu _request_ dengan _cookie_ pengguna]),
      ([DPoP], [_Demonstrating Proof of Possession_], [Token terikat ke _private key_ klien (RFC 9449)]),
      ([FAPI], [_Financial-grade API_], [Profil keamanan OAuth2 untuk sektor keuangan]),
      ([IdP], [_Identity Provider_], [Sistem pengelola identitas dan login]),
      ([IETF], [_Internet Engineering Task Force_], [Penyusun standar internet, termasuk OAuth2]),
      ([JSON], [_JavaScript Object Notation_], [Format data teks]),
      ([JWKS], [_JSON Web Key Set_], [Kumpulan _public key_ untuk memeriksa JWT]),
      ([JWT], [_JSON Web Token_], [Token berisi _claim_ yang di-_sign_]),
    ),
    gloss(
      ([mTLS], [_Mutual TLS_], [Kedua pihak koneksi saling menunjukkan sertifikat]),
      ([OIDC], [_OpenID Connect_], [Standar login pengguna di atas OAuth2]),
      ([OTP], [_One-Time Password_], [Kode sekali pakai]),
      ([PAR], [_Pushed Authorization Request_], [Parameter `/authorize` dikirim langsung ke server (RFC 9126)]),
      ([PKCE], [_Proof Key for Code Exchange_], [Mengikat `code` ke aplikasi yang memintanya (RFC 7636)]),
      ([PKI], [_Public Key Infrastructure_], [Penerbitan dan pengelolaan sertifikat]),
      ([RS256], [RSA _signature_ dengan SHA-256], [Algoritma _signature_ JWT. RSA: Rivest–Shamir–Adleman]),
      ([RFC], [_Request for Comments_], [Nomor dokumen standar IETF]),
      ([SHA-256], [_Secure Hash Algorithm_, 256 bit], [Fungsi _hash_. `S256` di PKCE berarti SHA-256]),
      ([SPA], [_Single-Page Application_], [Aplikasi web berbasis JavaScript di _browser_]),
      ([SSO], [_Single Sign-On_], [Satu kali login untuk banyak aplikasi]),
      ([TLS], [_Transport Layer Security_], [Enkripsi koneksi jaringan]),
      ([URL], [_Uniform Resource Locator_], [Alamat halaman atau _endpoint_]),
      ([XSS], [_Cross-Site Scripting_], [Skrip penyerang berjalan di halaman aplikasi]),
    ),
  )
]

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
  #note[Prinsip ini disebut _zero trust_. Setiap panggilan wajib diperiksa, termasuk panggilan dari dalam jaringan sendiri.]
]

#decision(title: [OAuth2 _client credentials_ dengan Hydra],
  [
    - Identitas per service dan hak akses per operasi (_scope_)
    - Token diperiksa secara lokal di setiap service
    - Mengikuti standar terbuka, sehingga _authorization server_ dapat diganti dengan milik organisasi
  ],
  [
    - _API key_ atau _shared secret_ per pasangan service: tanpa _scope_ standar, rotasi manual
    - mTLS: identitas di tingkat koneksi, butuh PKI, _scope_ tetap diatur sendiri
    - OAuth2 _client credentials_ + JWT dari Hydra, Keycloak, atau IdP lain
  ],
  [
    OAuth2 _client credentials_ dengan Ory Hydra, dijalankan dari konfigurasi `compose.yaml` yang sudah disediakan. Hydra hanya berperan sebagai _authorization server_ OAuth2/OIDC, tanpa UI _login_ dan tanpa manajemen _user_. Untuk alur dengan _user_, _login_ dan _consent_ diserahkan ke aplikasi terpisah. _Client credentials_ tidak melibatkan _user_, sehingga cukup satu _container_
  ],
  [
    - Pengambilan token bergantung pada Hydra. Bila Hydra mati saat token harus diperbarui, transfer berakhir `FAILED` (saat debit) atau `COMPENSATION_FAILED` (saat _reversal_)
    - Mengganti dengan Keycloak atau IdP lain cukup dengan mengubah `OAUTH_ISSUER`, `OAUTH_JWKS_URL`, dan `OAUTH_TOKEN_URL`, misalnya _issuer_ `https://sso.example/realms/<realm>` dan JWKS `.../protocol/openid-connect/certs`
    - Nama _claim_ _scope_ berbeda: Hydra `scp` (_array_), Keycloak `scope` (_string_ dipisah spasi). _Struct_ `Claims` di paket `auth` perlu disesuaikan
  ],
)

#slide(kicker: "SSO dan IdP", title: [_Authorization server_: _embedded_ atau _standalone_])[
  #{
    show table.cell: set text(size: 11pt)
    table(
      columns: (1.25fr, auto, auto, auto, 1.5fr),
      inset: (x: 6pt, y: 4.5pt),
      [Produk], [Jenis], [Bahasa], [Lisensi], [Situs],
      [Spring Security (_Authorization Server_)], [_Embedded_], [Java], [Apache-2.0], [#link("https://spring.io/projects/spring-security")[`spring.io/projects/spring-security`]],
      [zitadel/oidc (_package_ `op`)], [_Embedded_], [Go], [Apache-2.0], [#link("https://github.com/zitadel/oidc")[`github.com/zitadel/oidc`]],
      [node-oidc-provider], [_Embedded_], [Node.js], [MIT], [#link("https://github.com/panva/node-oidc-provider")[`github.com/panva/node-oidc-provider`]],
      [Laravel Passport], [_Embedded_], [PHP], [MIT], [#link("https://laravel.com/docs/passport")[`laravel.com/docs/passport`]],
      [Keycloak], [_Standalone_], [Semua], [Apache-2.0], [#link("https://www.keycloak.org")[`keycloak.org`]],
      [Ory Hydra (digunakan di lab)], [_Standalone_], [Semua], [Apache-2.0], [#link("https://www.ory.sh/hydra")[`ory.sh/hydra`]],
      [ZITADEL], [_Standalone_], [Semua], [AGPL-3.0], [#link("https://zitadel.com")[`zitadel.com`]],
    )
  }
  #v(6pt)
  #grid(columns: (1fr, 1fr), column-gutter: 14pt,
    card([_Embedded_: _library_ di dalam aplikasi], text(size: 12pt)[Satu artefak untuk di-_deploy_, tetapi terikat pada satu _tech stack_, dan tim memelihara kode _security_ tersebut.]),
    card([_Standalone_: produk terpisah], accent: gold.darken(15%), text(size: 12pt)[Dapat digunakan service dalam bahasa apa pun dan siap dijalankan, tetapi menambah satu server yang harus dioperasikan.]),
  )
  #v(4pt)
  #text(size: 11pt, fill: slate)[SSO untuk pengguna (login aplikasi channel atau karyawan) dan _client credentials_ untuk service menggunakan _authorization server_ yang sama. Studi kasus hanya menggunakan _client credentials_ dengan Hydra, karena tidak ada login pengguna. Hydra tidak menyediakan halaman login dan manajemen pengguna, sehingga SSO dengan Hydra membutuhkan aplikasi login terpisah.]
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
    [Alur ini tidak melibatkan _login_ pengguna. Service mengautentikasi dirinya sendiri dengan `client_id` dan `client_secret`],
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
        [`scp`], [Pemanggil memiliki _scope_ untuk operasi ini],
      )
    ],
    ratio: (1.25fr, 1fr),
  )
  #v(8pt)
  #note(kind: "warn")[JWT hanya di-_sign_, tidak dienkripsi. Siapa pun yang memegang token dapat membaca isinya, jadi data rahasia tidak boleh dimasukkan ke _claim_.]
]

#code-slide(kicker: "JWT", title: "Validasi token dengan keyfunc dan golang-jwt",
  side: [
    - keyfunc mengambil JWKS saat _startup_ dan setiap jam. Token dengan `kid` yang belum dikenal memicu pengambilan JWKS baru, paling sering sekali per 5 detik
    - _Signature_, `iss`, dan `exp` diperiksa oleh _parser_ `jwt`
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
#source(("studi-kasus/transfer/internal/auth/verifier.go", "lab-07"))
]

#slide(kicker: "Lab 7", title: [Bagian yang dikerjakan _library_ dan yang ditulis sendiri])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (1.1fr, 1.6fr, 1.6fr),
      inset: (x: 6pt, y: 4pt),
      [Bagian], [Dikerjakan _Library_], [Ditulis di Studi Kasus],
      [_Authorization server_], [Ory Hydra dari `compose.yaml`], [Pendaftaran dua klien di `hydra-init`],
      [Meminta token ke `/token`], [`golang.org/x/oauth2/clientcredentials`: _request_ token, autentikasi klien, membaca _response_ dan waktu kedaluwarsa], [Isi `clientcredentials.Config` di `main.go` transfer],
      [Memasang token di panggilan gRPC], [grpc-go: antarmuka `credentials.PerRPCCredentials` dan `grpc.WithPerRPCCredentials`], [`tokenCredentials`: _cache_ token, _metadata_ `authorization`, `tokenFetchError`],
      [Mengganti token yang ditolak], [—], [_Interceptor_ `refreshOnUnauthenticated`],
      [Mengambil _public key_ (JWKS)], [`MicahParks/keyfunc/v3`: unduh saat _startup_, perbarui setiap jam, unduh ulang untuk `kid` baru], [Batas unduh ulang 5 detik dan _timeout_ di `NewVerifier`],
      [Memeriksa JWT], [`golang-jwt/jwt/v5`: _signature_, `alg`, `iss`, `exp`, toleransi jam], [Opsi _parser_ dan _struct_ `Claims` (`scp`, `client_id`)],
      [Membaca _bearer token_ dan memeriksa _scope_], [—], [_Middleware_ REST `Require`, _interceptor_ gRPC, `HasScope`, kode `401`/`403` dan `Unauthenticated`/`PermissionDenied`],
    )
  }
  #v(6pt)
  #note[grpc-go sudah menyediakan `credentials/oauth.TokenSource`, tetapi _adapter_ tersebut menolak mengirim token tanpa TLS, sedangkan lab berjalan tanpa TLS. _Cache_ `oauth2.ReuseTokenSource` juga tidak dapat dikosongkan saat account menolak token. Dengan TLS dan tanpa penggantian token, `tokenCredentials` cukup diganti dengan `grpc.WithPerRPCCredentials(oauth.TokenSource{TokenSource: tokenCfg.TokenSource(ctx)})`.]
]

#code-slide(kicker: "Lab 7", title: [_Middleware_ JWT di REST transfer],
  side: [
    - `POST /transfers` butuh `transfer:write`, `GET /transfers/{id}` butuh `transfer:read`
    - Token tidak ada atau tidak valid: `401` dengan _header_ `WWW-Authenticate`
    - Token valid tanpa _scope_: `403`
    - `/healthz` dan `/readyz` terbuka untuk _probe_. `/debug/circuit-breaker` terbuka hanya untuk keperluan lab dan tidak diekspos keluar di _production_
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
#source(("studi-kasus/transfer/internal/auth/http.go", "lab-07"))
]

#code-slide(kicker: "Lab 7", title: [_Interceptor_ JWT di gRPC account],
  side: [
    - Token dibaca dari _metadata_ `authorization`
    - Fungsi `public` meloloskan _method_ di luar `AccountService` (_health_, _reflection_) tanpa token
    - _Method_ `AccountService` tanpa _scope_ di _map_ `scopes` ditolak (_fail closed_)
    - Kode gRPC: `Unauthenticated` dan `PermissionDenied`
    - _Interceptor_ ini hanya menangani panggilan _unary_, sehingga RPC _streaming_ dan service lain yang kelak didaftarkan tidak terlindungi
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
#source(("studi-kasus/account/internal/auth/grpc.go", "lab-07"))
]

#code-slide(kicker: "Lab 7", title: "Token dikirim otomatis oleh klien gRPC",
  side: [
    - Transfer meminta _scope_ `account:write` saja, sesuai kebutuhannya (_least privilege_)
    - `tokenCredentials` menyimpan token hingga 10 detik sebelum kedaluwarsa, lalu meminta token baru ke Hydra
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
func (*tokenCredentials) RequireTransportSecurity() bool { return false }
```
#source(("studi-kasus/transfer/main.go", "lab-07"), ("studi-kasus/transfer/internal/accountclient/credentials.go", "lab-07"))
]

#code-slide(kicker: "Lab 7", title: "Token yang ditolak account diganti satu kali",
  side: [
    - Token dapat ditolak sebelum kedaluwarsa, misalnya karena Hydra mengganti _signing key_. Bila itu terjadi, token di _cache_ dibuang dan panggilan diulang sekali dengan token baru
    - Bila token gagal diambil (Hydra mati), klien menghasilkan `tokenFetchError` dengan kode `Unauthenticated`. Panggilan tidak sampai ke account, tidak diulang, dan tidak dihitung oleh _circuit breaker_, sehingga transfer berakhir `FAILED` dengan `502`
    - _Interceptor_ ini dipasang paling luar, sebelum _policy_ _resiliency_, di kedua koneksi
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
#source(("studi-kasus/transfer/internal/accountclient/credentials.go", "lab-07"), ("studi-kasus/transfer/internal/accountclient/client.go", "lab-07"))
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
      - _Gateway_ tidak menggantikan pemeriksaan di service, karena panggilan antarservice tidak melewati _gateway_
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
      Klien dapat membaca alamat internal dan detail _error_ gRPC.
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
  #note(kind: "tip")[Klien cukup tahu kategori kegagalan. Penyebabnya ditelusuri dari log, dan sesi _observability_ di akhir hari ini menambahkan _correlation ID_ serta _trace_ untuk mempercepat penelusuran tersebut.]
]

#slide(kicker: "OAuth2 dan OIDC", title: [_Grant_ OAuth2 dan penggunaannya])[
  #{
    show table.cell: set text(size: 10.5pt)
    table(
      columns: (1.15fr, 0.85fr, 2fr, 1.5fr),
      inset: (x: 6pt, y: 4pt),
      [_Grant_], [Token Atas Nama], [Digunakan Untuk], [Status Saat Ini],
      [_Authorization code_ + PKCE (RFC 6749, RFC 7636)], [Pengguna], [Login pengguna di aplikasi web, SPA, dan _mobile_. Pengguna login di halaman _authorization server_], [Satu-satunya _grant_ untuk aplikasi dengan pengguna. PKCE wajib untuk semua klien],
      [_Client credentials_], [Service], [Service ke service, _batch job_. Tidak ada interaksi pengguna], [Digunakan di Lab 7],
      [_Refresh token_], [Sama dengan token awal], [Memperbarui _access token_ tanpa login ulang], [Untuk _public client_: rotasi setiap kali digunakan atau _sender-constrained_],
      [_Device authorization_ (RFC 8628)], [Pengguna], [Perangkat tanpa _browser_ atau _keyboard_: TV, CLI, kios. Pengguna login di perangkat lain, misalnya HP], [Standar],
      [CIBA (OpenID Foundation)], [Pengguna], [Tindakan yang dimulai pihak bank lalu disetujui nasabah di aplikasi _mobile_ miliknya, misalnya _call center_ membuka blokir kartu debit atau tim _fraud_ meminta konfirmasi transaksi mencurigakan], [Standar, bagian dari profil FAPI],
      [_Token exchange_ (RFC 8693)], [Pengguna, diteruskan service], [Service meneruskan identitas pengguna ke service lain dengan token baru yang _scope_-nya lebih sempit, tanpa interaksi pengguna], [Standar, opsional],
      [_Implicit_], [Pengguna], [Dulu untuk SPA: token dikirim langsung di URL], [Tidak direkomendasikan (RFC 9700), dihapus di _draft_ OAuth 2.1],
      [_Resource owner password credentials_], [Pengguna], [Aplikasi menerima _password_ pengguna lalu menukarnya dengan token], [Dilarang (RFC 9700), dihapus di _draft_ OAuth 2.1],
    )
  }
  #v(6pt)
  #note[RFC 9700 (_OAuth 2.0 Security Best Current Practice_, Januari 2025) memuat rekomendasi keamanan terbaru. _Draft_ OAuth 2.1 menggabungkan RFC 6749, PKCE, dan rekomendasi tersebut menjadi satu dokumen.]
]

#slide(kicker: "OAuth2 dan OIDC", title: "Empat peran dalam OAuth2")[
  #diagram(height: 208pt,
    at(0pt, 0pt, node("Resource owner", sub: "pengguna, nasabah", kind: "ext", width: 180pt)),
    at(684pt, 0pt, node("Authorization server", sub: "Hydra, Keycloak, IdP bank", kind: "infra", width: 180pt)),
    at(0pt, 150pt, node("Client", sub: "aplikasi mobile, web, service", width: 180pt)),
    at(684pt, 150pt, node("Resource server", sub: "API: account, transfer", width: 180pt)),
    edge((180pt, 28pt), (684pt, 28pt), label: "login dan persetujuan"),
    edge((90pt, 56pt), (90pt, 150pt), label: "menggunakan aplikasi", label-dx: 72pt, label-dy: -6pt),
    edge((180pt, 160pt), (684pt, 46pt), label: [1. minta token (_grant_)], label-dx: -70pt, label-dy: -22pt),
    edge((684pt, 60pt), (180pt, 174pt), label: [2. _access token_], dash: "dashed", label-dx: 70pt, label-dy: 12pt),
    edge((180pt, 192pt), (684pt, 192pt), label: [3. _request_ + _access token_]),
    edge((774pt, 150pt), (774pt, 56pt), label: [JWKS atau _introspection_], dash: "dashed", label-dx: -80pt, label-dy: -6pt),
  )
  #v(6pt)
  #{
    show table.cell: set text(size: 11pt)
    table(
      columns: (auto, 1fr),
      inset: (x: 6pt, y: 4pt),
      [Peran], [Tugas],
      [_Resource owner_], [Pemilik data atau rekening yang memberi izin. Tidak ada pada _client credentials_],
      [_Client_], [Aplikasi yang meminta token lalu memanggil API. _Public client_ tidak dapat menyimpan _secret_ (SPA, _mobile_), _confidential client_ dapat (_backend_, BFF)],
      [_Authorization server_], [Mengautentikasi pengguna dan _client_, lalu mengeluarkan token],
      [_Resource server_], [Memeriksa token dan _scope_ sebelum melayani _request_],
      [_Browser_ atau HP pengguna], [Bukan peran tersendiri, melainkan _user agent_ milik _resource owner_. Pada _device flow_, perangkat yang meminta token (TV, CLI) adalah _client_. Pada CIBA, HP nasabah disebut _authentication device_ dan tidak pernah menerima token],
    )
  }
]

#slide(kicker: "OAuth2 dan OIDC", title: "Peran OAuth2 pada beberapa skenario")[
  #{
    show table.cell: set text(size: 11pt)
    table(
      columns: (1.3fr, 0.9fr, 1.2fr, 0.9fr, 1fr, 1fr),
      inset: (x: 6pt, y: 5pt),
      [Skenario], [_Resource Owner_], [_Client_], [_Authorization Server_], [_Resource Server_], [_Grant_],
      [Login _mobile banking_], [Nasabah], [Aplikasi _mobile_ (_public client_)], [IdP bank], [API di belakang _gateway_], [_Authorization code_ + PKCE],
      [_Internet banking_ berbasis SPA], [Nasabah], [BFF (_confidential client_)], [IdP bank], [API di belakang _gateway_], [_Authorization code_ + PKCE],
      [Login CLI internal (_device flow_)], [Pengguna], [CLI (_public client_)], [IdP bank], [API internal], [_Device authorization_],
      [_Call center_ meminta persetujuan nasabah], [Nasabah], [Aplikasi _call center_], [IdP bank], [API transaksi], [CIBA],
      [Lab 7: aplikasi kanal memanggil transfer], [Tidak ada], [`channel-app`], [Hydra], [Transfer (REST)], [_Client credentials_],
      [Lab 7: transfer memanggil account], [Tidak ada], [`transfer-service`], [Hydra], [Account (gRPC)], [_Client credentials_],
    )
  }
  #v(10pt)
  #bullets(size: 13pt,
    [Satu service dapat memegang dua peran. Di Lab 7, transfer menjadi _resource server_ bagi `channel-app` sekaligus _client_ bagi account.],
    [Tanpa _resource owner_, token atas nama _client_ itu sendiri: `sub` berisi `client_id`. Untuk meneruskan identitas nasabah dari transfer ke account, transfer membutuhkan _token exchange_.],
  )
]

#slide(kicker: "OAuth2 dan OIDC", title: [OAuth2 untuk otorisasi, OIDC untuk login pengguna])[
  #two-col(
    card([OAuth2: _access token_])[
      - Menjawab pertanyaan: boleh melakukan apa?
      - Ditujukan ke API (_resource server_). Klaim `aud` berisi API tujuan
      - Isi token tidak wajib dibaca oleh aplikasi klien
      - Lab 7 hanya membutuhkan bagian ini, karena tidak ada login pengguna
    ],
    card([OIDC: _ID token_], accent: gold.darken(15%))[
      - Standar identitas yang dibangun di atas OAuth2, diaktifkan dengan _scope_ `openid`
      - Menjawab pertanyaan: siapa pengguna yang baru login, kapan, dan dengan metode apa?
      - Ditujukan ke aplikasi klien. Klaim `aud` berisi `client_id` aplikasi
      - Menambahkan _endpoint_ UserInfo dan _discovery_ `/.well-known/openid-configuration`
    ],
  )
  #v(10pt)
  #note(kind: "warn")[_ID token_ tidak boleh dikirim ke API sebagai pengganti _access token_. API hanya menerima _access token_ yang `aud`-nya sesuai, dan aplikasi klien hanya membaca _ID token_ yang `aud`-nya sama dengan `client_id` miliknya.]
]

#slide(kicker: "OAuth2 dan OIDC", title: [Alur _authorization code_ dengan PKCE])[
  #sequence(width: 864pt, row: 20pt,
    actors: (("Pengguna + browser", "ext", [_resource owner_]), ("Aplikasi", "svc", [_client_]), ("Authorization server", "infra"), ("API", "svc", [_resource server_])),
    steps: (
      (from: 1, to: 1, label: [Buat `code_verifier` acak dan `code_challenge` = SHA-256-nya]),
      (from: 1, to: 0, label: [_Redirect_ ke `/authorize` + `code_challenge`], reply: true),
      (from: 0, to: 2, label: [`GET /authorize` + `code_challenge`, `state`, `nonce`, `redirect_uri`]),
      (from: 2, to: 0, label: [Halaman login dan persetujuan], reply: true),
      (from: 0, to: 2, label: [_Password_, OTP, persetujuan. Aplikasi tidak pernah menerimanya]),
      (from: 2, to: 0, label: [_Redirect_ ke `redirect_uri` + `code`, `state`], reply: true),
      (from: 0, to: 1, label: [`code`, `state`. Aplikasi mencocokkan `state`]),
      (from: 1, to: 2, label: [`POST /token`: `code` + `code_verifier`]),
      (from: 2, to: 2, label: [Cek SHA-256(`code_verifier`) = `code_challenge`]),
      (from: 2, to: 1, label: [_Access token_, _refresh token_, _ID token_], reply: true),
      (from: 1, to: 3, label: [_Request_ + `Bearer` _access token_]),
    ),
  )
  #two-col(
    card([Alasan _implicit_ ditinggalkan], accent: red)[
      Token dikirim di URL, sehingga tercatat di _history browser_, _header_ `Referer`, dan log _proxy_, tanpa cara mengikat token ke aplikasi yang meminta.
    ],
    card("Fungsi PKCE", accent: gold.darken(15%))[
      `code` yang tercuri di langkah 6 tidak dapat ditukar tanpa `code_verifier`. SPA dan aplikasi _mobile_ (_public client_ tanpa _secret_) dapat menggunakan alur ini.
    ],
  )
]

#slide(kicker: "OAuth2 dan OIDC", title: [Login dari perangkat lain: _device flow_ dan CIBA])[
  #grid(columns: (1fr, 1fr), column-gutter: 24pt,
    [
      #text(size: 13pt, weight: "bold", fill: navy)[_Device authorization grant_ (RFC 8628)]
      #v(2pt)
      #sequence(width: 420pt, row: 31pt,
        actors: (("TV / CLI", "ext", [_client_]), ("Authorization server", "infra"), ("HP pengguna", "ext", [_resource owner_])),
        steps: (
          (from: 0, to: 1, label: [`POST /device_authorization`]),
          (from: 1, to: 0, label: [`device_code`, `user_code`, alamat verifikasi], reply: true),
          (from: 0, to: 0, label: [Tampilkan `user_code` atau QR _code_]),
          (from: 2, to: 1, label: [Buka alamat verifikasi, login, masukkan `user_code`]),
          (from: 0, to: 1, label: [`POST /token` + `device_code`, berkala]),
          (from: 1, to: 0, label: [`authorization_pending` sampai pengguna setuju], reply: true),
          (from: 1, to: 0, label: [_Access token_], reply: true),
        ),
      )
      #set text(size: 11pt)
      Risiko: penyerang mengirim `user_code` miliknya ke korban. Halaman persetujuan harus menampilkan perangkat yang meminta akses.
    ],
    [
      #text(size: 13pt, weight: "bold", fill: navy)[CIBA (_Client-Initiated Backchannel Authentication_)]
      #v(2pt)
      #sequence(width: 420pt, row: 31pt,
        actors: (("Aplikasi call center", "svc", [_client_]), ("Authorization server", "infra"), ("HP nasabah", "ext", [_resource owner_])),
        steps: (
          (from: 0, to: 1, label: [`POST /bc-authorize` + `login_hint`, `binding_message`]),
          (from: 1, to: 0, label: [`auth_req_id`], reply: true),
          (from: 1, to: 2, label: [Permintaan persetujuan (_push notification_)]),
          (from: 2, to: 2, label: [Nasabah login, memeriksa `binding_message`]),
          (from: 2, to: 1, label: [Persetujuan]),
          (from: 0, to: 1, label: [`POST /token` + `auth_req_id`]),
          (from: 1, to: 0, label: [_Access token_, _ID token_], reply: true),
        ),
      )
      #set text(size: 11pt)
      Contoh: _call center_ membuka blokir kartu debit, tim _fraud_ meminta konfirmasi transaksi mencurigakan. `binding_message` tampil di kedua sisi agar nasabah dapat memastikan permintaan yang disetujuinya. Token diterima dengan mode _poll_, _ping_, atau _push_. CIBA termasuk dalam profil FAPI.
    ],
  )
]

#slide(kicker: "OAuth2 dan OIDC", title: "Penyimpanan token di sisi klien")[
  #{
    show table.cell: set text(size: 11.5pt)
    table(
      columns: (auto, 1.5fr, 1.3fr),
      inset: (x: 6pt, y: 5pt),
      [Jenis Klien], [Tempat Token], [Yang Dihindari],
      [Aplikasi web _server-side_], [_Session_ di server. _Browser_ hanya menyimpan _cookie_ `HttpOnly`, `Secure`, `SameSite`], [Token dikirim ke halaman HTML],
      [SPA dengan BFF], [Di BFF. _Browser_ hanya menyimpan _cookie_ _session_], [—],
      [SPA tanpa _backend_], [Memori JavaScript, dengan _refresh token_ yang dirotasi], [`localStorage` dan `sessionStorage`: dapat dibaca oleh skrip XSS],
      [Aplikasi _mobile_], [iOS Keychain, Android Keystore. Login melalui _browser_ sistem (ASWebAuthenticationSession, Custom Tabs) dengan _redirect_ HTTPS milik aplikasi], [WebView di dalam aplikasi (RFC 8252), _custom URL scheme_ yang dapat diklaim aplikasi lain, penyimpanan tanpa enkripsi],
      [Service _backend_], [Memori proses. `client_secret` di Kubernetes Secret atau _vault_], [_Secret_ di _image_, repositori, atau log],
      [CLI], [_Credential store_ sistem operasi], [_File_ teks biasa di _home directory_],
    )
  }
  #v(6pt)
  #note[Prinsipnya sama untuk semua jenis klien: token disimpan sejauh mungkin dari kode yang dapat disusupi, dan umurnya dibuat pendek agar token yang bocor cepat tidak berlaku.]
]

#slide(kicker: "OAuth2 dan OIDC", title: [Pola _Backend for Frontend_ (BFF)])[
  #flow(
    node("browser", sub: "SPA", kind: "ext", width: 110pt),
    arr(label: "cookie HttpOnly", length: 120pt),
    node("BFF", sub: "confidential client", kind: "infra", width: 140pt),
    arr(label: "Bearer access token", length: 140pt),
    node("API gateway / API", width: 150pt),
  )
  #v(4pt)
  #align(center, text(size: 11pt, fill: slate)[BFF menjalankan alur _authorization code_ + PKCE ke _authorization server_ dan menyimpan _access token_ serta _refresh token_])
  #v(10pt)
  #two-col(
    card("Yang diperoleh")[
      - Token tidak pernah sampai ke JavaScript, sehingga skrip XSS tidak dapat mengambil dan membawa token keluar
      - BFF adalah _confidential client_ yang dapat menyimpan _secret_ atau _private key_
      - _Draft_ IETF _OAuth 2.0 for Browser-Based Applications_ menempatkan BFF sebagai pilihan paling aman untuk SPA
    ],
    card("Yang tetap harus dijaga", accent: amber)[
      - Selama halaman terbuka, skrip XSS masih dapat mengirim _request_ melalui BFF. XSS tetap harus dicegah
      - _Cookie_ memerlukan perlindungan CSRF: `SameSite` dan _header_ khusus yang diperiksa BFF
      - BFF menjadi satu komponen tambahan yang harus dioperasikan dan di-_scale_
    ],
  )
]

#slide(kicker: "OAuth2 dan OIDC", title: "Rekomendasi keamanan terkini")[
  #two-col(
    card([Klien dan _authorization server_])[
      - _Authorization code_ + PKCE (`S256`) untuk semua klien, termasuk _confidential client_
      - `redirect_uri` dicocokkan persis, tanpa _wildcard_
      - Token tidak dikirim di _query string_ URL
      - Parameter `/authorize` dikirim melalui PAR (RFC 9126), sehingga tidak dapat diubah di _browser_
      - Autentikasi klien dengan `private_key_jwt` (RFC 7523) atau mTLS (RFC 8705), lebih kuat dari `client_secret`
    ],
    card([_Token_ dan _resource server_], accent: gold.darken(15%))[
      - _Access token_ berumur pendek, dalam hitungan menit
      - `aud` diperiksa di setiap API, agar token untuk satu API tidak diterima API lain (Lab 7 belum memeriksanya)
      - _Scope_ sesempit yang dibutuhkan
      - _Sender-constrained token_ dengan DPoP (RFC 9449) atau mTLS: token yang tercuri tidak dapat digunakan tanpa _private key_ pemiliknya
      - _Refresh token_ dirotasi, dan penggunaan ulang _refresh token_ lama mencabut seluruh rangkaian token tersebut
    ],
  )
  #v(10pt)
  #note[Untuk sektor keuangan, profil FAPI 2.0 dari OpenID Foundation menjadikan sebagian besar rekomendasi ini wajib: PAR, PKCE, _sender-constrained token_, serta autentikasi klien dengan `private_key_jwt` atau mTLS.]
]

#slide(kicker: "Lab 7", title: "Transfer dan account diamankan dengan JWT")[
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
    [Konfigurasi wajib berupa `OAUTH_ISSUER`, `OAUTH_JWKS_URL`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, dan `OAUTH_TOKEN_URL`. Service berhenti saat _startup_ bila salah satunya kosong],
    [`make token` mencetak token `channel-app` untuk dicoba dengan curl],
  )
  #note(kind: "tip")[Langkah lengkap ada di Panduan Lab, bab Lab 7. Lab ini dimulai dari tag `lab-06` dan berakhir di tag `lab-07`.]
]

// ── 05 Observability ───────────────────────────────────────────────────────

#section-slide(number: "05", title: [_Observability_ lintas service], subtitle: [Log, metrik, dan _trace_ di kode dan di platform sebagai bekal Lab 8 di awal Hari 4])

#slide(kicker: "Konsep", title: [Tiga pilar _observability_])[
  #table(
    columns: (auto, 1fr, 1fr, auto),
    [Pilar], [Pertanyaan yang dijawab], [Implementasi di studi kasus], [Disimpan di],
    [Log], [Apa yang terjadi pada satu _request_ tertentu?], [`slog` format JSON, `correlation_id`, `trace_id`], [Loki],
    [Metrik], [Seberapa sering, seberapa cepat, berapa yang gagal?], [`prometheus/client_golang`, _endpoint_ `/metrics`], [Prometheus],
    [_Trace_], [Di service mana sebagian besar waktu satu transaksi terpakai?], [OpenTelemetry, `otelhttp`, `otelgrpc`, _header_ Kafka], [Tempo],
  )
  #v(12pt)
  #bullets(size: 13pt,
    [Pada monolith, satu _stack trace_ cukup untuk menjelaskan kegagalan. Pada microservices, satu transfer melewati tiga service dan sebuah _broker_. Ketiga pilar ditampilkan di Grafana.],
    [Metrik mendeteksi adanya masalah. _Trace_ menunjukkan service yang paling banyak menyita waktu, dan log berisi penyebabnya.],
    [_Trace_ dan log dihubungkan oleh `trace_id`. Dari lonjakan di grafik metrik, _engineer_ mempersempit rentang waktu lalu membuka _trace_ pada rentang tersebut. Tautan langsung dari metrik ke _trace_ membutuhkan _exemplar_ Prometheus, dan fitur tersebut tidak dipasang di lab.],
  )
]

#slide(kicker: "Peta concern microservices", title: [_Observability_ di kode dan di platform])[
  #two-col(
    card([Di kode setiap service (Lab 8)])[
      - *Log.* slog dengan _handler_ JSON ke stdout
      - *Metrik.* Prometheus client (`client_golang`), dibaca dari `GET /metrics`
      - *Trace.* OpenTelemetry SDK: otelhttp dan otelgrpc, _trace context_ di _header_ Kafka ditulis sendiri, dikirim melalui OTLP
      - Setiap service punya salinan paket `telemetry` sendiri. Yang dibagi hanya konvensi, misalnya nama _header_ dan nama metrik
    ],
    card("Di platform", accent: gold.darken(15%))[
      - *Prometheus* mengambil (_scrape_) `/metrics` secara berkala
      - *Loki* menyimpan log, *Tempo* menyimpan _trace_
      - *Grafana* menampilkan ketiganya dan menghubungkan log dengan _trace_
      - Lab menggunakan `otel-lgtm`, yaitu semua komponen di atas dalam satu _container_. _Production_ menjalankannya terpisah dengan _storage_ (Hari 4)
    ],
  )
  #v(10pt)
  #note[*12-factor, faktor XI (_logs_).* Service menulis log sebagai aliran event ke stdout, tanpa mengatur _file_ atau rotasi. Pengumpulan dan penyimpanan log menjadi tugas platform, misalnya `kubectl logs` dan _log collector_ di Kubernetes. Daftar 12-factor diperkenalkan di Hari 1, sesi Anatomi Service Go. Di Lab 8, catatan log yang sama juga dikirim melalui OTLP agar langsung tampil di Loki.]
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
type contextHandler struct{ slog.Handler }

func (h contextHandler) Handle(ctx context.Context,
    r slog.Record) error {
    if id := CorrelationID(ctx); id != "" {
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

func (h contextHandler) WithAttrs(a []slog.Attr) slog.Handler {
    return contextHandler{h.Handler.WithAttrs(a)}
}

func (h contextHandler) WithGroup(n string) slog.Handler {
    return contextHandler{h.Handler.WithGroup(n)}
}
```
#source(("studi-kasus/transfer/internal/telemetry/log.go", "lab-08"))
]

#slide(kicker: "Panduan logging", title: "Isi log untuk kebutuhan operasional")[
  #two-col(
    card("Dicatat")[
      - Hasil akhir setiap transaksi bisnis, satu baris per transaksi: berhasil, ditolak, atau gagal
      - Tindakan otomatis sistem: _retry_, perubahan status _circuit breaker_, kompensasi
      - Kegagalan yang harus ditangani orang, lengkap dengan _error_ dan ID transaksi
      - _Startup_ dan _shutdown_: versi, alamat _listen_, alamat dependensi, tanpa _secret_
    ],
    card("Tidak dicatat", accent: amber)[
      - Setiap langkah di dalam satu transaksi. Urutan dan durasi langkah sudah terlihat di _trace_
      - Jumlah dan laju kejadian. Angka tersebut diambil dari metrik
      - _Body request_ dan _response_ secara utuh
      - _Health check_ dan _scrape_ `/metrics` yang berhasil
    ],
  )
  #v(10pt)
  #bullets(size: 13pt,
    [Transaksi yang berhasil tetap dicatat dengan satu baris INFO. Tanpa baris tersebut, tim operasional tidak dapat membedakan transfer yang berhasil dari transfer yang tidak pernah sampai ke service.],
    [Log merupakan bahan penelusuran. Status resmi transaksi tetap tersimpan di database service, dan _audit trail_ yang diwajibkan regulasi disimpan terpisah dari log aplikasi.],
  )
  #note(kind: "tip")[Cara menguji kelengkapan log: nasabah menanyakan transfernya pukul 10.00. Tim operasional seharusnya dapat menemukan hasil transfer tersebut di Loki hanya dengan nomor referensi, tanpa membuka database.]
]

#code-slide(kicker: "Panduan logging", title: "Pesan log yang mudah dicari",
  side: [
    - Teks pesan sama untuk setiap jenis kejadian. Nilai yang berubah ditulis sebagai atribut
    - Pencarian di Loki menjadi tepat: `msg="transfer completed"` lalu _filter_ berdasarkan `transfer_id` atau `amount`
    - Nama atribut seragam di ketiga service: `transfer_id`, `correlation_id`, `error`
    - Pesan ERROR menyebut tindakan yang diperlukan, misalnya `source account needs manual reversal`
    - Satu _error_ dicatat satu kali, di fungsi yang menangani _error_ tersebut. Fungsi di bawahnya cukup membungkus _error_ dengan konteks (`%w`) lalu mengembalikannya
  ],
)[
```go
// Sulit dicari: data bercampur dengan teks pesan
log.Printf("transfer %s dari %s sebesar %d gagal: %v",
    id, from, amount, err)

// Mudah dicari: pesan tetap, data sebagai atribut
s.log.InfoContext(ctx, "transfer completed",
    "transfer_id", t.ID, "amount", t.Amount)

s.log.ErrorContext(ctx,
    "compensation failed, source account needs manual reversal",
    "transfer_id", t.ID, "from_account", t.FromAccount,
    "amount", t.Amount, "error", err)
```
#source(("studi-kasus/transfer/internal/transfer/service.go", "lab-08"))
]

#slide(kicker: "Panduan logging", title: "Data transaksi di dalam log")[
  #table(
    columns: (auto, auto, 1fr),
    [Data], [Dicatat di Log], [Keterangan],
    [ID transfer, nomor referensi, `correlation_id`], [Selalu], [Kunci pencarian. Baris log tanpa ID tidak dapat dikaitkan dengan keluhan nasabah],
    [Nomor rekening], [Ya, sesuai klasifikasi data bank], [Dibutuhkan untuk penelusuran. Bila kebijakan bank mewajibkan, nomor rekening dicatat dalam bentuk _masking_, misalnya `******7890`],
    [Nominal], [Ya], [Menunjukkan dampak kegagalan, misalnya pada kompensasi yang gagal],
    [Status dan alasan penolakan], [Ya], [Berupa kategori, misalnya `insufficient funds`],
    [Nama, NIK, nomor HP, email nasabah], [Tidak], [Termasuk data pribadi (UU PDP). Data lengkap tersedia di database service pemiliknya],
    [Nomor kartu (PAN), PIN, OTP, _password_], [Tidak pernah], [PCI DSS mewajibkan PAN di-_mask_. PIN dan OTP tidak boleh tersimpan dalam bentuk apa pun],
    [Token JWT, _client secret_, _header_ `Authorization`], [Tidak pernah], [Token yang terbaca di log dapat digunakan ulang sampai kedaluwarsa. Cukup catat `client_id` (Lab 7)],
    [_Body request_ utuh], [Tidak], [Mudah membawa data di atas tanpa disadari. _Field_ yang dicatat dipilih satu per satu],
  )
  #v(8pt)
  #note(kind: "warn")[Log tersalin ke banyak tempat: stdout, _log collector_, Loki, dan layar _engineer_. Hak akses dan masa retensi log mengikuti data paling sensitif yang ada di dalamnya.]
]

#slide(kicker: "Panduan logging", title: "Level log dan tindak lanjutnya")[
  #table(
    columns: (auto, 1fr, 1.2fr, 1fr),
    [Level], [Kapan Digunakan], [Contoh di Studi Kasus], [Tindak Lanjut],
    [DEBUG], [Detail untuk _developer_ saat mencari _bug_, misalnya nilai antara atau isi _query_], [Tidak digunakan], [Tidak aktif di _production_. Diaktifkan sementara saat investigasi],
    [INFO], [Kejadian normal dan hasil bisnis, termasuk transaksi yang ditolak aturan bisnis], [`transfer completed`, `notification sent`, `duplicate event skipped`], [Tidak ada. Menjadi bahan penelusuran],
    [WARN], [Kondisi tidak normal yang sudah ditangani otomatis oleh sistem], [`retrying account call`, `circuit breaker state changed`, `credit failed after debit, reversing the debit`], [Dipantau. Bila terus berulang, metrik memicu _alert_],
    [ERROR], [Sistem gagal menyelesaikan pekerjaannya sehingga perlu tindakan orang], [`compensation failed, source account needs manual reversal`, `skipping unreadable event`], [Memicu _alert_ dan harus ditindaklanjuti],
  )
  #v(10pt)
  #note[Uji untuk level ERROR: bila baris ERROR muncul dan tidak ada orang yang perlu bertindak, levelnya salah. ERROR yang tidak perlu ditindaklanjuti membuat tim terbiasa mengabaikan _alert_ (_alert fatigue_), termasuk _alert_ yang penting.]
]

#slide(kicker: "Panduan logging", title: "Kegagalan bisnis dicatat di level INFO")[
  #table(
    columns: (1fr, auto, 1.4fr),
    [Kejadian], [Level], [Alasan],
    [Saldo tidak cukup], [INFO], [Aturan bisnis berjalan sesuai desain. Service menolak transaksi dengan benar],
    [Rekening tujuan tidak ditemukan], [INFO], [Kesalahan ada di data dari klien, dan service tidak dapat memperbaikinya],
    [Validasi _request_ gagal], [INFO], [Klien menerima daftar _field_ yang salah di _response_],
    [Account lambat, _retry_ berjalan], [WARN], [Kondisi tidak normal yang sudah ditangani _retry_],
    [_Circuit breaker_ terbuka, transfer ditolak], [WARN], [Ditangani otomatis. _Breaker_ yang tidak kembali _closed_ terdeteksi dari metrik],
    [Token ditolak], [WARN], [Konfigurasi klien salah atau ada percobaan akses tanpa izin],
    [Kompensasi gagal, saldo sumber sudah berkurang], [ERROR], [Harus di-_reverse_ manual],
  )
  #v(8pt)
  #bullets(size: 13pt,
    [Kegagalan bisnis yang dicatat sebagai WARN atau ERROR akan memicu _alert_ ratusan kali sehari dan menutupi masalah yang sebenarnya.],
    [Lonjakan penolakan bisnis, misalnya transfer gagal karena saldo tidak cukup yang tiba-tiba naik sepuluh kali lipat, dideteksi dari metrik `transfers_total{status="FAILED"}`.],
  )
  #note(kind: "warn")[*Contoh yang perlu diperbaiki.* Fungsi `finish` di `transfer/internal/transfer/service.go` mencatat semua transfer yang tidak `COMPLETED` di level WARN, termasuk saldo tidak cukup dan rekening tidak ditemukan. _Interceptor_ gRPC account (Hari 2) sudah sesuai panduan: `NotFound` dan `FailedPrecondition` dicatat di level INFO. Latihan: periksa `cause` dengan `errors.Is` terhadap `ErrInsufficientFunds` dan `ErrAccountNotFound`, lalu catat kedua penolakan tersebut di level INFO.]
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
#source(("studi-kasus/transfer/internal/telemetry/telemetry.go", "lab-08"), ("studi-kasus/transfer/internal/outbox/outbox.go", "lab-08"), ("studi-kasus/notification/internal/notification/consumer.go", "lab-08"))
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
    at(250pt, 90pt, node("collector", sub: "OTLP :14317", kind: "infra", width: 130pt)),
    at(480pt, 30pt, node("Tempo", sub: "trace", kind: "infra")),
    at(480pt, 110pt, node("Loki", sub: "log", kind: "infra")),
    at(480pt, 190pt, node("Prometheus", sub: "metrik", kind: "infra")),
    at(720pt, 110pt, node("Grafana", sub: ":13000", kind: "infra")),
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

#decision(title: [`otel-lgtm` untuk _observability_ di lab],
  [
    - Lab 8 membutuhkan _collector_, penyimpanan _trace_, _log_, metrik, dan Grafana di setiap laptop
    - RAM laptop terbatas, dan waktu lab tidak cukup untuk mengonfigurasi lima komponen
  ],
  [
    - Komponen terpisah (OTel Collector, Tempo, Loki, Prometheus, Grafana) di `compose.yaml`
    - Jaeger, khusus untuk _trace_
    - Platform _observability_ SaaS
    - `grafana/otel-lgtm`: kelima komponen tersebut dalam satu _container_
  ],
  [
    - `grafana/otel-lgtm:0.37.0` di `compose.yaml`, _port_ 13000 (Grafana) dan 14317/14318 (OTLP) di laptop
    - Service hanya mengenal `OTEL_EXPORTER_OTLP_ENDPOINT`
  ],
  [
    - Ditujukan untuk pengembangan, demo, dan _testing_. Tidak ada _high availability_ maupun kontrol akses per tim
    - Di _production_, setiap komponen dijalankan dan diskalakan sendiri (Hari 4, bagian Operasional)
    - Kode service tidak berubah saat pindah ke _stack_ terpisah, cukup alamat OTLP yang diganti
  ],
)

#slide(kicker: "Demo Grafana", title: [Mencari service yang lambat dari _waterfall_])[
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
    [Setiap baris menggambarkan satu _span_, dan baris yang menjorok adalah _child span_ dari _parent span_ di atasnya],
    [Panjang _bar_ menunjukkan durasi. `Credit` di account menghabiskan hampir seluruh waktu transfer, sehingga account yang diperiksa lebih dahulu],
    [Penyebabnya terbaca dari atribut _span_ dan dari log dengan `trace_id` yang sama, misalnya _fault delay_ yang dipasang dengan `make fault-slow` di Lab 8],
  )
  #note(kind: "tip")[Diagram di atas hanya ilustrasi. Demo sesi ini dijalankan instruktur dari tag `lab-08`, karena `otel-lgtm` baru ditambahkan ke `compose.yaml` di Lab 8.]
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
    [Di Grafana _Explore_, pilih Loki lalu _filter_ log berdasarkan `correlation_id` yang dikembalikan transfer di _header_ `X-Correlation-ID`],
    [Semua baris log dari transfer, account, dan notification untuk _request_ tersebut tampil berurutan menurut waktu],
    [Nilai `trace_id` pada baris log membuka _trace_ yang sama di Tempo],
  )
  #note[_Correlation ID_ digunakan untuk mencari log satu _request_, sedangkan `trace_id` menghubungkan log tersebut ke _span_ yang menunjukkan durasi setiap langkah.]
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
    [`rate(...[5m])` mengubah _counter_ yang terus naik menjadi laju per detik dalam rentang 5 menit],
    [p95 dihitung dari _bucket_ histogram dan berarti 95% _request_ selesai di bawah angka tersebut],
    [Bila `FAILED` atau `COMPENSATED` naik bersamaan dengan p95, periksa _trace_ pada rentang waktu yang sama],
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
    [_Transactional outbox_], [Penulisan ke DB dan _publish_ event tidak atomik], [Event wajib terkirim jika dan hanya jika data tersimpan],
    [_Idempotent consumer_], [Duplikat dari _at-least-once delivery_], [_Consumer_ mengubah data atau memicu efek ke luar],
    [_Idempotency-Key_], [Klien mengirim ulang _request_], [_Endpoint_ membuat transaksi finansial],
    [OAuth2 _client credentials_ + JWT], [Panggilan antarservice tanpa identitas], [Setiap service internal yang mengubah data],
    [_Correlation ID_ + _tracing_], [Satu transaksi tersebar di banyak log], [Satu _request_ melewati lebih dari satu service],
  )
]

#slide(kicker: "Peta concern microservices", title: [Posisi Hari 3 pada peta _concern_])[
  #let kondisi = (
    [Tiga service, masing-masing dengan database sendiri],
    [REST dari kanal, gRPC transfer ke account, event Kafka ke notification],
    [failsafe-go di klien gRPC, _reversal_ dengan _policy_ sendiri],
    [Saga dengan kompensasi, outbox, _idempotent consumer_, _Idempotency-Key_],
    [JWT di REST transfer dan gRPC account, token dari Hydra],
    [Konsep dan rancangan instrumentasi sudah dibahas, kodenya dipasang di Lab 8],
    [_Environment variable_, service berhenti bila nilai wajib kosong],
    [Alamat `localhost` dari konfigurasi],
    [Proses Go di laptop],
    [—],
  )
  #let berikutnya = (
    [—],
    [—],
    [_Probe_ dan _rolling update_ (Lab 9)],
    [_Recovery job_ di _production_],
    [TLS dan API _gateway_ di _production_],
    [Lab 8 di awal Hari 4],
    [ConfigMap dan Secret (Lab 9)],
    [Kubernetes Service (Lab 9)],
    [_Container_ dan k3d (Lab 9)],
    [_Pipeline_ (Lab 10)],
  )
  #concern-map(highlight: (2, 4, 5, 6), cols: ("concern",), size: 12pt, inset: (x: 6pt, y: 5.5pt),
    extra: (
      (header: [Kondisi studi kasus setelah Lab 7], cells: kondisi, width: 1.6fr),
      (header: [Berikutnya], cells: berikutnya, width: 1.1fr),
    ))
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
