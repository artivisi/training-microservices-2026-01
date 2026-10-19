# Studi Kasus: Sistem Simulasi Perbankan

Tiga service Go dalam satu Go _workspace_ (`go.work`), masing-masing dengan database sendiri:

| Service | Tanggung jawab | Port HTTP | Port gRPC | Database |
|---|---|---|---|---|
| `account` | Data rekening dan saldo | 28081 | 29091 (Lab 4) | `db-account`, port 15432 |
| `transfer` | Transfer antarrekening (Lab 2), _saga orchestrator_ (Lab 5) | 28082 | – | `db-transfer`, port 15433 |
| `notification` | Notifikasi hasil transfer (Lab 5) | 28083 | – | `db-notification`, port 15434 |

Port database dimulai dari 15432 agar tidak bentrok dengan PostgreSQL yang terpasang langsung di laptop.

## Menjalankan

```
make infra-up            # PostgreSQL, Kafka, Hydra, dan otel-lgtm via Docker Compose, termasuk pembuatan topic dan client OAuth2
make -C account run      # account service di http://localhost:28081
make -C transfer run     # transfer service di http://localhost:28082
make -C notification run # notification service di http://localhost:28083 (Lab 5)
make test                # unit test seluruh service (dan vet kode hasil generate proto)
make infra-down          # hentikan container, data tetap tersimpan
make infra-reset         # hentikan container dan hapus seluruh data
```

Konfigurasi service hanya dibaca dari _environment variable_. Bila ada variabel yang kosong, service berhenti saat _startup_ dengan pesan error yang menyebutkan nama variabelnya.

### Rekening contoh

Contoh transfer di README ini menggunakan rekening `1111111111` dan `2222222222`. Buat keduanya sekali setelah `account` berjalan. Datanya tetap ada di `db-account` hingga `make infra-reset`:

```
curl -X POST localhost:28081/accounts -d '{"number":"1111111111","owner_name":"Budi","initial_balance":"10000000"}'
curl -X POST localhost:28081/accounts -d '{"number":"2222222222","owner_name":"Siti","initial_balance":"5000000"}'
curl localhost:28081/accounts
```

## Resiliency (Lab 3)

`transfer` memanggil `account` melalui _policy_ failsafe-go: _timeout_ 2 detik per percobaan, _retry_ maksimal 3 kali (_backoff_ 100 ms–1 detik dengan _jitter_) hanya untuk koneksi gagal dan HTTP 503, serta _circuit breaker_ (terbuka setelah 5 gagal dari 10 panggilan terakhir, menunggu 10 detik, tertutup lagi setelah 3 panggilan uji berhasil). Di Lab 3 dan Lab 4, _timeout_ tidak di-_retry_ karena _debit_ belum _idempotent_. Mulai Lab 5, _timeout_ ikut di-_retry_ (lihat bagian Lab 5).

```
make fault-slow            # account lambat 3 detik, melewati timeout 2 detik
make fault-error RATE=0.5  # 50% request ke account dijawab 503
make fault-status          # konfigurasi fault yang aktif
make fault-clear           # account normal kembali
make breaker               # status circuit breaker di transfer: closed, open, half-open
```

Bila _circuit breaker_ terbuka sebelum _debit_, `transfer` langsung menjawab `POST /transfers` dengan HTTP 503 dan status transfer `FAILED` tanpa memanggil `account`. Saldo belum berubah, sehingga _request_ aman diulang. Bila _credit_ gagal setelah _debit_ berhasil, karena sebab apa pun termasuk _circuit breaker_ yang baru terbuka, `transfer` menjawab HTTP 502. Saldo sumber sudah berkurang dan perlu dikembalikan manual, sehingga _request_ tidak boleh diulang.

## gRPC (Lab 4)

Kontrak internal ada di modul `proto/` (`account/v1/account.proto`, _package_ `account.v1`). Kode Go hasil _generate_ ada di `proto/gen/account/v1` dan ikut di-_commit_, sehingga service bisa di-_build_ tanpa `protoc`. Setelah mengubah file `.proto`:

```
make proto     # protoc + protoc-gen-go + protoc-gen-go-grpc, hasil di proto/gen
```

Pembagian API `account`:

| API | Port | Pemanggil | Operasi |
|---|---|---|---|
| REST | 28081 | Aplikasi _channel_ | `POST /accounts`, `GET /accounts`, `GET /accounts/{number}`, _probe_, `/admin/fault` |
| gRPC | 29091 | Service lain | `GetAccount`, `Debit`, `Credit`, _health_ (`grpc.health.v1`), _reflection_ |

Endpoint REST `POST /accounts/{number}/debit` dan `/credit` sudah dihapus: perubahan saldo hanya lewat gRPC. Nominal dikirim sebagai _string_ desimal (`"150000.50"`), tidak sebagai `double`. _String_ itu hanya berisi angka dengan maksimal 2 digit desimal, tanpa tanda minus dan tanpa notasi eksponen (`"1e3"`). Format lain dijawab `INVALID_ARGUMENT`, tidak dibulatkan, karena kolom `numeric(19,2)` di PostgreSQL membulatkan digit desimal ketiga tanpa pesan apa pun. Aturan yang sama berlaku untuk `initial_balance` di `POST /accounts` dan `amount` di `POST /transfers`: lebih dari 2 digit desimal atau nilai 10^17 ke atas dijawab HTTP 400.

_Health_ gRPC (`grpc.health.v1`) tidak memeriksa database: statusnya `SERVING` sejak service berjalan hingga _shutdown_. Kesiapan menerima _traffic_ tetap ditentukan oleh `GET /readyz` di HTTP, yang memeriksa database.

_Error_ gRPC dari `account`:

| Kode | Arti | Di-_retry_ | Dihitung _circuit breaker_ |
|---|---|---|---|
| `NOT_FOUND` | Rekening tidak ada | Tidak | Tidak |
| `FAILED_PRECONDITION` | Saldo tidak cukup | Tidak | Tidak |
| `INVALID_ARGUMENT` | _Field_ tidak valid | Tidak | Tidak |
| `UNAVAILABLE` | Ditolak sebelum diproses (termasuk _fault injection_), atau koneksi gagal | Ya | Ya |
| `DEADLINE_EXCEEDED`, _timeout_ 2 detik | Jawaban terlambat, _debit_ mungkin sudah terjadi | Tidak (Lab 4), Ya (mulai Lab 5) | Ya |
| `INTERNAL`, `UNKNOWN` | _Error_ di sisi server | Tidak | Ya |
| `CANCELLED` | Pemanggil sudah berhenti menunggu (misalnya _timeout_ di sisi `transfer`) saat _request_ masih diproses. Hanya terlihat di log `account` dengan level WARN | - | - |

`transfer` membaca alamat gRPC `account` dari `ACCOUNT_GRPC_ADDR` (menggantikan `ACCOUNT_SERVICE_URL`). _Policy_ failsafe-go dari Lab 3 tetap sama, sekarang dipasang sebagai _unary client interceptor_. Di sisi server, `account` memasang dua _interceptor_: _logging_ (`grpc request` dengan `method`, `code`, `duration_ms`) dan _fault injection_. `make fault-slow` dan `make fault-error` berlaku untuk REST dan gRPC sekaligus.

## Saga, Outbox, Kafka (Lab 5)

Lab 5 dimulai dengan database kosong:

```
make infra-reset
make infra-up
```

_Unique index_ baru di tabel `mutation` gagal dibuat bila database dari Lab 1–4 berisi mutasi dengan `reference` ganda, dan `account` berhenti saat _startup_ dengan error `apply schema`. Kafka juga baru muncul di lab ini.

