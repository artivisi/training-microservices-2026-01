# Studi Kasus: Sistem Simulasi Perbankan

Tiga service Go dalam satu Go _workspace_ (`go.work`), masing-masing dengan database sendiri:

| Service | Tanggung jawab | Port HTTP | Database |
|---|---|---|---|
| `account` | Data rekening dan saldo | 8081 | `db-account`, port 15432 |
| `transfer` | Transfer antar rekening (Lab 2) | 8082 | `db-transfer`, port 15433 |
| `notification` | Notifikasi hasil transfer (Lab 5) | 8083 | `db-notification`, port 15434 |

Port database dimulai dari 15432 agar tidak bentrok dengan PostgreSQL yang terpasang langsung di laptop.

## Menjalankan

```
make infra-up            # PostgreSQL (dan infrastruktur lab berikutnya) via Docker Compose
make -C account run      # account service di http://localhost:8081
make -C transfer run     # transfer service di http://localhost:8082
make test                # unit test seluruh service
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

`transfer` memanggil `account` melalui _policy_ failsafe-go: _timeout_ 2 detik per percobaan, _retry_ maksimal 3 kali (_backoff_ 100 ms–1 detik dengan _jitter_) hanya untuk koneksi gagal dan HTTP 503, serta _circuit breaker_ (terbuka setelah 5 gagal dari 10 panggilan terakhir, menunggu 10 detik, tertutup lagi setelah 3 panggilan uji berhasil). _Timeout_ tidak di-_retry_ karena _debit_ belum _idempotent_.

```
make fault-slow            # account lambat 3 detik, melewati timeout 2 detik
make fault-error RATE=0.5  # 50% request ke account dijawab 503
make fault-status          # konfigurasi fault yang aktif
make fault-clear           # account normal kembali
make breaker               # status circuit breaker di transfer: closed, open, half-open
```

Saat _circuit breaker_ terbuka sebelum _debit_, `POST /transfers` langsung dijawab HTTP 503 dengan status transfer `FAILED` tanpa memanggil `account`: belum ada saldo yang berubah, sehingga _request_ aman diulang. Jika _debit_ sudah berhasil lalu _credit_ gagal karena sebab apa pun, termasuk _circuit breaker_ yang baru terbuka, jawabannya HTTP 502: saldo sumber sudah berkurang dan perlu dikembalikan manual, sehingga _request_ tidak boleh diulang.

## Checkpoint

Tag `lab-01` … `lab-10` berisi kondisi kode di akhir setiap lab. Peserta yang tertinggal melanjutkan dari tag lab sebelumnya:

```
git checkout lab-03
```
