# Studi Kasus: Sistem Simulasi Perbankan

Tiga service Go dalam satu Go _workspace_ (`go.work`), masing-masing dengan database sendiri:

| Service | Tanggung jawab | Port HTTP | Port gRPC | Database |
|---|---|---|---|---|
| `account` | Data rekening dan saldo | 8081 | 9091 (Lab 4) | `db-account`, port 15432 |
| `transfer` | Transfer antar rekening (Lab 2), _saga orchestrator_ (Lab 5) | 8082 | – | `db-transfer`, port 15433 |
| `notification` | Notifikasi hasil transfer (Lab 5) | 8083 | – | `db-notification`, port 15434 |

Port database dimulai dari 15432 agar tidak bentrok dengan PostgreSQL yang terpasang langsung di laptop.

## Menjalankan

```
make infra-up            # PostgreSQL, Kafka, Hydra, dan otel-lgtm via Docker Compose, termasuk pembuatan topic dan client OAuth2
make -C account run      # account service di http://localhost:8081
make -C transfer run     # transfer service di http://localhost:8082
make -C notification run # notification service di http://localhost:8083 (Lab 5)
make test                # unit test seluruh service (dan vet kode hasil generate proto)
make infra-down          # hentikan container, data tetap tersimpan
make infra-reset         # hentikan container dan hapus seluruh data
```

Konfigurasi service hanya dibaca dari _environment variable_. Variabel yang kosong menghentikan service saat _startup_ dengan pesan error yang menyebutkan nama variabelnya.

### Rekening contoh

Contoh transfer di README ini memakai rekening `1111111111` dan `2222222222`. Buat keduanya sekali setelah `account` berjalan. Datanya tetap ada di `db-account` sampai `make infra-reset`:

