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
make test                # unit test seluruh service
make infra-down          # hentikan container, data tetap tersimpan
make infra-reset         # hentikan container dan hapus seluruh data
```

Konfigurasi service hanya dibaca dari _environment variable_. Variabel yang kosong menghentikan service saat _startup_ dengan pesan error yang menyebutkan nama variabelnya.

## Checkpoint

Tag `lab-01` … `lab-10` berisi kondisi kode di akhir setiap lab. Peserta yang tertinggal melanjutkan dari tag lab sebelumnya:

```
git checkout lab-03
```