### Mutasi _idempotent_

Tabel `mutation` di `db-account` mendapat _unique index_ `(account_number, type, reference)`. Bila `Debit` atau `Credit` diulang dengan `reference` yang sama, `account` tidak menerapkannya lagi, menjawab sukses dengan saldo saat ini, dan mencatat log `mutation already applied, not repeated`. Karena itu `transfer` sekarang juga me-_retry_ `DEADLINE_EXCEEDED` dan _timeout_ 2 detik.

### Status transfer

| Status | Kondisi | _Event_ |
|---|---|---|
| `PENDING` | Transfer tercatat, _debit_ belum berhasil | – |
| `DEBITED` | _Debit_ rekening asal berhasil | – |
| `COMPLETED` | _Credit_ rekening tujuan berhasil | `TransferCompleted` |
| `FAILED` | _Debit_ gagal, saldo tidak berubah | `TransferFailed` |
| `COMPENSATED` | _Credit_ gagal, _debit_ dikembalikan dengan _credit_ ke rekening asal (_reference_ `<transfer_id>:reversal`) | `TransferCompensated` |
| `COMPENSATION_FAILED` | _Credit_ gagal dan pengembalian juga gagal; perlu penanganan manual (log `ERROR`) | – |

Respons HTTP `POST /transfers`:

| Kode | Kondisi |
|---|---|
| 201 | `COMPLETED` |
| 422 | Rekening tidak ada atau saldo kurang, termasuk `COMPENSATED` karena rekening tujuan tidak ada |
| 503 | _Circuit breaker_ terbuka saat _debit_ (`FAILED`) atau saat _credit_ lalu _debit_ dikembalikan (`COMPENSATED`); tidak ada uang yang berpindah, aman diulang |
| 502 | _Dependency_ gagal (`FAILED` atau `COMPENSATED`) |
| 500 | `COMPENSATION_FAILED` |

Pengembalian _debit_ (_reversal_) menggunakan _policy_ sendiri, melalui koneksi gRPC terpisah: tanpa _circuit breaker_, _retry_ dengan _backoff_ 200 ms–5 detik selama maksimal 30 detik, _reference_ tetap `<transfer_id>:reversal` sehingga pengulangan tidak menggandakan saldo. _Policy_ terpisah ini diperlukan karena _credit_ biasanya gagal saat `account` mati atau _circuit breaker_ baru terbuka. Bila _reversal_ lewat _breaker_ yang sama, _reversal_ langsung ditolak dan transfer berakhir `COMPENSATION_FAILED`. Log `retrying reversal` menandai setiap _retry_.

_Graceful shutdown_ `transfer` menunggu transfer yang sedang berjalan hingga 60 detik (`shutdownGrace` di `transfer/main.go`). Angka ini mencakup durasi terburuk satu saga: _debit_ dan _credit_ masing-masing 11,75 detik (4 percobaan × 2 detik + 3 _backoff_), _reversal_ 32 detik. Celah tetap ada bila proses dimatikan paksa (SIGKILL, _crash_) di antara dua langkah, karena baris `PENDING` atau `DEBITED` yang tertinggal tidak akan dilanjutkan. Sistem _production_ menambahkan _recovery job_ yang melanjutkan atau mengompensasi baris seperti itu.

Jika semua percobaan _debit_ atau _credit_ berakhir _timeout_, hasilnya di `account` tidak pasti, tetapi lab ini sengaja tetap menandai `FAILED` atau menjalankan kompensasi. Sistem _production_ menjalankan _reconciliation job_ yang mengulang mutasi dengan _reference_ yang sama hingga jawabannya pasti.

### _Transactional outbox_

`transfer` menulis perubahan status dan _event_-nya ke tabel `transfer` dan `outbox` di `db-transfer` dalam satu transaksi database. _Relay_ di dalam `transfer` membaca `outbox` setiap 500 ms (`for update skip locked`, maksimal 100 baris), mengirim ke Kafka, lalu mengisi `published_at`. Selama Kafka mati, transfer tetap berjalan dan _event_ tertahan di `outbox` hingga Kafka aktif kembali.

_Delivery_ bersifat _at-least-once_: bila proses berhenti setelah Kafka menerima _event_ tetapi sebelum `published_at` tersimpan, _event_ dikirim ulang.

| Atribut Kafka | Isi |
|---|---|
| _Topic_ | `transfer-events`, 3 _partition_, dibuat oleh `kafka-init` saat `make infra-up` |
| _Key_ | `transfer_id`: semua _event_ satu transfer masuk _partition_ yang sama |
| _Header_ | `event_type`, `event_id` |
| _Payload_ | `event_id`, `transfer_id`, `from_account`, `to_account`, `amount`, `status`, `reason`, `occurred_at` |

Kafka dari laptop: `localhost:19092`. Konfigurasi `transfer` menambah `KAFKA_BROKERS` dan `KAFKA_TOPIC`.

### Notification service

`notification` membaca `transfer-events` dengan _consumer group_ `notification`, menyimpan satu baris per _event_ di `db-notification`, mencatat log `notification sent`, lalu melakukan _commit offset_. Bila Kafka atau database mati, service tetap berjalan dan menunggu hingga keduanya aktif kembali.

_Event_ yang tidak mungkin diproses (_poison message_) dicatat dengan level `ERROR` lalu dilewati, dan _offset_-nya tetap di-_commit_ agar _event_ berikutnya di _partition_ yang sama tidak tertahan. _Poison message_ mencakup JSON rusak, `event_id` atau `transfer_id` yang bukan UUID, dan _error_ PostgreSQL kelas 22 (data tidak valid, misalnya `22P02`) atau 23 (_constraint_, misalnya `23502`, `23514`). _Error_ lain, seperti koneksi putus atau _timeout_, diulang terus.

```
curl "localhost:28083/notifications?transfer_id=<id>"
```

Konfigurasi: `HTTP_ADDR`, `DATABASE_URL`, `KAFKA_BROKERS`, `KAFKA_TOPIC`, `KAFKA_GROUP_ID`.

Di Lab 5, `notification` sengaja belum _idempotent_: _event_ yang dikirim ulang menghasilkan notifikasi ganda. Lab 6 memperbaikinya.

### _Make target_

```
make events    # isi topic transfer-events: partition, header, key, payload (berhenti setelah 5 detik tanpa event baru)
make outbox    # 20 baris outbox terbaru; published_at kosong = belum terkirim ke Kafka
make replay    # offset group notification kembali ke awal; hentikan notification dulu
```

Skenario uji:

| Skenario | Cara | Hasil |
|---|---|---|
| Transfer berhasil | Transfer antara dua rekening yang ada | `COMPLETED`, notifikasi "berhasil" |
| Saldo kurang | Nominal melebihi saldo | `FAILED`, HTTP 422 |
| Kompensasi | `to_account` yang tidak terdaftar, misalnya `9999999999` | `COMPENSATED`, saldo asal kembali, dua mutasi di `db-account` |
| Kafka mati | `docker compose stop kafka`, transfer, `make outbox`, `docker compose start kafka` | `published_at` kosong, terisi setelah Kafka aktif |
| _Replay_ | Hentikan `notification`, `make replay`, jalankan lagi | Lab 5: semua notifikasi tersimpan dua kali. Mulai Lab 6: tidak ada notifikasi baru |

## _Idempotency_ (Lab 6)

### _Idempotent consumer_