```
curl -X POST localhost:8081/accounts -d '{"number":"1111111111","owner_name":"Budi","initial_balance":"10000000"}'
curl -X POST localhost:8081/accounts -d '{"number":"2222222222","owner_name":"Siti","initial_balance":"5000000"}'
curl localhost:8081/accounts
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

Saat _circuit breaker_ terbuka sebelum _debit_, `POST /transfers` langsung dijawab HTTP 503 dengan status transfer `FAILED` tanpa memanggil `account`: belum ada saldo yang berubah, sehingga _request_ aman diulang. Jika _debit_ sudah berhasil lalu _credit_ gagal karena sebab apa pun, termasuk _circuit breaker_ yang baru terbuka, jawabannya HTTP 502: saldo sumber sudah berkurang dan perlu dikembalikan manual, sehingga _request_ tidak boleh diulang.

## gRPC (Lab 4)

Kontrak internal ada di modul `proto/` (`account/v1/account.proto`, _package_ `account.v1`). Kode Go hasil _generate_ ada di `proto/gen/account/v1` dan ikut di-_commit_, sehingga service bisa di-_build_ tanpa `protoc`. Setelah mengubah file `.proto`:

```
make proto     # protoc + protoc-gen-go + protoc-gen-go-grpc, hasil di proto/gen
```

Pembagian API `account`:

| API | Port | Pemanggil | Operasi |
|---|---|---|---|
| REST | 8081 | Aplikasi _channel_ | `POST /accounts`, `GET /accounts`, `GET /accounts/{number}`, _probe_, `/admin/fault` |
| gRPC | 9091 | Service lain | `GetAccount`, `Debit`, `Credit`, _health_ (`grpc.health.v1`), _reflection_ |

Endpoint REST `POST /accounts/{number}/debit` dan `/credit` sudah dihapus: perubahan saldo hanya lewat gRPC. Nominal dikirim sebagai _string_ desimal (`"150000.50"`), bukan `double`: hanya angka dengan paling banyak 2 digit desimal, tanpa tanda minus dan tanpa notasi eksponen (`"1e3"`). Format lain dijawab `INVALID_ARGUMENT`, tidak dibulatkan, karena kolom `numeric(19,2)` di PostgreSQL membulatkan digit desimal ketiga tanpa pesan apa pun. Aturan yang sama berlaku untuk `initial_balance` di `POST /accounts` dan `amount` di `POST /transfers`: lebih dari 2 digit desimal atau nilai 10^17 ke atas dijawab HTTP 400.

_Health_ gRPC (`grpc.health.v1`) tidak memeriksa database: statusnya `SERVING` sejak service berjalan sampai _shutdown_. Kesiapan menerima _traffic_ tetap ditentukan oleh `GET /readyz` di HTTP, yang memeriksa database.

_Error_ gRPC dari `account`:

| Kode | Arti | Di-_retry_ | Dihitung _circuit breaker_ |
|---|---|---|---|
| `NOT_FOUND` | Rekening tidak ada | Tidak | Tidak |
| `FAILED_PRECONDITION` | Saldo tidak cukup | Tidak | Tidak |
| `INVALID_ARGUMENT` | _Field_ tidak valid | Tidak | Tidak |
| `UNAVAILABLE` | Ditolak sebelum diproses (termasuk _fault injection_), atau koneksi gagal | Ya | Ya |
| `DEADLINE_EXCEEDED`, _timeout_ 2 detik | Jawaban terlambat, _debit_ mungkin sudah terjadi | Tidak (Lab 4), Ya (mulai Lab 5) | Ya |
| `INTERNAL`, `UNKNOWN` | Kesalahan di server | Tidak | Ya |
| `CANCELLED` | Pemanggil sudah berhenti menunggu (misalnya _timeout_ di sisi `transfer`) saat _request_ masih diproses. Hanya terlihat di _log_ `account` sebagai WARN, bukan ERROR | - | - |

`transfer` membaca alamat gRPC `account` dari `ACCOUNT_GRPC_ADDR` (menggantikan `ACCOUNT_SERVICE_URL`). _Policy_ failsafe-go dari Lab 3 tetap sama, sekarang dipasang sebagai _unary client interceptor_. Di sisi server, `account` memasang dua _interceptor_: _logging_ (`grpc request` dengan `method`, `code`, `duration_ms`) dan _fault injection_. `make fault-slow` dan `make fault-error` berlaku untuk REST dan gRPC sekaligus.

## Saga, Outbox, Kafka (Lab 5)

Lab 5 dimulai dengan database kosong:

```
make infra-reset
make infra-up
```

_Unique index_ baru di tabel `mutation` gagal dibuat bila database dari Lab 1–4 berisi mutasi dengan `reference` ganda, dan `account` berhenti saat _startup_ dengan error `apply schema`. Kafka juga baru muncul di lab ini.

### Mutasi _idempotent_

Tabel `mutation` di `db-account` mendapat _unique index_ `(account_number, type, reference)`. `Debit` atau `Credit` yang diulang dengan `reference` yang sama tidak diterapkan lagi; `account` menjawab sukses dengan saldo saat ini dan mencatat log `mutation already applied, not repeated`. Karena itu `transfer` sekarang juga me-_retry_ `DEADLINE_EXCEEDED` dan _timeout_ 2 detik.

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

Pengembalian _debit_ (_reversal_) memakai _policy_ sendiri, melalui koneksi gRPC terpisah: tanpa _circuit breaker_, _retry_ dengan _backoff_ 200 ms–5 detik selama maksimal 30 detik, _reference_ tetap `<transfer_id>:reversal` sehingga pengulangan tidak menggandakan saldo. Alasannya: _credit_ biasanya gagal karena `account` mati atau _circuit breaker_ baru terbuka. Bila _reversal_ lewat _breaker_ yang sama, _reversal_ langsung ditolak dan transfer berakhir `COMPENSATION_FAILED`. _Log_ `retrying reversal` menandai percobaan ulang.

_Graceful shutdown_ `transfer` menunggu transfer yang sedang berjalan sampai 60 detik (`shutdownGrace` di `transfer/main.go`). Angka ini menutup durasi terburuk satu saga: _debit_ dan _credit_ masing-masing 11,75 detik (4 percobaan × 2 detik + 3 _backoff_), _reversal_ 32 detik. Celah yang tersisa: proses yang dimatikan paksa (SIGKILL, _crash_) di antara dua langkah meninggalkan baris `PENDING` atau `DEBITED` yang tidak dilanjutkan oleh siapa pun. Sistem _production_ menambahkan _recovery job_ yang melanjutkan atau mengompensasi baris seperti itu.

Celah yang disengaja: jika semua percobaan _debit_ atau _credit_ berakhir _timeout_, hasilnya di `account` tidak pasti. Lab ini tetap menandai `FAILED` atau menjalankan kompensasi; sistem _production_ menjalankan _reconciliation job_ yang mengulang mutasi dengan _reference_ yang sama sampai jawabannya pasti.

### _Transactional outbox_

Perubahan status dan _event_-nya ditulis dalam satu transaksi database: tabel `transfer` dan `outbox` di `db-transfer`. _Relay_ di dalam `transfer` membaca `outbox` setiap 500 ms (`for update skip locked`, maksimal 100 baris), mengirim ke Kafka, lalu mengisi `published_at`. Selama Kafka mati, transfer tetap jalan dan _event_ menunggu di `outbox`.

_Delivery_ bersifat _at-least-once_: bila proses berhenti setelah Kafka menerima _event_ tetapi sebelum `published_at` tersimpan, _event_ dikirim ulang.

| Atribut Kafka | Isi |
|---|---|
| _Topic_ | `transfer-events`, 3 _partition_, dibuat oleh `kafka-init` saat `make infra-up` |
| _Key_ | `transfer_id`: semua _event_ satu transfer masuk _partition_ yang sama |
| _Header_ | `event_type`, `event_id` |
| _Payload_ | `event_id`, `transfer_id`, `from_account`, `to_account`, `amount`, `status`, `reason`, `occurred_at` |

Kafka dari laptop: `localhost:9092`. Konfigurasi `transfer` menambah `KAFKA_BROKERS` dan `KAFKA_TOPIC`.

### Notification service

`notification` membaca `transfer-events` dengan _consumer group_ `notification`, menyimpan satu baris per _event_ di `db-notification`, mencatat log `notification sent`, lalu melakukan _commit offset_. Kafka atau database yang mati ditunggu sampai kembali aktif; service tidak berhenti.

_Event_ yang tidak mungkin diproses (_poison message_) dicatat dengan level `ERROR` lalu dilewati, dan _offset_-nya tetap di-_commit_ agar _event_ berikutnya di _partition_ yang sama tidak tertahan: JSON rusak, `event_id` atau `transfer_id` yang bukan UUID, dan _error_ PostgreSQL kelas 22 (data tidak valid, misalnya `22P02`) atau 23 (_constraint_, misalnya `23502`, `23514`). _Error_ lain, seperti koneksi putus atau _timeout_, diulang terus.

```
curl "localhost:8083/notifications?transfer_id=<id>"
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
| Transfer berhasil | Transfer antar dua rekening yang ada | `COMPLETED`, notifikasi "berhasil" |
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

