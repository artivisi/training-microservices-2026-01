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
make infra-up            # PostgreSQL dan Kafka via Docker Compose, termasuk pembuatan topic
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

`notification` di lab ini sengaja belum _idempotent_: _event_ yang dikirim ulang menghasilkan notifikasi ganda. Lab 6 memperbaikinya.

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
| _Replay_ | Hentikan `notification`, `make replay`, jalankan lagi | Semua notifikasi tersimpan dua kali |

## Checkpoint

_Tag_ `lab-01` … `lab-10` berisi kondisi kode di akhir setiap lab. Peserta yang tertinggal melanjutkan dari _tag_ lab sebelumnya:

```
git checkout lab-03
```
