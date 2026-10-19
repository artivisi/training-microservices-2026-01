# Training Arsitektur Microservices dan Cloud dengan Golang

Materi in-house training Arsitektur Microservices dan Cloud (Golang), 4 hari,
Oktober 2026. Disusun oleh PT ArtiVisi Intermedia, instruktur Endy Muhardin.

| Folder | Isi |
|---|---|
| `setup-guide/` | Panduan persiapan laptop peserta dan skrip pemeriksaan kesiapan |
| `studi-kasus/` | Studi kasus: sistem simulasi perbankan 3 service (account, transfer, notification) dalam Go — kontrak protobuf, manifest Kubernetes, pipeline CI/CD, dengan checkpoint tag `lab-01` … `lab-10` |
| `lab-guide/` | Panduan lab langkah demi langkah |
| `deck/` | Slide 4 hari |
| `_template/` | Template Typst untuk dokumen peserta |

Peserta yang tertinggal pada suatu lab dapat melanjutkan dari checkpoint
lab sebelumnya: `git checkout lab-NN`.

Pemeriksaan kesiapan laptop:

```
curl -fsSL https://raw.githubusercontent.com/artivisi/training-microservices-2026-01/main/setup-guide/cek-persiapan.sh | bash
```