Baris yang tertinggal di `PENDING` atau `DEBITED` karena proses `transfer` mati di tengah _saga_ tidak dilanjutkan oleh siapa pun (lihat celah di Lab 5). _Replay_ untuk transfer seperti itu terus menjawab 202 dengan status yang sama.

Nominal dibandingkan sebagai desimal: `"100000"` dan `"100000.00"` dianggap sama. _Request_ paralel dengan _key_ yang sama menghasilkan satu transfer.

```
curl -i -X POST localhost:8082/transfers -H 'Idempotency-Key: 7f9c2b1e-0d4a-4c1e-9b8f-1a2b3c4d5e6f' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```

Lingkup _key_ di lab ini global untuk semua klien dan tidak kedaluwarsa. Di _production_, _key_ biasanya dibatasi per klien dan dihapus setelah periode tertentu, misalnya 24 jam.

Database dari Lab 5 tidak perlu di-_reset_: tabel `processed_event` dan kolom `idempotency_key` dibuat otomatis saat service dijalankan.

## OAuth2 dan JWT (Lab 7)

Hydra (_authorization server_) dijalankan dari `compose.yaml` dengan konfigurasi siap pakai. Peserta tidak mengonfigurasi Hydra; yang ditulis adalah verifikasi _token_ di `account` dan `transfer`.

