#import "../_template/panduan.typ": panduan, note, perintah

#show: panduan.with(
  label: "PANDUAN PERSIAPAN PESERTA",
  title: "Persiapan Laptop Peserta",
  subtitle: "Training Arsitektur Microservices dan Cloud dengan Golang",
  client: sys.inputs.at("client"),
  date: "19 Oktober 2026",
  metadata: (
    ("Training", "26 – 29 Oktober 2026"),
    ("Batas persiapan", "Jumat, 23 Oktober 2026"),
    ("Perkiraan waktu", [1 – 2 jam, _download_ ±5 GB]),
    ("Sistem operasi", "Windows 10/11 (WSL2), macOS, Linux"),
  ),
)

= Ringkasan

Setiap peserta menjalankan seluruh lab di laptop masing-masing. Persiapan laptop terdiri atas empat langkah:

+ Memastikan spesifikasi laptop dan hak akses memenuhi syarat (@spesifikasi).
+ Memastikan jaringan kantor membuka akses ke alamat yang dibutuhkan (@jaringan).
+ Memasang _software_ sesuai sistem operasi (@windows, @macos, @linux, @plugin).
+ Menjalankan skrip pemeriksaan, lalu mengirim _file_ log hasilnya ke PIC (@pemeriksaan).

Seluruh langkah selesai paling lambat *Jumat, 23 Oktober 2026*. Pada tanggal tersebut instruktur dan PIC melakukan pemeriksaan jarak jauh terhadap hasil skrip dari setiap laptop. Laptop yang belum lulus pemeriksaan masih dapat diperbaiki sebelum hari pertama training.

#note[Pertanyaan seputar persiapan laptop disampaikan melalui PIC, atau langsung ke instruktur: Endy Muhardin, `endy@artivisi.com`.]

= Spesifikasi dan Hak Akses <spesifikasi>

#table(
  columns: (1fr, 2.4fr),
  [Komponen], [Syarat],
  [Prosesor], [64-bit, x86_64 (Intel/AMD) atau Apple Silicon],
  [RAM], [Minimal 16 GB. Docker mendapat jatah minimal 8 GB dari jumlah tersebut],
  [Ruang disk], [Minimal 25 GB kosong],
  [Sistem operasi], [Windows 10 versi 22H2 atau Windows 11 dengan WSL2, macOS 13 atau lebih baru, atau Linux 64-bit (Ubuntu 22.04/24.04 sudah diuji)],
  [Hak akses], [Hak administrator untuk memasang _software_ dan menjalankan Docker],
  [Virtualisasi], [Windows: fitur _virtualization_ (Intel VT-x / AMD-V) aktif di BIOS. Kebijakan laptop kantor sering menonaktifkan fitur ini, sehingga perlu diperiksa sebelum memasang Docker Desktop],
)

#note[Bila laptop kantor tidak dapat memenuhi hak akses atau virtualisasi, siapkan laptop khusus untuk training dan sampaikan ke PIC sebelum 23 Oktober.]

= Akses Jaringan <jaringan>

Jaringan tempat laptop digunakan, baik kantor maupun Wi-Fi ruang training, harus membuka akses keluar ke alamat berikut.

#table(
  columns: (2fr, 0.7fr, 2.3fr),
  [Alamat], [Port], [Kegunaan],
  [`git.training.artivisi.id`], [22, 443], [Git server dan _container registry_ training. Port 22 (SSH) wajib terbuka karena _clone_, _push_, dan login ke server _deployment_ menggunakan SSH],
  [`*.training.artivisi.id`], [22, 443], [Server _deployment_ dan aplikasi peserta (Day 4)],
  [`proxy.golang.org`, `sum.golang.org`], [443], [_Download_ dan verifikasi Go module],
  [`go.dev`, `dl.google.com`], [443], [Installer Go],
  [`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`], [443], [Docker Hub],
  [`ghcr.io`, `pkg-containers.githubusercontent.com`], [443], [Image pendukung k3d],
  [`github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`], [443], [Repositori materi training, skrip pemeriksaan, _download_ protoc, k3d, dan dependensi lain],
  [`dl.k8s.io`], [443], [_Download_ kubectl (Linux dan WSL2)],
)

Bila jaringan kantor mewajibkan HTTP _proxy_, tambahkan dua pengaturan berikut:

- *Terminal.* Tambahkan baris berikut ke `~/.bashrc` (Linux, WSL2) atau `~/.zshrc` (macOS), dengan alamat _proxy_ dari tim jaringan:
  #perintah[```bash
  export HTTPS_PROXY=http://proxy.kantor:8080
  export HTTP_PROXY=http://proxy.kantor:8080
  export NO_PROXY=localhost,127.0.0.1,.local
  ```]
- *Docker Desktop.* Menu _Settings_ → _Resources_ → _Proxies_, isi alamat _proxy_ yang sama.

SSH ke port 22 tidak melewati HTTP _proxy_. Akses langsung ke `git.training.artivisi.id` port 22 perlu dibuka oleh tim jaringan.

= Versi Software

#table(
  columns: (1.4fr, 1fr, 2fr),
  [Software], [Versi], [Keterangan],
  [Go], [1.27.x], [Minimal 1.26],
  [protoc], [36.2], [_Protocol Buffers compiler_],
  [protoc-gen-go], [1.36.12], [_Plugin_ protoc untuk Go],
  [protoc-gen-go-grpc], [1.6.2], [_Plugin_ protoc untuk gRPC],
  [Docker], [Versi terbaru], [Docker Desktop (Windows, macOS) atau Docker Engine dengan Compose _plugin_ (Linux)],
  [k3d], [5.9.0], [Cluster Kubernetes di atas Docker],
  [kubectl], [1.37.x], [Minimal 1.35],
  [Git, Make, curl], [Bawaan sistem], [Sudah tersedia di macOS dan Ubuntu, atau dipasang pada langkah instalasi],
)

= Instalasi di Windows <windows>

Di Windows seluruh lab berjalan di dalam Ubuntu pada WSL2. Perintah lab ditulis untuk _shell_ Linux, sehingga peserta Windows dan Linux menjalankan perintah yang sama.

== Aktifkan WSL2 dan Ubuntu

Buka PowerShell sebagai _Administrator_, lalu jalankan:

#perintah[```powershell
wsl --install -d Ubuntu-24.04
```]

_Restart_ laptop. Setelah _restart_, jendela Ubuntu terbuka dan meminta _username_ serta _password_ baru untuk Ubuntu.

== Batasi Memori WSL2

Secara _default_, WSL2 mengambil setengah RAM laptop. Buat _file_ `%UserProfile%\.wslconfig` dengan Notepad:

#perintah[```ini
[wsl2]
memory=10GB
```]

Simpan, lalu jalankan `wsl --shutdown` di PowerShell agar pengaturan berlaku.

== Pasang Docker Desktop

+ _Download_ Docker Desktop dari #link("https://docs.docker.com/desktop/setup/install/windows-install/")[`docs.docker.com/desktop/setup/install/windows-install`] dan pasang dengan opsi _Use WSL 2 instead of Hyper-V_.
+ Buka Docker Desktop, menu _Settings_ → _Resources_ → _WSL integration_, aktifkan *Ubuntu-24.04*, lalu klik _Apply & restart_.
+ Buka terminal Ubuntu dan jalankan `docker version`. Bila _output_ memuat bagian `Server`, Docker sudah dapat diakses dari Ubuntu.

== Lanjutkan di Ubuntu

Langkah berikutnya dijalankan di terminal Ubuntu: @linux (lewati bagian Docker Engine, karena Docker Desktop sudah terpasang), lalu @plugin.

Editor yang disarankan adalah Visual Studio Code dengan ekstensi *WSL* dan *Go*. Jalankan `code .` dari terminal Ubuntu untuk membuka folder proyek di dalam WSL2.

= Instalasi di macOS <macos>

+ Pasang Command Line Tools (berisi Git dan Make):
  #perintah[```bash
  xcode-select --install
  ```]
+ Pasang Homebrew dari #link("https://brew.sh")[`brew.sh`] bila belum tersedia.
+ Pasang Go, protoc, k3d, dan kubectl:
  #perintah[```bash
  brew install go protobuf k3d kubernetes-cli
  ```]
+ Tambahkan folder _binary_ Go ke `PATH`:
  #perintah[```bash
  echo 'export PATH="$PATH:$HOME/go/bin"' >> ~/.zshrc
  source ~/.zshrc
  ```]
+ Pasang Docker Desktop dari #link("https://docs.docker.com/desktop/setup/install/mac-install/")[`docs.docker.com/desktop/setup/install/mac-install`], sesuai jenis prosesor (Apple Silicon atau Intel).
+ Di Docker Desktop, menu _Settings_ → _Resources_, atur _Memory_ minimal 8 GB dan _Virtual disk limit_ minimal 40 GB, lalu klik _Apply & restart_.

Lanjutkan ke @plugin.

= Instalasi di Linux dan Ubuntu WSL2 <linux>

Perintah di bagian ini ditulis untuk prosesor x86_64. Untuk prosesor ARM, ganti `amd64` dengan `arm64` dan `x86_64` dengan `aarch_64`.

== Paket Dasar

#perintah[```bash
sudo apt update
sudo apt install -y curl git make unzip
```]

== Go

#perintah[```bash
curl -LO https://go.dev/dl/go1.27.2.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.27.2.linux-amd64.tar.gz
echo 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' >> ~/.bashrc
source ~/.bashrc
go version
```]

== protoc

#perintah[```bash
curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v36.2/protoc-36.2-linux-x86_64.zip
sudo unzip -o protoc-36.2-linux-x86_64.zip -d /usr/local bin/protoc 'include/*'
protoc --version
```]

== k3d dan kubectl

#perintah[```bash
curl -Lo k3d https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64
sudo install -m 0755 k3d /usr/local/bin/k3d
curl -LO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl
sudo install -m 0755 kubectl /usr/local/bin/kubectl
k3d version
kubectl version --client
```]

== Docker Engine (Linux saja)

Peserta WSL2 melewati bagian ini. Di Linux, pasang Docker Engine beserta Compose _plugin_ mengikuti #link("https://docs.docker.com/engine/install/")[`docs.docker.com/engine/install`] sesuai distribusi, lalu izinkan _user_ menjalankan Docker tanpa `sudo`:

#perintah[```bash
sudo usermod -aG docker $USER
```]

Logout lalu login kembali agar keanggotaan grup `docker` berlaku.

= Plugin protoc (Semua Sistem Operasi) <plugin>

#perintah[```bash
go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
protoc-gen-go --version
protoc-gen-go-grpc --version
```]

Perintah ini sekaligus menguji akses ke `proxy.golang.org`. Bila _download_ di langkah ini gagal, penyebabnya umumnya _proxy_ atau _firewall_ kantor (@jaringan).

Editor: Visual Studio Code dengan ekstensi *Go* (dari Go Team at Google), atau GoLand.

= Pemeriksaan Kesiapan <pemeriksaan>

Skrip pemeriksaan memeriksa versi _software_, memori Docker, ruang disk, dan akses jaringan, melakukan _download_ seluruh image Docker yang digunakan selama training, lalu menguji `docker compose up` dan `k3d cluster create`. Pastikan Docker sudah berjalan, lalu jalankan skrip dari terminal macOS, terminal Ubuntu WSL2, atau terminal Linux:

#perintah[```bash
curl -fsSL https://raw.githubusercontent.com/artivisi/training-microservices-2026-01/main/setup-guide/cek-persiapan.sh | bash
```]

Pemeriksaan pertama memakan waktu 10 – 20 menit karena _download_ image ±4 GB. Contoh _output_ dari laptop yang siap:

#perintah[```text
== Perangkat lunak
[OK]    Go 1.27.2
[OK]    protoc 36.2
...
== Akses jaringan
[OK]    Git server training (SSH port 22)
...
== Cluster Kubernetes lokal (k3d)
[OK]    k3d cluster create, node Ready

