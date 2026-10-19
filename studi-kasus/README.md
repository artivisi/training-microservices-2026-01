# Studi Kasus: Sistem Simulasi Perbankan

Tiga service Go dalam satu Go _workspace_ (`go.work`), masing-masing dengan database sendiri:

| Service | Tanggung jawab | Port HTTP | Port gRPC | Database |
|---|---|---|---|---|
| `account` | Data rekening dan saldo | 28081 | 29091 (Lab 4) | `db-account`, port 15432 |
| `transfer` | Transfer antar rekening (Lab 2) | 28082 | – | `db-transfer`, port 15433 |
| `notification` | Notifikasi hasil transfer (Lab 5) | 28083 | – | `db-notification`, port 15434 |

Port database dimulai dari 15432 agar tidak bentrok dengan PostgreSQL yang terpasang langsung di laptop.

## Menjalankan

```
make infra-up            # PostgreSQL (dan infrastruktur lab berikutnya) via Docker Compose
make -C account run      # account service di http://localhost:28081
make -C transfer run     # transfer service di http://localhost:28082
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

`transfer` memanggil `account` melalui _policy_ failsafe-go: _timeout_ 2 detik per percobaan, _retry_ maksimal 3 kali (_backoff_ 100 ms–1 detik dengan _jitter_) hanya untuk koneksi gagal dan HTTP 503, serta _circuit breaker_ (terbuka setelah 5 gagal dari 10 panggilan terakhir, menunggu 10 detik, tertutup lagi setelah 3 panggilan uji berhasil). _Timeout_ tidak di-_retry_ karena _debit_ belum _idempotent_.

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
| `DEADLINE_EXCEEDED`, _timeout_ 2 detik | Jawaban terlambat, _debit_ mungkin sudah terjadi | Tidak | Ya |
| `INTERNAL`, `UNKNOWN` | Kesalahan di server | Tidak | Ya |
| `CANCELLED` | Pemanggil sudah berhenti menunggu (misalnya _timeout_ di sisi `transfer`) saat _request_ masih diproses. Hanya terlihat di _log_ `account` sebagai WARN, bukan ERROR | - | - |

`transfer` membaca alamat gRPC `account` dari `ACCOUNT_GRPC_ADDR` (menggantikan `ACCOUNT_SERVICE_URL`). _Policy_ failsafe-go dari Lab 3 tetap sama, sekarang dipasang sebagai _unary client interceptor_. Di sisi server, `account` memasang dua _interceptor_: _logging_ (`grpc request` dengan `method`, `code`, `duration_ms`) dan _fault injection_. `make fault-slow` dan `make fault-error` berlaku untuk REST dan gRPC sekaligus.

## Checkpoint

_Tag_ `lab-01` … `lab-10` berisi kondisi kode di akhir setiap lab. Peserta yang tertinggal melanjutkan dari _tag_ lab sebelumnya:

```
git checkout lab-03
```