| Endpoint Hydra | Alamat |
|---|---|
| _Token endpoint_ | `http://localhost:4444/oauth2/token` |
| JWKS (_public key_) | `http://localhost:4444/.well-known/jwks.json` |
| _Issuer_ (`iss`) | `http://localhost:4444/` (dengan garis miring di akhir) |
| Admin | `http://localhost:4445`, hanya digunakan oleh `hydra-init` |

`make infra-up` menjalankan `hydra-init` yang membuat dua _client_ dengan _grant_ `client_credentials`:

| _Client ID_ | _Secret_ | _Scope_ yang boleh diminta | Pengguna |
|---|---|---|---|
| `transfer-service` | `transfer-service-secret` | `account:read`, `account:write` | `transfer` saat memanggil gRPC `account` |
| `channel-app` | `channel-app-secret` | `transfer:read`, `transfer:write` | Aplikasi _channel_ (di lab: `curl`) |

Hydra menyimpan data di memori (`DSN=memory`): setelah Hydra di-_restart_, _client_ dan _signing key_ hilang. `make infra-up` membuat ulang _client_. `account` dan `transfer` mengambil JWKS baru saat menerima _token_ dengan `kid` yang belum dikenal (paling sering sekali per 5 detik). `transfer` meminta _token_ baru bila `account` menolak _token_ lama dengan `UNAUTHENTICATED`, lalu mengulang panggilan sekali.

### Aturan akses

| Service | Operasi | _Scope_ |
|---|---|---|
| `account` gRPC | `GetAccount` | `account:read` |
| `account` gRPC | `Debit`, `Credit` | `account:write` |
| `transfer` REST | `POST /transfers` | `transfer:write` |
| `transfer` REST | `GET /transfers/{id}` | `transfer:read` |

Tanpa _token_: `/healthz`, `/readyz`, `/debug/circuit-breaker`, gRPC _health_ dan _reflection_, `/admin/fault`, serta REST `account` (`/accounts`).

Pemeriksaan _token_: tanda tangan RS256 dengan _key_ dari JWKS, `iss` sama persis dengan `OAUTH_ISSUER`, `exp` wajib ada dan belum lewat, _scope_ dari _claim_ `scp`. `aud` tidak diperiksa karena _token_ `client_credentials` dari Hydra tidak membawa `aud` kecuali diminta.

| Kondisi | REST `transfer` | gRPC `account` |
|---|---|---|
| Tanpa _token_ | 401, `WWW-Authenticate: Bearer` | `UNAUTHENTICATED` |
| _Token_ rusak, kedaluwarsa, _issuer_ lain, tanda tangan salah | 401, `WWW-Authenticate: Bearer error="invalid_token"` | `UNAUTHENTICATED` |
| _Token_ valid, _scope_ kurang | 403, `WWW-Authenticate: Bearer error="insufficient_scope"` | `PERMISSION_DENIED` |

Detail penolakan (misalnya `token is expired`) hanya ada di log `request rejected` / `grpc call rejected`; respons hanya berisi `missing bearer token`, `invalid token`, atau `scope ... required`.

`transfer` mengambil _token_ `transfer-service` hanya dengan _scope_ `account:write`, menyimpannya sampai 10 detik sebelum kedaluwarsa (masa berlaku 1 jam), dan mengirimnya di _metadata_ `authorization`. Kegagalan mengambil _token_ menghasilkan `UNAUTHENTICATED`: tidak di-_retry_, tidak memicu pengambilan _token_ kedua, dan tidak dihitung _circuit breaker_, karena `account` tidak bermasalah. Transfer berakhir `FAILED` dengan kode 502. Koneksi gRPC di lab tanpa TLS; di _production_, _bearer token_ wajib lewat TLS.