Tabel `processed_event` (`event_id` sebagai _primary key_) di `db-notification` mencatat setiap _event_ yang sudah diproses. Baris `processed_event` dan baris `notification` ditulis dalam satu transaksi. _Event_ dengan `event_id` yang sudah tercatat dilewati dengan log `duplicate event skipped`, lalu _offset_-nya tetap di-_commit_.

Saat `notification` dijalankan, `event_id` dari notifikasi yang tersimpan di Lab 5 ikut dimasukkan ke `processed_event`. Notifikasi ganda dari Lab 5 tetap ada di tabel `notification`; _replay_ berikutnya tidak menambah baris baru.

```
make replay       # hentikan notification dulu, lalu jalankan lagi setelah replay
make duplicates   # event dengan lebih dari satu notifikasi; kosong = tidak ada duplikat
```

### _Header_ `Idempotency-Key`

`POST /transfers` menerima _header_ `Idempotency-Key` (1–100 karakter ASCII tanpa spasi, misalnya UUID dari klien). Nilainya disimpan di kolom `transfer.idempotency_key` dengan _unique index_. _Header_ ini opsional agar _request_ dari Lab 2–5 tetap berjalan; API _channel_ di _production_ mewajibkannya.

| Kondisi | Respons |
|---|---|
| _Key_ baru | 201, _saga_ dijalankan seperti biasa |
| _Key_ sama, _body_ sama | Transfer asli dalam status terkini, _header_ `Idempotent-Replayed: true`, _saga_ tidak dijalankan lagi. Kode HTTP sama dengan respons pertama untuk status tersebut (tabel berikut) |
| _Key_ sama, _body_ berbeda (`from_account`, `to_account`, atau `amount`) | 422 |
| Format _key_ salah | 400 |
| Tanpa _header_ | 201, setiap _request_ menjadi transfer baru |

Kode HTTP untuk _request_ yang diulang (_replay_):

| Status tersimpan | Kode |
|---|---|
| `COMPLETED` | 201 |
| `FAILED`, `COMPENSATED` | 422, 503, atau 502, sesuai penyebab di `failure_reason` (tabel respons Lab 5) |
| `COMPENSATION_FAILED` | 500 |
| `PENDING`, `DEBITED` | 202: transfer pertama masih berjalan; klien memeriksa `GET /transfers/{id}` |

Dengan kode yang sama, klien yang mengulang _request_ karena respons pertama hilang mengambil keputusan yang sama seperti bila respons pertama sampai. Penyebab `FAILED` dan `COMPENSATED` dibaca kembali dari teks `failure_reason`, karena hanya kolom itu yang menyimpan penyebabnya.

Baris yang tertinggal di `PENDING` atau `DEBITED` karena proses `transfer` mati di tengah _saga_ tidak akan dilanjutkan (lihat celah di Lab 5). `transfer` terus menjawab _replay_ untuk transfer seperti itu dengan 202 dan status yang sama.

Nominal dibandingkan sebagai desimal: `"100000"` dan `"100000.00"` dianggap sama. _Request_ paralel dengan _key_ yang sama menghasilkan satu transfer.

```
curl -i -X POST localhost:28082/transfers -H 'Idempotency-Key: 7f9c2b1e-0d4a-4c1e-9b8f-1a2b3c4d5e6f' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```

Lingkup _key_ di lab ini global untuk semua klien dan tidak kedaluwarsa. Di _production_, _key_ biasanya dibatasi per klien dan dihapus setelah periode tertentu, misalnya 24 jam.

Database dari Lab 5 tidak perlu di-_reset_: tabel `processed_event` dan kolom `idempotency_key` dibuat otomatis saat service dijalankan.

## OAuth2 dan JWT (Lab 7)

Hydra (_authorization server_) dijalankan dari `compose.yaml` dengan konfigurasi siap pakai. Peserta tidak mengonfigurasi Hydra, cukup menulis verifikasi _token_ di `account` dan `transfer`.

| Endpoint Hydra | Alamat |
|---|---|
| _Token endpoint_ | `http://localhost:14444/oauth2/token` |
| JWKS (_public key_) | `http://localhost:14444/.well-known/jwks.json` |
| _Issuer_ (`iss`) | `http://localhost:14444/` (dengan garis miring di akhir) |
| Admin | `http://localhost:14445`, hanya digunakan oleh `hydra-init` |

`make infra-up` menjalankan `hydra-init` yang membuat dua _client_ dengan _grant_ `client_credentials`:

| _Client ID_ | _Secret_ | _Scope_ yang boleh diminta | Pengguna |
|---|---|---|---|
| `transfer-service` | `transfer-service-secret` | `account:read`, `account:write` | `transfer` saat memanggil gRPC `account` |
| `channel-app` | `channel-app-secret` | `transfer:read`, `transfer:write` | Aplikasi _channel_ (di lab: `curl`) |

Hydra menyimpan data di memori (`DSN=memory`): setelah Hydra di-_restart_, _client_ dan _signing key_ hilang. `make infra-up` membuat ulang _client_. `account` dan `transfer` mengambil JWKS baru saat menerima _token_ dengan `kid` yang belum dikenal (maksimal sekali per 5 detik). `transfer` meminta _token_ baru bila `account` menolak _token_ lama dengan `UNAUTHENTICATED`, lalu mengulang panggilan sekali.

### Aturan akses

| Service | Operasi | _Scope_ |
|---|---|---|
| `account` gRPC | `GetAccount` | `account:read` |
| `account` gRPC | `Debit`, `Credit` | `account:write` |
| `transfer` REST | `POST /transfers` | `transfer:write` |
| `transfer` REST | `GET /transfers/{id}` | `transfer:read` |

Tanpa _token_: `/healthz`, `/readyz`, `/debug/circuit-breaker`, gRPC _health_ dan _reflection_, `/admin/fault`, serta REST `account` (`/accounts`).

Pemeriksaan _token_: _signature_ RS256 dengan _key_ dari JWKS, `iss` sama persis dengan `OAUTH_ISSUER`, `exp` wajib ada dan belum lewat, _scope_ dari _claim_ `scp`. `aud` tidak diperiksa karena _token_ `client_credentials` dari Hydra tidak membawa `aud` kecuali diminta.

| Kondisi | REST `transfer` | gRPC `account` |
|---|---|---|
| Tanpa _token_ | 401, `WWW-Authenticate: Bearer` | `UNAUTHENTICATED` |
| _Token_ rusak, kedaluwarsa, _issuer_ lain, _signature_ salah | 401, `WWW-Authenticate: Bearer error="invalid_token"` | `UNAUTHENTICATED` |
| _Token_ valid, _scope_ kurang | 403, `WWW-Authenticate: Bearer error="insufficient_scope"` | `PERMISSION_DENIED` |

Detail penolakan (misalnya `token is expired`) hanya ada di log `request rejected` / `grpc call rejected`; respons hanya berisi `missing bearer token`, `invalid token`, atau `scope ... required`.

`transfer` mengambil _token_ `transfer-service` hanya dengan _scope_ `account:write`, menyimpannya hingga 10 detik sebelum kedaluwarsa (masa berlaku 1 jam), dan mengirimnya di _metadata_ `authorization`. Bila `transfer` gagal mengambil _token_, panggilan berakhir `UNAUTHENTICATED` tanpa _retry_ dan tanpa pengambilan _token_ kedua, serta tidak dihitung _circuit breaker_ karena `account` tidak bermasalah. Transfer berakhir `FAILED` dengan kode 502. Koneksi gRPC di lab tidak menggunakan TLS, sedangkan di _production_ pengiriman _bearer token_ wajib lewat TLS.