HASIL: SEMUA PEMERIKSAAN LULUS
```]

Hasil pemeriksaan tersimpan di `~/cek-persiapan.log`. Kirim _file_ tersebut ke PIC paling lambat *Jumat, 23 Oktober 2026*, meskipun masih ada pemeriksaan yang gagal.

== Penanganan Kegagalan

#table(
  columns: (1.5fr, 2.5fr),
  [Pemeriksaan Gagal], [Penanganan],
  [_Software_ tidak ditemukan], [Ulangi langkah instalasi terkait. Buka terminal baru agar perubahan `PATH` berlaku],
  [Docker Engine tidak ditemukan], [Jalankan Docker Desktop dan tunggu hingga statusnya _Engine running_. Di WSL2, periksa _WSL integration_ untuk Ubuntu-24.04],
  [Memori untuk Docker kurang dari 8 GB], [macOS: _Settings_ → _Resources_ → _Memory_. Windows: nilai `memory` di `.wslconfig`, lalu `wsl --shutdown`],
  [Go module proxy, Docker Hub, GitHub tidak terjangkau], [Akses diblokir _proxy_ atau _firewall_ kantor. Atur _proxy_ (@jaringan) atau minta tim jaringan membuka alamat tersebut],
  [Git server training (SSH port 22)], [Port 22 keluar diblokir _firewall_ kantor. Minta tim jaringan membuka port 22 ke `git.training.artivisi.id`],
  [`docker pull`], [Periksa akses Docker Hub dan `ghcr.io`, serta ruang disk],
  [`k3d cluster create`], [Pastikan Docker berjalan dan memori Docker minimal 8 GB. Jalankan ulang skrip. Percobaan kedua tidak mengulang _download_ image],
)