### Konfigurasi

| Variabel | `account` | `transfer` |
|---|---|---|
| `OAUTH_ISSUER` | Ya | Ya |
| `OAUTH_JWKS_URL` | Ya | Ya |
| `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_TOKEN_URL` | – | Ya |

Semua wajib; nilai untuk laptop ada di `Makefile` masing-masing service.

### `failure_reason`

Mulai Lab 7, `failure_reason` di respons API dan di _event_ Kafka hanya berisi alasan umum: `insufficient funds`, `account not found`, `account service unavailable` (_circuit breaker_ terbuka), atau `account service error` (penyebab lain). Contoh: `debit failed: account service error`. Pesan aslinya, misalnya alamat `dial tcp 127.0.0.1:9091`, hanya ada di log `transfer` bersama `transfer_id`.

Perubahan ini hanya berlaku untuk transfer baru. Transfer yang tersimpan sebelum Lab 7 tetap menampilkan `failure_reason` lama yang memuat pesan asli, misalnya `debit failed: debit 1111111111: rpc error: ...`. Untuk melihat format baru, buat transfer baru yang gagal. _Replay_ dengan `Idempotency-Key` lama tetap menghasilkan kode HTTP yang sama, karena kedua format diakhiri dengan pesan penyebab yang sama.

### Mencoba

```
TOKEN=$(make -s token)                       # token channel-app, scope transfer:read transfer:write
RO=$(make -s token SCOPE=transfer:read)      # token hanya-baca

curl -i -X POST localhost:8082/transfers \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'          # 401
curl -i -X POST localhost:8082/transfers -H "Authorization: Bearer $RO" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'          # 403
curl -i -X POST localhost:8082/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'          # 201
curl -H "Authorization: Bearer $RO" localhost:8082/transfers/<id>                         # 200
```

Isi _token_ dapat dibaca di https://jwt.io atau dengan `cut -d. -f2 <<<"$TOKEN" | base64 -d`. Log `account mutated` di `account` mencatat `client_id` pemanggil.

Database dari Lab 6 tidak perlu di-_reset_.

## Observability (Lab 8)

Tiga sinyal dari setiap service:

| Sinyal | Cara keluar dari service | Tujuan di `otel-lgtm` |
|---|---|---|
| Log | JSON ke _stdout_ dan OTLP gRPC ke `localhost:4317` (`otelslog`) | Loki |
| _Trace_ | OTLP gRPC ke `localhost:4317` | Tempo |
| _Metric_ | `GET /metrics` di port HTTP masing-masing, diambil Prometheus setiap 5 detik | Prometheus |

`otel-lgtm` (`grafana/otel-lgtm:0.37.0`) berisi OpenTelemetry Collector, Prometheus, Tempo, Loki, dan Grafana dalam satu _container_, khusus untuk lab. Grafana: http://localhost:3000, tanpa _login_. Data hilang bila _container_ dibuat ulang.

Prometheus di dalam _container_ mengambil `/metrics` service di laptop lewat `host.docker.internal` (`observability/prometheus.yaml`). Docker Desktop menyediakan nama ini; di Docker Engine Linux, `extra_hosts: host-gateway` di `compose.yaml` yang membuatnya. Status pengambilan: panel _Target scrape_ di _dashboard_, atau query `up` di Grafana Explore.

### Konfigurasi

| Variabel | Nilai di laptop | Keterangan |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | Wajib berupa URL `http://host:port` atau `https://host:port`; format lain menghentikan service saat _startup_ |
| `OTEL_SERVICE_NAME` | `account`, `transfer`, `notification` | Nama service di Tempo dan Loki |