### Konfigurasi

| Variabel | `account` | `transfer` |
|---|---|---|
| `OAUTH_ISSUER` | Ya | Ya |
| `OAUTH_JWKS_URL` | Ya | Ya |
| `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_TOKEN_URL` | – | Ya |

Semua wajib; nilai untuk laptop ada di `Makefile` masing-masing service.

### `failure_reason`

Mulai Lab 7, `failure_reason` di respons API dan di _event_ Kafka hanya berisi alasan umum: `insufficient funds`, `account not found`, `account service unavailable` (_circuit breaker_ terbuka), atau `account service error` (penyebab lain). Contoh: `debit failed: account service error`. Pesan aslinya, misalnya alamat `dial tcp 127.0.0.1:29091`, hanya ada di log `transfer` bersama `transfer_id`.

Perubahan ini hanya berlaku untuk transfer baru. Transfer yang tersimpan sebelum Lab 7 tetap menampilkan `failure_reason` lama yang memuat pesan asli, misalnya `debit failed: debit 1111111111: rpc error: ...`. Untuk melihat format baru, buat transfer baru yang gagal. _Replay_ dengan `Idempotency-Key` lama tetap menghasilkan kode HTTP yang sama, karena kedua format diakhiri dengan pesan penyebab yang sama.

### Mencoba

```
TOKEN=$(make -s token)                       # token channel-app, scope transfer:read transfer:write
RO=$(make -s token SCOPE=transfer:read)      # token hanya-baca

curl -i -X POST localhost:28082/transfers \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'          # 401
curl -i -X POST localhost:28082/transfers -H "Authorization: Bearer $RO" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'          # 403
curl -i -X POST localhost:28082/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'          # 201
curl -H "Authorization: Bearer $RO" localhost:28082/transfers/<id>                         # 200
```

Isi _token_ dapat dibaca di https://jwt.io atau dengan `cut -d. -f2 <<<"$TOKEN" | base64 -d`. Log `account mutated` di `account` mencatat `client_id` pemanggil.

Database dari Lab 6 tidak perlu di-_reset_.

## Observability (Lab 8)

Tiga sinyal dari setiap service:

| Sinyal | Cara keluar dari service | Tujuan di `otel-lgtm` |
|---|---|---|
| Log | JSON ke _stdout_ dan OTLP gRPC ke `localhost:14317` (`otelslog`) | Loki |
| _Trace_ | OTLP gRPC ke `localhost:14317` | Tempo |
| _Metric_ | `GET /metrics` di port HTTP masing-masing, diambil Prometheus setiap 5 detik | Prometheus |

`otel-lgtm` (`grafana/otel-lgtm:0.37.0`) berisi OpenTelemetry Collector, Prometheus, Tempo, Loki, dan Grafana dalam satu _container_, khusus untuk lab. Grafana: http://localhost:13000, tanpa _login_. Data hilang bila _container_ dibuat ulang.

Prometheus di dalam _container_ mengambil `/metrics` service di laptop lewat `host.docker.internal` (`observability/prometheus.yaml`). Docker Desktop menyediakan nama ini; di Docker Engine Linux, `extra_hosts: host-gateway` di `compose.yaml` yang membuatnya. Status _scrape_: panel _Target scrape_ di _dashboard_, atau query `up` di Grafana Explore.

### Konfigurasi

| Variabel | Nilai di laptop | Keterangan |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:14317` | Wajib berupa URL `http://host:port` atau `https://host:port`; format lain menghentikan service saat _startup_ |
| `OTEL_SERVICE_NAME` | `account`, `transfer`, `notification` | Nama service di Tempo dan Loki |

Keduanya wajib di ketiga service. Service tetap berjalan walaupun Collector mati. Kegagalan kirim dicatat di _stdout_ sebagai `telemetry export failed`, lalu _span_ dan log yang gagal dikirim dibuang.

### _Correlation ID_ dan _trace context_

| Jalur | _Correlation ID_ | _Trace context_ (W3C) |
|---|---|---|
| REST | _Header_ `X-Correlation-ID`; dibuat (UUID) bila tidak ada atau formatnya salah; dikembalikan di respons | _Header_ `traceparent` (`otelhttp`) |
| gRPC `transfer` → `account` | _Metadata_ `x-correlation-id` | _Metadata_ `traceparent` (`otelgrpc`) |
| Kafka `transfer` → `notification` | _Header_ `correlation_id` | _Header_ `traceparent` |

Format _correlation ID_ yang diterima: 1–100 karakter `A-Z a-z 0-9 . _ : -`.

_Relay outbox_ berjalan setelah _request_ selesai, di _goroutine_ terpisah. Karena itu _correlation ID_ dan _trace context_ disimpan di baris `outbox` (kolom `correlation_id`, `trace_context`) dalam transaksi yang sama dengan _event_. _Relay_ membuat _span_ `publish transfer-events` sebagai _child_ dari _request_ asal, lalu `notification` membuat _span_ `process transfer-events` sebagai _child_-nya. Hasilnya, satu transfer menjadi satu _trace_ di tiga service:

```
transfer      POST /transfers
transfer        HTTP POST                              (ambil token ke Hydra, hanya bila token belum ada)
transfer        account.v1.AccountService/Debit        (client, satu span per percobaan)
account           account.v1.AccountService/Debit      (server)
transfer        account.v1.AccountService/Credit
account           account.v1.AccountService/Credit
transfer        publish transfer-events
notification      process transfer-events
```

Setiap baris log yang ditulis dalam konteks _request_ atau _event_ membawa `correlation_id`, `trace_id`, dan `span_id`:

```
{"level":"INFO","msg":"account mutated","number":"1111111111","type":"DEBIT",...,"correlation_id":"lab8-1","trace_id":"122d873a...","span_id":"c65886ff..."}
```

_Probe_ (`/healthz`, `/readyz`) dan `/metrics` tidak di-_trace_. _Publish_ yang gagal karena Kafka mati tidak menghasilkan _span_; _retry_ setiap 500 ms tercatat di log `outbox publish failed` dan di `outbox_pending`.

Atribut _span_ untuk pencarian di Tempo (TraceQL):

```
{ span.correlation.id = "lab8-1" }
{ span.transfer.id = "<transfer_id>" }
{ span.transfer.status = "FAILED" }
```

_Fault injection_ di `account` menambah _event_ `fault injected: delay` atau `fault injected: error` pada _span_ server gRPC, sehingga gangguan simulasi dapat dibedakan dari gangguan sebenarnya.

### _Metric_

| _Metric_ | Service | Label | Isi |
|---|---|---|---|
| `http_server_request_duration_seconds` | Ketiganya | `method`, `route`, `status` | _Histogram_ durasi _request_ REST; `route` = _pattern_ ServeMux (`/transfers/{id}`), `unmatched` untuk 404 dari ServeMux |
| `grpc_server_request_duration_seconds` | `account` | `method`, `code` | _Histogram_ durasi panggilan gRPC, termasuk delay _fault injection_ |
| `transfers_total` | `transfer` | `status` | Transfer yang mencapai status akhir |
| `circuit_breaker_state` | `transfer` | `target` | 0 `closed`, 1 `half-open`, 2 `open` |
| `circuit_breaker_transitions_total` | `transfer` | `target`, `from`, `to` | Jumlah perpindahan status _circuit breaker_ |
| `outbox_pending` | `transfer` | – | Baris `outbox` yang belum terkirim ke Kafka |
| `notifications_processed_total` | `notification` | `result` | `sent`, `duplicate`, `skipped` |

Ditambah _metric_ bawaan `go_*` dan `process_*`.

```
make metrics    # metric domain dari /metrics ketiga service
```

### _Dashboard_

Grafana → _Dashboards_ → folder _Studi Kasus_ → _Studi Kasus: Transfer_ (`observability/dashboards/studi-kasus.json`):

| Panel | Query utama |
|---|---|
| Transfer per status | `sum by (status) (rate(transfers_total[1m]))` |
| Latensi p95 REST per service | `histogram_quantile(0.95, ... http_server_request_duration_seconds_bucket ...)` per `job` |
| Circuit breaker transfer → account | `circuit_breaker_state{target="account"}` |
| Perubahan status circuit breaker | `increase(circuit_breaker_transitions_total[1m])` per `from`, `to` |
| Outbox pending | `outbox_pending` |
| Notifikasi per hasil | `sum by (result) (rate(notifications_processed_total[1m]))` |
| Latensi p95 gRPC account per method | `histogram_quantile(0.95, ... grpc_server_request_duration_seconds_bucket ...)` per `method` |
| Latensi p95 REST per route | Seperti latensi REST, per `route` |
| Target scrape | `up` |

Perubahan file JSON baru terbaca setelah `docker compose restart otel-lgtm`. Perubahan lewat UI Grafana tidak tersimpan ke file.

### Latihan: mencari service yang lambat

```
TOKEN=$(make -s token)
while true; do
  curl -sS -o /dev/null -w "%{http_code}\n" -X POST localhost:28082/transfers -H "Authorization: Bearer $TOKEN" \
    -d '{"from_account":"1111111111","to_account":"2222222222","amount":"1000"}'
  sleep 0.5
done
```

Di terminal lain:

```
make fault-slow     # account menahan setiap panggilan 3 detik
make breaker        # setelah beberapa transfer: {"account":"open"}
make metrics
make fault-clear
```

| Langkah | Tempat | Yang terlihat |
|---|---|---|
| 1 | _Dashboard_ | Latensi p95 gRPC `Debit` naik ke sekitar 2 detik (panggilan diputus _timeout_ 2 detik dari `transfer`), lalu _circuit breaker_ `OPEN`, `FAILED` naik, respons berubah dari 201 ke 502 lalu 503 |
| 2 | Explore → Tempo, query `{ span.transfer.status = "FAILED" }` | _Trace_ dengan empat _span_ `Debit` sekitar 2 detik: satu percobaan ditambah tiga _retry_. _Span_ server di `account` sama panjangnya dan membawa _event_ `fault injected: delay` |
| 3 | Explore → Loki, query `{service_name=~"account\|transfer\|notification"} \| trace_id="<trace_id>"` | Log `retrying account call` dan `transfer not completed` dari _trace_ yang sama |
| 4 | _Dashboard_, setelah `make fault-clear` | _Circuit breaker_ `HALF-OPEN` lalu `CLOSED`, transfer kembali `COMPLETED` |

Transfer yang ditolak _circuit breaker_ yang terbuka hanya memiliki _span_ `POST /transfers` tanpa _span_ `Debit`: panggilan ke `account` tidak pernah dikirim.

Database dari Lab 7 tidak perlu di-_reset_: kolom `correlation_id` dan `trace_context` di tabel `outbox` dibuat otomatis saat `transfer` dijalankan. `make infra-up` menambah _container_ `otel-lgtm`.

## Container dan k3d (Lab 9)

### _Image_

Setiap service memiliki `Dockerfile` di direktorinya sendiri. _Build context_-nya tetap direktori `studi-kasus/` karena `go.mod` `account` dan `transfer` mengarah ke `../proto` lewat _replace directive_. `notification` tidak menggunakan `proto` (_event_ dikirim sebagai JSON di Kafka), jadi `Dockerfile`-nya hanya menyalin `notification/`; _build context_-nya tetap sama agar ketiga _image_ di-_build_ dengan perintah yang sama.

| Tahap | Isi |
|---|---|
| _Builder_ | `golang:1.27.2-alpine`, `GOWORK=off` (hanya modul service, ditambah `proto` untuk `account` dan `transfer`), `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"` |
| Akhir | `FROM scratch`: _binary_ statis dan sertifikat CA, tanpa _shell_. Ukuran sekitar 8–9 MB terkompresi. Docker dengan _containerd image store_ (Docker Engine 29, Docker Desktop versi baru) menampilkan dua kolom di `docker images`: `CONTENT SIZE` sekitar 8–9 MB dan `DISK USAGE` sekitar 31–34 MB (terkompresi ditambah hasil ekstrak). _Image store_ klasik menampilkan satu kolom `SIZE` sekitar 21–23 MB |
| _User_ | `65532:65532` (numerik). Tetap berjalan dengan UID lain (OpenShift _restricted SCC_) dan _root filesystem_ _read-only_ |

```
make images VERSION=1.0.0     # studi-kasus/account:1.0.0, studi-kasus/transfer:1.0.0, studi-kasus/notification:1.0.0
```

`VERSION` wajib diisi; tanpa `VERSION`, `make` berhenti dengan pesan error. `make` tidak mencegah _build_ ulang dengan _tag_ yang sudah ada, tetapi _image_ hasil _build_ ulang itu tidak pernah sampai ke _pod_: Deployment menggunakan `imagePullPolicy: IfNotPresent`, dan referensi _image_ yang tidak berubah tidak memicu _rollout_. Beri `VERSION` baru untuk setiap perubahan kode (`1.0.1`, `1.0.2`, ...), lalu `make k3d-import` dengan `VERSION` itu dan `kubectl set image` atau `newTag` di `overlays/k3d/kustomization.yaml` (lihat Latihan).

### Seluruh sistem di Docker Compose

_Profile_ `apps` di `compose.yaml` menjalankan ketiga service sebagai _container_ dengan alamat _compose service_ (`db-account:5432`, `kafka:29092`, `hydra:4444`, `otel-lgtm:4317`) dan _root filesystem_ _read-only_. Hentikan service yang dijalankan dengan `make -C <service> run` terlebih dahulu karena port 28081–28083 sama.

```
make infra-up
make apps-up      # build image lalu jalankan account, transfer, notification
make apps-down    # hentikan dan hapus container ketiga service
```

### k3d

Hanya ketiga service yang berjalan di _cluster_. PostgreSQL, Kafka, Hydra, dan `otel-lgtm` tetap di Docker Compose (`make infra-up`). _Pod_ menjangkau laptop lewat nama `host.k3d.internal`, yang ditambahkan k3d ke DNS _cluster_.

| Infrastruktur | Alamat dari _pod_ |
|---|---|
| PostgreSQL | `host.k3d.internal:15432`, `15433`, `15434` |
| Kafka | `host.k3d.internal:19093` (_listener_ `K3D` di `compose.yaml`) |
| Hydra | JWKS dan _token endpoint_ di `http://host.k3d.internal:14444`; `OAUTH_ISSUER` tetap `http://localhost:14444/` karena nilai `iss` di _token_ selalu alamat itu |
| OTLP | `http://host.k3d.internal:14317` |
| `account` gRPC | `account:9091` (Service di _namespace_ yang sama) |

Kafka mendapat _listener_ ketiga karena _listener_ `localhost:19092` di-_advertise_ dengan alamat `localhost`, dan dari dalam _pod_, `localhost` merujuk ke _pod_ itu sendiri.