Keduanya wajib di ketiga service. Collector yang mati tidak menghentikan service: kegagalan kirim dicatat di _stdout_ sebagai `telemetry export failed`, lalu _span_ dan log yang gagal dikirim dibuang.

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

_Probe_ (`/healthz`, `/readyz`) dan `/metrics` tidak di-_trace_. _Publish_ yang gagal karena Kafka mati tidak menghasilkan _span_; percobaan ulang setiap 500 ms tercatat di log `outbox publish failed` dan di `outbox_pending`.

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
| `http_server_request_duration_seconds` | Ketiganya | `method`, `route`, `status` | _Histogram_ durasi request REST; `route` = _pattern_ ServeMux (`/transfers/{id}`), `unmatched` untuk 404 dari ServeMux |
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
  curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8082/transfers -H "Authorization: Bearer $TOKEN" \
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

Setiap service punya `Dockerfile` di direktorinya sendiri. _Build context_ adalah direktori `studi-kasus/`, bukan direktori service, karena `go.mod` `account` dan `transfer` mengarah ke `../proto` lewat _replace directive_. `notification` tidak memakai `proto` (_event_ dikirim sebagai JSON di Kafka), jadi `Dockerfile`-nya hanya menyalin `notification/`; _build context_-nya tetap sama agar ketiga _image_ dibangun dengan perintah yang sama.

| Tahap | Isi |
|---|---|
| _Builder_ | `golang:1.27.2-alpine`, `GOWORK=off` (hanya modul service, ditambah `proto` untuk `account` dan `transfer`), `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"` |
| Akhir | `FROM scratch`: _binary_ statis dan sertifikat CA, tanpa _shell_. Ukuran sekitar 8–9 MB terkompresi. Docker dengan _containerd image store_ (Docker Engine 29, Docker Desktop versi baru) menampilkan dua kolom di `docker images`: `CONTENT SIZE` sekitar 8–9 MB dan `DISK USAGE` sekitar 31–34 MB (terkompresi ditambah hasil ekstrak). _Image store_ klasik menampilkan satu kolom `SIZE` sekitar 21–23 MB |
| _User_ | `65532:65532` (numerik). Tetap jalan dengan UID lain (OpenShift _restricted SCC_) dan _root filesystem_ _read-only_ |

```
make images VERSION=1.0.0     # studi-kasus/account:1.0.0, studi-kasus/transfer:1.0.0, studi-kasus/notification:1.0.0
```

`VERSION` wajib diisi; tanpa `VERSION`, `make` berhenti dengan pesan error. `make` tidak mencegah _build_ ulang dengan _tag_ yang sudah ada, tetapi _image_ hasil _build_ ulang itu tidak pernah sampai ke _pod_: Deployment memakai `imagePullPolicy: IfNotPresent`, dan referensi _image_ yang tidak berubah tidak memicu _rollout_. Setiap perubahan kode mendapat `VERSION` baru (`1.0.1`, `1.0.2`, ...), lalu `make k3d-import` dengan `VERSION` itu dan `kubectl set image` atau `newTag` di `overlays/k3d/kustomization.yaml` (lihat Latihan).

### Seluruh sistem di Docker Compose

_Profile_ `apps` di `compose.yaml` menjalankan ketiga service sebagai _container_ dengan alamat _compose service_ (`db-account:5432`, `kafka:29092`, `hydra:4444`, `otel-lgtm:4317`) dan _root filesystem_ _read-only_. Hentikan service yang dijalankan dengan `make -C <service> run` lebih dulu karena port 8081–8083 sama.

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
| Kafka | `host.k3d.internal:19092` (_listener_ `K3D` di `compose.yaml`) |
| Hydra | JWKS dan _token endpoint_ di `http://host.k3d.internal:4444`; `OAUTH_ISSUER` tetap `http://localhost:4444/` karena nilai `iss` di _token_ selalu alamat itu |
| OTLP | `http://host.k3d.internal:4317` |
| `account` gRPC | `account:9091` (Service di _namespace_ yang sama) |

Kafka mendapat _listener_ ketiga karena _listener_ `localhost:9092` mengiklankan `localhost`, dan di dalam _pod_ `localhost` adalah _pod_ itu sendiri.

```
make infra-up
make images VERSION=1.0.0
make k3d-up                        # cluster "bank", rancher/k3s:v1.36.5-k3s1, port 8080 laptop ke Traefik, tunggu DNS host.k3d.internal
make k3d-import VERSION=1.0.0      # salin image ke cluster, tanpa registry
make k8s-apply                     # kubectl apply -k k8s/overlays/k3d, lalu tunggu rollout ketiga Deployment
make k3d-down                      # hapus cluster
```

Hentikan service yang berjalan di laptop (`make -C <service> run`) atau di _profile_ `apps` sebelum `make k8s-apply`. Kalau tidak, dua `notification` berbagi _partition_ dalam satu _consumer group_ dan dua _relay outbox_ membaca database yang sama.

k3d menulis `host.k3d.internal` ke ConfigMap CoreDNS, tetapi CoreDNS baru menjawab nama itu setelah ConfigMap sampai ke _pod_-nya, sampai sekitar satu menit kemudian. `make k3d-up` menunggu sampai nama itu terjawab, sehingga `make k8s-apply` sesudahnya tidak menghasilkan _restart_.