```
make infra-up
make images VERSION=1.0.0
make k3d-up                        # cluster "bank", rancher/k3s:v1.36.5-k3s1, port 28080 laptop ke Traefik, tunggu DNS host.k3d.internal
make k3d-import VERSION=1.0.0      # salin image ke cluster, tanpa registry
make k8s-apply                     # kubectl apply -k k8s/overlays/k3d, lalu tunggu rollout ketiga Deployment
make k3d-down                      # hapus cluster
```

Hentikan service yang berjalan di laptop (`make -C <service> run`) atau di _profile_ `apps` sebelum `make k8s-apply`. Kalau tidak, dua `notification` berbagi _partition_ dalam satu _consumer group_ dan dua _relay outbox_ membaca database yang sama.

k3d menulis `host.k3d.internal` ke ConfigMap CoreDNS, tetapi CoreDNS baru menjawab nama itu setelah ConfigMap sampai ke _pod_-nya, hingga sekitar satu menit kemudian. `make k3d-up` menunggu hingga nama itu terjawab, sehingga `make k8s-apply` sesudahnya tidak menghasilkan _restart_.

Setelah Docker atau laptop di-_restart_, _container_ _cluster_ berjalan lagi tanpa `host.k3d.internal` di DNS _cluster_. _Pod_ masuk `CrashLoopBackOff` dengan log `lookup host.k3d.internal ... no such host`. Jalankan `k3d cluster stop bank` lalu `k3d cluster start bank`: k3d menulis nama itu lagi, dan _pod_ berjalan normal setelah satu sampai dua menit tanpa perintah tambahan.

### Manifest

```
k8s/
  base/                 sama di semua environment
    account/            configmap, secret (kosong), deployment, service
    transfer/           configmap, secret (kosong), deployment, service, ingress
    notification/       configmap, secret (kosong), deployment, service
  overlays/k3d/         namespace bank, alamat infrastruktur, credential lab, tag image
```

| Objek | Isi |
|---|---|
| ConfigMap | _Key_ yang sama di semua _environment_ di `base` (`HTTP_ADDR`, `GRPC_ADDR`, `ACCOUNT_GRPC_ADDR`, `OTEL_SERVICE_NAME`); alamat infrastruktur ditambahkan `overlays/k3d/config.yaml` |
| Secret | Kosong di `base`; `DATABASE_URL` dan `OAUTH_CLIENT_SECRET` diisi `overlays/k3d/secrets.yaml`. _Credential_ lab ini ikut di-_commit_ hanya karena tidak melindungi apa pun di luar laptop |
| Deployment | 1 _replica_, `envFrom` ConfigMap + Secret, _readiness_ `/readyz`, _liveness_ `/healthz`, _resource request_ dan _limit_, _rolling update_ `maxSurge: 1`, `maxUnavailable: 0`, `preStop` _sleep_ 5 detik, `terminationGracePeriodSeconds` 30 (`transfer` 75) |
| _Security context_ | `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, tanpa `runAsUser` |
| Service | ClusterIP: `account` 8081 dan 9091, `transfer` 8082, `notification` 8083 |
| Ingress | Hanya `transfer`, _path_ `/transfers`, `ingressClassName: traefik` |

Saat _pod_ dihentikan (_rolling update_, _scale down_), Kubernetes menghentikan _pod_ dan mengeluarkannya dari _endpoint_ Service dan Ingress secara bersamaan. Selama beberapa detik _request_ baru masih datang. `preStop` dengan aksi `sleep` (Kubernetes 1.30+, tidak memerlukan _shell_, yang memang tidak ada di _image_ `scratch`) menunda SIGTERM 5 detik hingga _pod_ tidak lagi menerima _request_ baru; setelah itu _graceful shutdown_ di `main.go` menyelesaikan _request_ yang sedang berjalan. `terminationGracePeriodSeconds` dihitung sejak `preStop` dimulai dan harus mencakup `preStop` + batas _shutdown_ service + _flush_ telemetri 5 detik: `account` dan `notification` 5 + 10 + 5 detik, `transfer` 5 + 60 + 5 detik (`shutdownGrace`, agar _saga_ tidak terpotong). Bila batas itu terlampaui, _kubelet_ mengirim SIGKILL. Di _profile_ `apps`, `stop_grace_period: 70s` memberi `transfer` waktu yang sama di Docker Compose.

Bila sebuah _key_ tidak ada di ConfigMap maupun Secret, service berhenti saat _startup_ (`missing required environment variables: ...`) dan _pod_ masuk `CrashLoopBackOff`.

```
kubectl kustomize k8s/overlays/k3d    # hasil render tanpa apply
```

### Mencoba

```
kubectl -n bank get pods,svc,ingress
kubectl -n bank port-forward svc/account 28081:8081    # terminal lain: REST account, make fault-*
TOKEN=$(make -s token)
curl -i -X POST localhost:28080/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
kubectl -n bank logs deploy/transfer
```

Rekening dari lab sebelumnya tetap ada karena `account` di k3d menggunakan `db-account` yang sama. `/debug/circuit-breaker`, `/metrics`, dan `GET /notifications` tidak lewat Ingress: gunakan `kubectl -n bank port-forward svc/transfer 28082:8082` atau `svc/notification 8083:8083`.

### Latihan: mengubah manifest

| Latihan | Perintah | Yang diamati |
|---|---|---|
| _Scale_ | `kubectl -n bank scale deployment/notification --replicas=3` | Tiga _pod_ berbagi tiga _partition_. Dengan `--replicas=4`, satu _pod_ tidak mendapat _partition_ dan tidak memproses _event_ |
| Ubah konfigurasi | Hapus `KAFKA_GROUP_ID` dari ConfigMap `notification` di `overlays/k3d/config.yaml`, `kubectl apply -k k8s/overlays/k3d`, `kubectl -n bank rollout restart deployment/notification` | _Pod_ baru `CrashLoopBackOff`, `kubectl -n bank logs` menyebut variabel yang kosong; _pod_ lama tetap melayani karena `maxUnavailable: 0`. Kembalikan nilainya, _apply_ lagi, lalu `kubectl -n bank rollout restart deployment/notification`: _pod_ yang `CrashLoopBackOff` baru mencoba lagi setelah jeda _backoff_ (sampai 5 menit), sedangkan `rollout restart` langsung membuat _pod_ baru |
| _Rolling update_ | `make images VERSION=1.0.1`, `make k3d-import VERSION=1.0.1`, `kubectl -n bank set image deployment/transfer transfer=studi-kasus/transfer:1.0.1`, `kubectl -n bank rollout status deployment/transfer` | _Pod_ baru dibuat dan menjadi _ready_ sebelum _pod_ lama dihentikan. _Build_ ulang dengan _tag_ `1.0.0` yang sama tidak memicu _rollout_. Alternatif: ubah `newTag` di `overlays/k3d/kustomization.yaml` lalu `kubectl apply -k` |
| _Rollback_ | `kubectl -n bank rollout undo deployment/transfer` | Kembali ke `1.0.0` |

Perubahan ConfigMap atau Secret tidak dibaca _pod_ yang sedang berjalan karena _environment variable_ hanya dibaca saat _startup_: jalankan `kubectl rollout restart`.

### HPA (opsional)

`k8s/hpa/transfer.yaml` menambah dan mengurangi _replica_ `transfer` antara 1 dan 4 berdasarkan CPU: rata-rata di atas 70% dari `requests.cpu` (50m) memicu penambahan _pod_. Metriknya berasal dari _metrics-server_ bawaan k3s. HPA ini terpisah dari _overlay_ k3d, sehingga Lab 9 dan Lab 10 berjalan tanpanya.

Jalankan di tiga terminal setelah `make k8s-apply`:

```bash
make hpa-apply                              # terminal 1: pasang HPA, tampilkan kubectl top pods
make hpa-watch                              # terminal 2: kolom TARGETS dan REPLICAS
make hpa-load DURATION=180 CONCURRENCY=10   # terminal 3: transfer lewat Ingress selama 180 detik
```

Kolom `TARGETS` menampilkan `<unknown>/70%` sampai _metrics-server_ memiliki sampel pertama (sekitar satu menit). Selama beban berjalan, `REPLICAS` naik dari 1. Sekitar 60 detik setelah beban berhenti, `REPLICAS` turun kembali ke 1 (`behavior.scaleDown` di _manifest_). `make hpa-delete` menghapus HPA dan mengembalikan `transfer` ke 1 _replica_.

`make k8s-apply` berikutnya mengisi `replicas: 1` dari `base`, lalu HPA menaikkannya lagi pada pemeriksaan berikutnya. Di _production_, _field_ `replicas` dihapus dari Deployment yang dikelola HPA.

### Batasan di lab

| Hal | Keterangan |
|---|---|
| _Metric_ | Prometheus di `otel-lgtm` hanya mengambil port 28081–28083 di laptop. _Metric_ _pod_ di k3d tidak terambil; _trace_ dan log tetap masuk lewat OTLP |
| gRPC dan Service | ClusterIP melakukan _load balancing_ saat koneksi dibuat, lalu semua panggilan di koneksi itu menuju _pod_ yang sama. Setelah `account` di-_scale_, panggilan dari satu _pod_ `transfer` tetap ke _pod_ `account` yang sama |
| _Circuit breaker_ | Per _pod_ `transfer`; tiap _replica_ memiliki status sendiri |
| Secret | Disimpan di repository khusus untuk lab. Di _production_, Secret berasal dari _vault_ atau _secret operator_ |

Database dari Lab 8 tidak perlu di-_reset_. `make infra-up` membuka port 19093 untuk _listener_ Kafka `K3D`.

## CI/CD (Lab 10)

Setiap service memiliki _pipeline_ sendiri. _Commit_ yang mengubah `account` hanya menjalankan _pipeline_ `account`.

| File | Fungsi |
|---|---|
| `../.forgejo/workflows/<service>.yaml` | _Workflow_ untuk git server dan runner CI di server pelatihan |
| `<service>/Jenkinsfile` | _Declarative pipeline_ Jenkins dengan _stage_ dan _make target_ yang sama, untuk pemetaan ke Bitbucket + Jenkins |
| `pipeline.mk` | _Target_ `image`, `push`, `apply`, `deploy`, di-_include_ oleh `Makefile` setiap service |
| `k8s/overlays/server/` | _Overlay_ untuk server pelatihan: satu _namespace_ per peserta, infrastruktur bersama |

### Tahapan

| _Step_ _workflow_ | _Stage_ Jenkins | Perintah |
|---|---|---|
| Checkout | (SCM bawaan Jenkins) | `git fetch` _commit_ yang memicu _pipeline_ dengan _token_ dari runner |
| Test | Test | `make -C studi-kasus/<service> test` |
| Build image | Build Image | `make -C studi-kasus/<service> image` |
| Push | Push | `make -C studi-kasus/<service> push` |
| Deploy | Deploy | `make -C studi-kasus/<service> deploy` |

_Workflow_ hanya berisi _step_ `run:` tanpa `uses:`, sehingga setiap _step_ setara satu _stage_ Jenkins dan perintah yang sama bisa dijalankan di laptop.

_Trigger_: _push_ ke `main` yang mengubah direktori service, `proto/` (khusus `account` dan `transfer`), `go.work`, `pipeline.mk`, atau file _workflow_ itu sendiri.

_Pipeline_ setiap service berjalan satu per satu. _Workflow_ menggunakan `concurrency` dengan `cancel-in-progress: false`: _push_ berikutnya menunggu _pipeline_ yang sedang berjalan selesai. Di Jenkins padanannya `disableConcurrentBuilds()`.

Job Jenkins harus bertipe _Multibranch Pipeline_. Kondisi `when { branch 'main' }` membaca `BRANCH_NAME`, dan variabel ini hanya diisi oleh job _Multibranch_. _Stage_ Test berhenti lebih awal bila `GIT_COMMIT` kosong, sehingga tidak ada _image_ dengan _tag_ `null`. Kondisi `changeset` membandingkan _build_ dengan _build_ sebelumnya, termasuk yang gagal: _build_ pertama sebuah _branch_ dan _build_ ulang setelah kegagalan melewati semua _stage_. _Build Now_ (`triggeredBy 'UserIdCause'`) menjalankan semua _stage_ untuk _commit_ terakhir.

### Variabel

Tidak ada nilai _default_. Bila ada variabel yang kosong, `make` berhenti dengan pesan `missing required variables: ...`.

| Variabel | Digunakan oleh | Sumber di _workflow_ | Sumber di Jenkins |
|---|---|---|---|
| `REGISTRY` | `image`, `push`, `apply`, `deploy` | _Variable_ repository `REGISTRY` | _Environment variable_ folder/global |
| `IMAGE_OWNER` | `image`, `push`, `apply`, `deploy` | Pemilik repository | _Environment variable_ folder/global |
| `VERSION` | `image`, `push`, `apply`, `deploy` | SHA _commit_ | `GIT_COMMIT` |
| `NAMESPACE` | `apply`, `deploy` | _Variable_ repository `NAMESPACE` | _Environment variable_ folder/global |
| `REGISTRY_USER`, `REGISTRY_PASSWORD` | `push` | _Secret_ repository | _Credential_ `registry` (_username with password_) |
| `KUBECONFIG` | `apply`, `deploy` | _Secret_ `KUBE_CONFIG`, ditulis ke file sementara | _Credential_ `kubeconfig` (_secret file_) |

Nama _image_: `<REGISTRY>/<IMAGE_OWNER>/<service>:<VERSION>`. Setiap _commit_ menghasilkan _tag_ baru, sehingga _tag_ lama tidak pernah tertimpa dan _image_ yang berjalan bisa ditelusuri ke _commit_-nya (_label_ `org.opencontainers.image.revision`).

`push` menjalankan `docker login` dengan `DOCKER_CONFIG` sementara yang dihapus di akhir _step_, sehingga _token_ registry tidak tertinggal di `~/.docker/config.json` milik runner setelah job selesai. Langkah ini tidak mengisolasi peserta satu sama lain. Runner digunakan bersama oleh semua peserta, dan siapa pun yang bisa mengubah _workflow_ bisa menjalankan perintah apa saja di host runner. Setelah _push_ berhasil, _image_ lokal dihapus agar disk runner tidak penuh oleh satu _image_ per _commit_ per peserta.

`deploy` menjalankan `kubectl set image` lalu `kubectl rollout status`, sama seperti latihan _rolling update_ di Lab 9. Anotasi `kubernetes.io/change-cause` dipasang setelah `set image` dan mencatat versi di `kubectl rollout history`. _Rollout_ yang gagal menggagalkan _pipeline_; _pod_ lama tetap melayani (`maxUnavailable: 0`). _Rollback_ dilakukan manual dengan `kubectl rollout undo`.

Bila Deployment service belum ada di _namespace_, `deploy` terlebih dahulu menjalankan _target_ `apply`: _overlay_ `k8s/overlays/server` di-_apply_ dengan _namespace_ `NAMESPACE` dan _image_ `<REGISTRY>/<IMAGE_OWNER>/<service>:<VERSION>`, hanya untuk objek service itu (`kubectl apply -l app.kubernetes.io/name=<service>`). _Pipeline_ pertama setiap service membuat ConfigMap, Service, Deployment, dan Ingress-nya sendiri dari _namespace_ kosong.

### Server pelatihan

| Hal | Isi |
|---|---|
| _Cluster_ | Satu _node_, satu _namespace_ per peserta, _kubeconfig_ dengan RBAC terbatas pada _namespace_ itu |
| _Image_ | Di-_pull_ dari _container registry_ git server dengan Secret `registry-credentials` (`imagePullSecrets`) |
| PostgreSQL | Bersama, database per peserta per service. `DATABASE_URL` ada di Secret yang dibuat instruktur, tidak di repository |
| Kafka | Bersama, _topic_ dan _consumer group_ diberi _prefix_ nama peserta |
| OAuth2, OTLP | Bersama |
| Ingress | _Host_ per peserta |

`k8s/overlays/server` tidak berisi _namespace_ dan _tag image_. Keduanya berasal dari variabel _pipeline_, sehingga tidak perlu _apply_ manual sebelum _pipeline_ pertama. Instruktur menyiapkan _namespace_, _kubeconfig_, Secret service, dan Secret `registry-credentials`. Nilai `replace-me` di `config.yaml` dan `ingress.yaml` diisi peserta dengan alamat dari instruktur; `deploy` dan `k8s-apply-server` tidak dapat dijalankan selama masih ada `replace-me`.

Setelah Deployment ada, _pipeline_ hanya mengganti _image_. Perubahan `config.yaml` atau `ingress.yaml` dikirim ke _cluster_ dengan `k8s-apply-server`, satu service per perintah, dengan `VERSION` = _commit_ yang sedang berjalan:

```
kubectl -n <namespace> rollout history deployment/transfer     # versi yang sedang berjalan
make k8s-apply-server SERVICE=transfer VERSION=<sha> REGISTRY=<registry> IMAGE_OWNER=<pemilik> NAMESPACE=<namespace>
kubectl -n <namespace> rollout restart deployment/transfer     # pod membaca ConfigMap hanya saat start
```

Perubahan manual seperti ini membuat isi _cluster_ berbeda dari isi repository (_drift_). GitOps menghilangkan _drift_ dengan mewajibkan setiap perubahan _cluster_ dilakukan lewat repository.

### Mencoba di laptop

`pipeline-k3d` menjalankan tahapan _pipeline_ untuk satu service terhadap k3d dari Lab 9. `push` diganti `k3d image import` karena laptop tidak memiliki registry.

```
make infra-up                                 # infrastruktur di Docker Compose
k3d cluster get bank || make k3d-up           # cluster Lab 9 digunakan lagi bila sudah ada
make images VERSION=1.0.0
make k3d-import VERSION=1.0.0
make k8s-apply                                # manifest Lab 9, image 1.0.0
# ubah kode transfer, lalu commit
make pipeline-k3d SERVICE=transfer            # test, image, import, deploy dengan tag = commit
kubectl -n bank rollout history deployment/transfer
kubectl -n bank get deploy transfer -o jsonpath='{.spec.template.spec.containers[0].image}'
```

_Cluster_ yang dihentikan dengan `k3d cluster stop bank` dijalankan lagi dengan `k3d cluster start bank`. _Tag_ diambil dari _commit_ saat ini, sehingga `pipeline-k3d` tidak dapat dijalankan selama ada perubahan yang belum di-_commit_ di `studi-kasus/`. `make k8s-apply` setelahnya mengembalikan _image_ ke _tag_ di `overlays/k3d`.

### GitHub Actions

_Pipeline_ yang sama berjalan di GitHub Actions. Hasil setiap _run_ dapat dibuka publik di https://github.com/artivisi/training-microservices-2026-01/actions.

| _Workflow_ | Isi |
|---|---|
| `../.github/workflows/<service>.yaml` | _Step_ Checkout, Install tools, Test, Build image, Push dengan _target_ `make` yang sama. _Image_ dikirim ke `ghcr.io/<pemilik repository>/<service>:<sha>` dengan `GITHUB_TOKEN`. Tanpa _step_ Deploy karena _runner_ GitHub tidak memiliki _cluster_ |
| `../.github/workflows/e2e-k3d.yaml` | Lab 9 di k3d pada _runner_ (`infra-up`, `images`, `k3d-up`, `k3d-import`, `k8s-apply`), lalu `make e2e-smoke` dan `make e2e-rolling-update` |

`Install tools` (`../.github/install-tools.sh`) memasang Go, k3d, dan kubectl dengan versi dari panduan persiapan dan memeriksa SHA-256 setiap unduhan. Runner git server dan Jenkins tidak memerlukan _step_ ini karena _tools_ tersebut sudah terpasang di host.

| _Target_ | Isi |
|---|---|
| `e2e-smoke` | Dua rekening baru, `POST /transfers` lewat Ingress (`localhost:28080`) harus 201 `COMPLETED`, lalu baris notifikasinya harus muncul di `db-notification` |
| `e2e-rolling-update` | `make pipeline-k3d SERVICE=transfer` sambil mengirim transfer lewat Ingress setiap 0,2 detik. Gagal bila ada respons selain 2xx. Mencetak `kubectl rollout history` |
| `e2e-dump` | Pod, _event_, log ketiga service, dan `docker compose logs`, dijalankan saat _workflow_ gagal |

Ketiga _target_ ini juga bisa dijalankan di laptop setelah `make k8s-apply`. Seperti `pipeline-k3d`, `e2e-rolling-update` tidak dapat dijalankan selama ada perubahan yang belum di-_commit_ di `studi-kasus/`.

### Status

| Bagian | Status |
|---|---|
| _Target_ `image`, `push`, `deploy` | Siap |
| `pipeline-k3d` | Siap |
| _Workflow_ | Berjalan di runner CI pusat server pelatihan: Test, Build image, Push ke registry git server, dan _deploy_ ke _namespace_ peserta, termasuk _rolling update_ |
| `Jenkinsfile` | Diuji di Jenkins LTS 2.580.1 (_Multibranch Pipeline_, sumber Git) dengan _deploy_ ke k3d: filter _path_ per service, _deploy_ pertama dari _namespace_ kosong, _rolling update_, `disableConcurrentBuilds()`, variabel kosong menghentikan `make` |
| `apply` (Deployment pertama dari _namespace_ kosong) | Diuji di k3d pada Docker Engine Linux: _namespace_ kosong, _kubeconfig_ dengan RBAC satu _namespace_, _image_ di-_pull_ dari registry dengan _basic auth_ lewat `registry-credentials`, lalu _deploy_ kedua (hanya `set image`) dan `k8s-apply-server`. Juga diuji di server pelatihan |
| _Workflow_ GitHub Actions dan `e2e-k3d` | Berjalan di GitHub Actions: Test, Build image, Push ke `ghcr.io`, dan _rolling update_ `transfer` di k3d tanpa respons selain 2xx |
| Runner CI pusat dan server pelatihan | Diuji _end-to-end_: _push_ hingga _rolling update_, isolasi antarpeserta, dan dua peserta melakukan _push_ bersamaan. Nilai `replace-me` di `k8s/overlays/server` dibagikan di `~/lab10.txt` pada server pelatihan |

## Checkpoint

_Tag_ `lab-01` … `lab-10` berisi kondisi kode di akhir setiap lab. Peserta yang tertinggal melanjutkan dari _tag_ lab sebelumnya:

```
git checkout lab-03
```