Setelah Docker atau laptop di-_restart_, _container_ cluster berjalan lagi tanpa `host.k3d.internal` di DNS cluster. _Pod_ masuk `CrashLoopBackOff` dengan log `lookup host.k3d.internal ... no such host`. Jalankan `k3d cluster stop bank` lalu `k3d cluster start bank`: k3d menulis nama itu lagi, dan _pod_ berjalan normal setelah satu sampai dua menit tanpa perintah tambahan.

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
| Secret | Kosong di `base`; `DATABASE_URL` dan `OAUTH_CLIENT_SECRET` diisi `overlays/k3d/secrets.yaml`. Credential lab ini ikut di-_commit_ hanya karena tidak melindungi apa pun di luar laptop |
| Deployment | 1 _replica_, `envFrom` ConfigMap + Secret, _readiness_ `/readyz`, _liveness_ `/healthz`, _resource request_ dan _limit_, _rolling update_ `maxSurge: 1`, `maxUnavailable: 0`, `preStop` _sleep_ 5 detik, `terminationGracePeriodSeconds` 30 (`transfer` 75) |
| _Security context_ | `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, tanpa `runAsUser` |
| Service | ClusterIP: `account` 8081 dan 9091, `transfer` 8082, `notification` 8083 |
| Ingress | Hanya `transfer`, _path_ `/transfers`, `ingressClassName: traefik` |

Saat _pod_ dihentikan (_rolling update_, _scale down_), Kubernetes mengeluarkan _pod_ dari _endpoint_ Service dan Ingress bersamaan dengan menghentikannya, bukan sebelumnya. Selama beberapa detik _request_ baru masih datang. `preStop` dengan aksi `sleep` (Kubernetes 1.30+, tidak butuh _shell_, yang memang tidak ada di _image_ `scratch`) menunda SIGTERM 5 detik sampai _pod_ tidak lagi menerima _request_ baru; setelah itu _graceful shutdown_ di `main.go` menyelesaikan _request_ yang sedang berjalan. `terminationGracePeriodSeconds` dihitung sejak `preStop` dimulai dan harus mencakup `preStop` + batas _shutdown_ service + _flush_ telemetri 5 detik: `account` dan `notification` 5 + 10 + 5 detik, `transfer` 5 + 60 + 5 detik (`shutdownGrace`, agar _saga_ tidak terpotong). Lewat dari batas itu _kubelet_ mengirim SIGKILL. Di _profile_ `apps`, `stop_grace_period: 70s` memberi `transfer` waktu yang sama di Docker Compose.

_Key_ yang tidak ada di ConfigMap maupun Secret menghentikan service saat _startup_ (`missing required environment variables: ...`); _pod_ masuk `CrashLoopBackOff`.

```
kubectl kustomize k8s/overlays/k3d    # hasil render tanpa apply
```

### Mencoba

```
kubectl -n bank get pods,svc,ingress
kubectl -n bank port-forward svc/account 8081:8081    # terminal lain: REST account, make fault-*
TOKEN=$(make -s token)
curl -i -X POST localhost:8080/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
kubectl -n bank logs deploy/transfer
```

Rekening dari lab sebelumnya tetap ada karena `account` di k3d menggunakan `db-account` yang sama. `/debug/circuit-breaker`, `/metrics`, dan `GET /notifications` tidak lewat Ingress: gunakan `kubectl -n bank port-forward svc/transfer 8082:8082` atau `svc/notification 8083:8083`.

### Latihan: mengubah manifest

| Latihan | Perintah | Yang diamati |
|---|---|---|
| _Scale_ | `kubectl -n bank scale deployment/notification --replicas=3` | Tiga _pod_ berbagi tiga _partition_. Dengan `--replicas=4`, satu _pod_ tidak mendapat _partition_ dan tidak memproses _event_ |
| Ubah konfigurasi | Hapus `KAFKA_GROUP_ID` dari ConfigMap `notification` di `overlays/k3d/config.yaml`, `kubectl apply -k k8s/overlays/k3d`, `kubectl -n bank rollout restart deployment/notification` | _Pod_ baru `CrashLoopBackOff`, `kubectl -n bank logs` menyebut variabel yang kosong; _pod_ lama tetap melayani karena `maxUnavailable: 0`. Kembalikan nilainya, _apply_ lagi, lalu `kubectl -n bank rollout restart deployment/notification`: _pod_ yang `CrashLoopBackOff` baru mencoba lagi setelah jeda _backoff_ (sampai 5 menit), sedangkan `rollout restart` langsung membuat _pod_ baru |
| _Rolling update_ | `make images VERSION=1.0.1`, `make k3d-import VERSION=1.0.1`, `kubectl -n bank set image deployment/transfer transfer=studi-kasus/transfer:1.0.1`, `kubectl -n bank rollout status deployment/transfer` | _Pod_ baru dibuat dan menjadi _ready_ sebelum _pod_ lama dihentikan. _Build_ ulang dengan _tag_ `1.0.0` yang sama tidak memicu _rollout_. Alternatif: ubah `newTag` di `overlays/k3d/kustomization.yaml` lalu `kubectl apply -k` |
| _Rollback_ | `kubectl -n bank rollout undo deployment/transfer` | Kembali ke `1.0.0` |

Perubahan ConfigMap atau Secret tidak dibaca _pod_ yang sedang berjalan karena _environment variable_ hanya dibaca saat _startup_: jalankan `kubectl rollout restart`.

### Batasan di lab

| Hal | Keterangan |
|---|---|
| _Metric_ | Prometheus di `otel-lgtm` hanya mengambil port 8081–8083 di laptop. _Metric_ _pod_ di k3d tidak terambil; _trace_ dan log tetap masuk lewat OTLP |
| gRPC dan Service | ClusterIP menyeimbangkan koneksi, bukan panggilan. Setelah `account` di-_scale_, panggilan dari satu _pod_ `transfer` tetap ke _pod_ `account` yang sama |
| _Circuit breaker_ | Per _pod_ `transfer`; tiap _replica_ punya status sendiri |
| Secret | Disimpan di repository khusus untuk lab. _Production_ mengambil Secret dari _vault_ atau _secret operator_ |

Database dari Lab 8 tidak perlu di-_reset_. `make infra-up` membuka port 19092 untuk _listener_ Kafka `K3D`.

## Checkpoint

Tag `lab-01` … `lab-10` berisi kondisi kode di akhir setiap lab. Peserta yang tertinggal melanjutkan dari tag lab sebelumnya:

```
git checkout lab-03
```
