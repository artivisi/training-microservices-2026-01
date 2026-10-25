#import "../_template/panduan.typ": note, perintah

= Lab 9: _Container_ dan _Deployment_ ke k3d

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

- menulis _multi-stage Dockerfile_ yang menghasilkan _binary_ Go statis di atas _image_ kosong (`FROM scratch`), berjalan sebagai _user_ non-_root_ dan tetap berfungsi dengan UID apa pun yang diberikan _platform_;
- menjalankan ketiga service sebagai _container_ di Docker Compose dengan _root filesystem_ _read-only_;
- membuat _cluster_ Kubernetes lokal dengan k3d, memasukkan _image_ ke _cluster_ tanpa _registry_, lalu menerapkan _manifest_ Kustomize yang sudah disediakan;
- membaca isi _manifest_ (Deployment, Service, ConfigMap, Secret, Ingress, _probe_, _security context_) dan menjelaskan alasan setiap pengaturan;
- mengubah sistem yang sedang berjalan di _cluster_: _scale_, perubahan konfigurasi, _rolling update_ dengan _tag image_ baru, serta _rollback_.

== Gambaran

Hingga Lab 8, ketiga service dijalankan langsung di laptop dengan `make -C <service> run`, sedangkan infrastruktur (PostgreSQL, Kafka, Hydra, `otel-lgtm`) berjalan di Docker Compose. Cara tersebut cocok untuk pengembangan, tetapi tidak mewakili cara aplikasi dijalankan di _server_, tempat aplikasi dikemas sebagai _image_ lalu dijalankan oleh _container platform_ seperti Kubernetes atau OpenShift.

Lab ini memindahkan ketiga service ke dalam _container_ dalam tiga tahap:

+ Setiap service mendapat `Dockerfile`. _Image_ yang dihasilkan hanya berisi _binary_ dan sertifikat CA, tanpa _shell_ maupun _package manager_.
+ _Profile_ `apps` di `compose.yaml` menjalankan ketiga _image_ tersebut di Docker Compose. Di tahap ini, _image_ diperiksa terlebih dahulu sebelum dijalankan di Kubernetes.
+ _Cluster_ k3d menjalankan ketiga service sebagai Deployment. Infrastruktur tetap di Docker Compose, dan _pod_ menjangkaunya melalui nama `host.k3d.internal`.

_Manifest_ Kubernetes untuk tahap ketiga sudah disediakan di _checkpoint_ `lab-09`. Peserta tidak perlu menulisnya dari awal, cukup menyalin _manifest_ tersebut, membaca bagian pentingnya, menerapkannya ke _cluster_, lalu mengubahnya melalui beberapa latihan.

Susunan sistem di akhir lab:

#perintah[```
 laptop
 ┌───────────────────────────────────────────────────────────────────┐
 │ curl localhost:28080/transfers                                    │
 │        │                                                          │
 │        ▼                                                          │
 │ ┌─ k3d cluster "bank" (namespace bank) ─────────────────────────┐ │
 │ │ Traefik (Ingress) ──► Service transfer:8082 ──► pod transfer  │ │
 │ │                                                    │ gRPC     │ │
 │ │                       Service account:9091  ◄──────┘          │ │
 │ │                              │                                │ │
 │ │                              ▼                                │ │
 │ │                         pod account        pod notification   │ │
 │ └──────────────────────────────┼───────────────────┼────────────┘ │
 │          host.k3d.internal     │                   │              │
 │ ┌─ Docker Compose ─────────────▼───────────────────▼────────────┐ │
 │ │ db-account :15432  db-transfer :15433  db-notification :15434 │ │
 │ │ kafka :19093 (listener K3D)   hydra :14444  otel-lgtm :14317  │ │
 │ └───────────────────────────────────────────────────────────────┘ │
 └───────────────────────────────────────────────────────────────────┘
```]

Pembagian ini mengikuti praktik umum di _production_: aplikasi berjalan di _cluster_, sedangkan database, _message broker_, dan _authorization server_ sering dikelola terpisah (_managed service_ atau _cluster_ khusus data).

=== Alasan Memilih Kubernetes dan k3d

#table(
  columns: (1fr, 3.6fr),
  table.header([Pertimbangan], [Keterangan]),
  [Kebutuhan], [Ketiga service harus dijalankan, diperbarui tanpa menghentikan layanan, dijalankan ulang otomatis saat macet, dan dapat menemukan alamat satu sama lain. Cara menjalankannya harus sama di laptop, di server _testing_, dan di _production_],
  [Opsi yang dipertimbangkan], [Docker Compose di beberapa VM, HashiCorp Nomad, atau Kubernetes (_vanilla_, OpenShift, atau layanan Kubernetes _managed_ milik penyedia _cloud_). Untuk Kubernetes di laptop: k3d, minikube, kind, atau Kubernetes bawaan Docker Desktop],
  [Pilihan di studi kasus], [Setiap service dikemas sebagai _container image_ dan dijalankan di Kubernetes. Untuk training, Kubernetes dijalankan dengan k3d],
  [Yang diperoleh], [_Image_ yang sama digunakan dari laptop sampai _production_. Kubernetes bersifat deklaratif: kondisi yang diinginkan ditulis di _manifest_, lalu Kubernetes menyesuaikan isi _cluster_ dengan _manifest_ tersebut. Kubernetes juga menjalankan ulang _container_ yang gagal (_self-healing_), menyediakan _rolling update_, nama DNS untuk setiap Service, dan _load balancing_. _Manifest_ yang sama dapat digunakan di OpenShift dan di layanan Kubernetes _managed_ milik penyedia _cloud_. k3d menjalankan k3s (distribusi Kubernetes yang ringan) di dalam _container_ Docker: _cluster_ dibuat dengan `make k3d-up` dan dihapus dengan `make k3d-down`, kebutuhan RAM-nya kecil, Traefik (_ingress controller_) sudah terpasang di k3s, _load balancer_ milik k3d meneruskan _port_ 28080 di laptop ke Traefik, dan `k3d image import` memasukkan _image_ ke _cluster_ tanpa _registry_],
  [Yang dikorbankan], [Kubernetes adalah platform tambahan yang harus dipelajari dan dioperasikan (_manifest_, RBAC, _upgrade_ _cluster_). _Cluster_ k3d hanya ditujukan untuk pengembangan dan pengujian di laptop. Komponen bawaan k3s seperti Traefik dan metrics-server belum tentu tersedia di _cluster_ lain. k3s tidak sama dengan OpenShift: perbedaan seperti SCC dan Route dibahas di sesi OpenShift pada Hari 4],
)

Dibandingkan k3d, minikube menyediakan banyak _add-on_ dan dapat berjalan di dalam VM maupun _container_. kind juga menjalankan Kubernetes di dalam Docker, tetapi _Ingress_ dan Service bertipe LoadBalancer membutuhkan komponen tambahan (cloud-provider-kind) yang dijalankan terpisah. Kubernetes bawaan Docker Desktop hanya tersedia bila menggunakan Docker Desktop.

== Titik Awal

Lanjutkan dari kode hasil Lab 8. Peserta yang tertinggal mengambil _checkpoint_ Lab 8:

#perintah[```bash
git checkout lab-08
```]

Lab ini membutuhkan Docker, k3d, dan kubectl yang sudah dipasang sesuai panduan persiapan. Periksa versinya:

#perintah[```bash
docker version --format '{{.Server.Version}}'
k3d version
kubectl version --client
```]

Semua perintah di lab ini dijalankan dari direktori `studi-kasus/`, kecuali jika disebutkan lain.

== Langkah

=== Menghentikan Service yang Berjalan di Laptop

Hentikan ketiga service yang masih berjalan dari Lab 8 (tekan `Ctrl+C` di terminal tempat `make -C account run`, `make -C transfer run`, dan `make -C notification run` dijalankan). Ada dua alasan:

- port 28081–28083 di laptop akan digunakan oleh _container_ di _profile_ `apps`;
- di k3d, `notification` yang kedua akan bergabung ke _consumer group_ yang sama dan berbagi _partition_ dengan `notification` di laptop, sedangkan dua _outbox relay_ `transfer` membaca tabel `outbox` yang sama. Hasilnya sulit dibaca karena sebagian _event_ diproses oleh proses di laptop.

Infrastruktur di Docker Compose tetap berjalan.

=== _Dockerfile_ untuk Service `account`

_Image_ yang di-_build_ di lab ini harus memenuhi tiga syarat:

- *Kecil dan minim isi.* _Image_ akhir hanya berisi _binary_ dan sertifikat CA. Tanpa _shell_ dan _package manager_, tidak ada komponen lain yang perlu di-_patch_ dan tidak ada _tools_ yang dapat digunakan penyerang di dalam _container_.
- *_Binary_ statis.* `CGO_ENABLED=0` menghasilkan _binary_ yang tidak bergantung pada `libc`, sehingga dapat berjalan di _image_ `scratch` yang kosong.
- *Non-_root_ dengan UID numerik.* Kubernetes hanya dapat memeriksa `runAsNonRoot` terhadap angka, dan OpenShift dengan _restricted SCC_ (_Security Context Constraints_) menjalankan _container_ dengan UID acak dari rentang milik _namespace_. _Binary_ yang tidak menulis ke _file_ apa pun tetap berjalan dengan UID mana pun.

_Multi-stage build_ memisahkan tahap kompilasi dari _image_ akhir. Tahap pertama (`build`) menggunakan `golang:1.27.2-alpine` yang berisi _compiler_; tahap kedua (`FROM scratch`) hanya menyalin hasil kompilasi dari tahap pertama.

_Build context_ adalah direktori `studi-kasus/`, satu tingkat di atas direktori service. Alasannya, `go.mod` service `account` dan `transfer` memiliki _replace directive_ ke `../proto`, sehingga modul `proto` harus ikut masuk ke _build context_. `notification` tidak menggunakan `proto`, tetapi tetap di-_build_ dengan _build context_ yang sama agar ketiga _image_ di-_build_ dengan perintah yang sama.

Buat _file_ `account/Dockerfile`:

#perintah[```dockerfile
# Multi-stage build of the account service. Build context: studi-kasus/ (not this
# directory), so the proto module that go.mod's replace directive points to
# (../proto) is part of the context:
#   docker build -f account/Dockerfile -t studi-kasus/account:1.0.0 .
FROM golang:1.27.2-alpine AS build

# GOWORK=off: build this module with its own go.mod/go.sum, not the workspace.
# The image then depends only on this service and proto; a change in another
# service's go.mod does not invalidate the cache here, and the CI pipeline of
# one service builds it alone (Lab 10).
# CGO_ENABLED=0: a static binary without libc, which runs in an empty image.
ENV GOWORK=off CGO_ENABLED=0

# Module files first: the download layer stays cached until go.mod/go.sum
# change, not on every source edit.
WORKDIR /src
COPY proto/go.mod proto/go.sum proto/
COPY account/go.mod account/go.sum account/
WORKDIR /src/account
RUN go mod download

COPY proto/ /src/proto/
COPY account/ /src/account/
# -trimpath drops the build machine's paths from the binary (reproducible,
# nothing about the builder leaks); -s -w drops the symbol table and DWARF
# debug data (smaller image; stack traces still have function names and lines).
RUN go build -trimpath -ldflags "-s -w" -o /out/account .

# Empty base image: no shell, no package manager, nothing to patch but the
# binary. The trade-off: no docker exec into a shell for debugging; use
# kubectl debug with an ephemeral container instead.
FROM scratch
# CA certificates for outgoing TLS (an https:// OAuth or OTLP endpoint in
# production). The lab endpoints are plain HTTP, but an image without them
# fails only later, on the first TLS connection.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/account /account
# Numeric UID:GID, not a name: scratch has no /etc/passwd, and Kubernetes can
# only check runAsNonRoot against a number. 65532 is the conventional
# "nonroot" ID. Nothing in the image needs a writable or owned path, so the
# binary also runs under the arbitrary UID that OpenShift's restricted SCC
# assigns, and with readOnlyRootFilesystem.
USER 65532:65532
# HTTP 8081 (REST, probes, /metrics) and gRPC 9091. Documentation only: the
# ports come from the environment (HTTP_ADDR, GRPC_ADDR).
EXPOSE 8081 9091
ENTRYPOINT ["/account"]
```]

Beberapa hal yang perlu diperhatikan dari _file_ tersebut:

- *Urutan `COPY`.* `go.mod` dan `go.sum` disalin dan `go mod download` dijalankan sebelum kode program disalin. Docker menyimpan setiap _layer_ di _cache_. Selama `go.mod` tidak berubah, _layer_ hasil `go mod download` digunakan ulang, sehingga _build_ setelah perubahan kode hanya mengulang kompilasi.
- *`GOWORK=off`.* Di laptop, `go.work` menggabungkan ketiga modul. Di dalam _image_, setiap service dikompilasi hanya dengan `go.mod` miliknya, sehingga _image_ satu service tidak terpengaruh perubahan dependensi service lain.
- *Tanpa _shell_.* `docker exec -it ... sh` tidak dapat digunakan pada _image_ ini. Untuk _debugging_ di Kubernetes, gunakan `kubectl debug` dengan _ephemeral container_, yaitu _container_ sementara yang ditambahkan ke _pod_ yang sedang berjalan (lihat Eksplorasi Mandiri).

=== _Dockerfile_ untuk `transfer` dan `notification`

Kedua service lain menggunakan struktur yang sama dan hanya berbeda pada nama direktori, nama _binary_, dan port. Salin _file_ milik `account`, lalu ganti nama service:

#perintah[```bash
sed 's/account/transfer/g' account/Dockerfile > transfer/Dockerfile
sed 's/account/notification/g' account/Dockerfile > notification/Dockerfile
```]

Perintah `sed` di atas tidak mengubah port. Di `transfer/Dockerfile`, ganti dua baris komentar `# HTTP 8081 ...` beserta baris `EXPOSE` di bawahnya (tepat di atas `ENTRYPOINT`) menjadi:

#perintah[```dockerfile
# HTTP 8082. Documentation only: the ports come from the environment
# (HTTP_ADDR).
EXPOSE 8082
```]

Lakukan hal yang sama di `notification/Dockerfile`:

#perintah[```dockerfile
# HTTP 8083. Documentation only: the ports come from the environment
# (HTTP_ADDR).
EXPOSE 8083
```]

`EXPOSE` hanya berfungsi sebagai dokumentasi. Port yang sebenarnya dibuka ditentukan oleh `HTTP_ADDR` dan `GRPC_ADDR` dari _environment variable_.

`notification` membutuhkan satu perubahan lagi. Service ini tidak mengimpor modul `proto`, karena _event_ dikirim sebagai JSON di Kafka, sehingga `go.mod`-nya tidak memiliki _replace directive_ ke `../proto`. Di `notification/Dockerfile`, hapus kedua baris yang menyalin `proto` (`COPY proto/go.mod proto/go.sum proto/` dan `COPY proto/ /src/proto/`), lalu sesuaikan komentarnya. Bagian atas _file_ menjadi:

#perintah[```dockerfile
# Multi-stage build of the notification service. Build context: studi-kasus/ (not this
# directory), the same as for account and transfer, so make images builds all
# three the same way. Notification does not import the proto module (the
# events are JSON on Kafka), so only notification/ is copied:
#   docker build -f notification/Dockerfile -t studi-kasus/notification:1.0.0 .
FROM golang:1.27.2-alpine AS build

# GOWORK=off: build this module with its own go.mod/go.sum, not the workspace.
# The image then depends only on this service; a change in another
# service's go.mod does not invalidate the cache here, and the CI pipeline of
# one service builds it alone (Lab 10).
# CGO_ENABLED=0: a static binary without libc, which runs in an empty image.
ENV GOWORK=off CGO_ENABLED=0

# Module files first: the download layer stays cached until go.mod/go.sum
# change, not on every source edit.
WORKDIR /src
COPY notification/go.mod notification/go.sum notification/
WORKDIR /src/notification
RUN go mod download

COPY notification/ /src/notification/
```]

Bagian sesudahnya (`RUN go build ...` hingga `ENTRYPOINT`) tetap sama dengan hasil `sed`.

=== _File_ `.dockerignore`

Saat `docker build` dijalankan, seluruh isi _build context_ dikirim ke _builder_. Direktori `k8s/`, `observability/`, dan dokumentasi tidak dibutuhkan untuk kompilasi; jika ikut terkirim, setiap perubahan pada _file_ tersebut juga membuat _cache_ tidak berlaku lagi. Buat `studi-kasus/.dockerignore`:

#perintah[```
# Build context is studi-kasus/ (make images, compose profile apps). Only Go
# sources and module files are needed; everything else would only slow down
# the upload to the builder and invalidate its cache.
**/bin
k8s
observability
*.md
compose.yaml
Makefile
```]

=== Target `make images`

Tambahkan bagian berikut di akhir `studi-kasus/Makefile`. `VERSION` sengaja tidak memiliki nilai _default_, sehingga _tag_ setiap _image_ selalu ditentukan secara eksplisit saat _build_.

#perintah[```makefile
# Lab 9 helpers.

# Images for k3d. VERSION is the tag, e.g. make images VERSION=1.0.0, and is
# required: the image name says which build it is. Nothing stops a rebuild under
# an existing tag, and it rolls nothing: the image reference is unchanged, so
# running pods keep the old image while pods created later (after another
# k3d-import) get the new one. A change = a new VERSION (1.0.1), make k3d-import
# with it, then
# kubectl set image or newTag in k8s/overlays/k3d/kustomization.yaml.
# Build context is this directory: account and transfer copy proto/ next to the
# service (go.mod replace ../proto); notification does not import it.
IMAGE_REPO := studi-kasus
CLUSTER := bank
NAMESPACE := bank
IMAGES = $(foreach s,$(SERVICES),$(IMAGE_REPO)/$(s):$(VERSION))

images:
	@test -n "$(VERSION)" || { echo "VERSION is required, e.g. make images VERSION=1.0.0" >&2; exit 1; }
	@for s in $(SERVICES); do docker build -f $$s/Dockerfile -t $(IMAGE_REPO)/$$s:$(VERSION) . || exit 1; done
```]

Baris perintah di bawah target diawali karakter _tab_, bukan spasi. Tambahkan juga `images` ke daftar `.PHONY` di bagian atas `Makefile`. Variabel `SERVICES` sudah ada sejak lab sebelumnya (`account transfer notification`).

`make` tidak mencegah _build_ ulang dengan _tag_ yang sudah ada. Referensi _image_ di Deployment tidak berubah, sehingga tidak terjadi _rollout_. _Pod_ yang sedang berjalan tetap menggunakan _image_ lama, sedangkan _pod_ yang dibuat kemudian (setelah `make k3d-import` ulang) menggunakan _image_ baru dengan _tag_ yang sama. Akibatnya, dua _pod_ dengan _tag_ yang sama dapat menjalankan hasil _build_ yang berbeda tanpa disadari. Karena itu setiap perubahan kode mendapat `VERSION` baru (`1.0.1`, `1.0.2`, dan seterusnya), seperti di latihan _rolling update_.

_Build_ ketiga _image_:

#perintah[```bash
make images VERSION=1.0.0
docker images 'studi-kasus/*'
```]

Hasilnya tiga _image_ dengan _tag_ `1.0.0`. Isi setiap _image_ hanya _binary_ (sekitar 21–23 MB) dan sertifikat CA. Angka yang tampil di `docker images` bergantung pada _image store_ Docker:

- _containerd image store_ (Docker Engine 29, Docker Desktop versi baru) menampilkan dua kolom: `CONTENT SIZE` sekitar 8–9 MB (ukuran terkompresi) dan `DISK USAGE` sekitar 31–34 MB (ukuran terkompresi ditambah hasil ekstraknya);
- _image store_ klasik menampilkan satu kolom `SIZE` sekitar 21–23 MB (ukuran tanpa kompresi).

Semua angka tersebut jauh lebih kecil dibanding _image_ berbasis `golang:alpine`.

Pastikan _image_ dapat berjalan dengan UID sembarang dan _root filesystem_ _read-only_, seperti di OpenShift. Tanpa _environment variable_ apa pun, service harus berhenti dengan pesan yang menyebut semua variabel yang belum diisi:

#perintah[```bash
docker run --rm --user 1000690000:0 --read-only studi-kasus/account:1.0.0
```]

_Output_ yang diharapkan berupa satu baris log JSON:

#perintah[```
{"time":"...","level":"ERROR","msg":"account service stopped","error":"missing required environment variables: HTTP_ADDR, GRPC_ADDR, DATABASE_URL, OAUTH_ISSUER, OAUTH_JWKS_URL, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME"}
```]

Pesan tersebut membuktikan bahwa _binary_ dapat dieksekusi oleh UID selain 65532, dan bahwa service langsung berhenti jika ada variabel yang kosong, tanpa menebak nilainya.

=== _Listener_ Kafka untuk _Pod_ di k3d

Klien Kafka bekerja dalam dua tahap. Klien terhubung ke alamat _bootstrap_, lalu _broker_ mengirim daftar alamat yang di-_advertise_ (_advertised listener_), dan klien membuka koneksi baru ke alamat tersebut. _Listener_ `HOST` meng-_advertise_ `localhost:19092`. Di dalam _pod_, `localhost` berarti _pod_ itu sendiri, sehingga koneksi kedua gagal walaupun koneksi _bootstrap_ berhasil.

Karena itu Kafka membutuhkan _listener_ ketiga yang meng-_advertise_ `host.k3d.internal:19093`. Ubah bagian `kafka` di `compose.yaml`: komentar di atasnya, tiga variabel _listener_, dan daftar `ports`.

#perintah[```yaml
  # Single-node Kafka in KRaft mode: the same process is broker and controller,
  # no ZooKeeper. Three client listeners:
  #   HOST     localhost:19092 for the services running on the laptop
  #   INTERNAL kafka:29092 for containers on the compose network (kafka-init,
  #            profile apps)
  #   K3D      host.k3d.internal:19093 for pods in the k3d cluster (Lab 9);
  #            inside the cluster "localhost" is the pod itself
  # A client connects to the bootstrap address, then reconnects to the address
  # the broker advertises for its listener; that is why each audience needs its
  # own listener.
  kafka:
    image: apache/kafka:4.3.1
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: HOST://:19092,INTERNAL://:29092,K3D://:19093,CONTROLLER://:9093
      KAFKA_ADVERTISED_LISTENERS: HOST://localhost:19092,INTERNAL://kafka:29092,K3D://host.k3d.internal:19093
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: HOST:PLAINTEXT,INTERNAL:PLAINTEXT,K3D:PLAINTEXT,CONTROLLER:PLAINTEXT
      # ... variabel lain tidak berubah ...
    ports:
      - "19092:19092"
      - "19093:19093"
```]

Terapkan perubahan tersebut. Docker Compose membuat ulang _container_ `kafka` karena konfigurasinya berubah, sedangkan data _topic_ tetap tersimpan di _volume_:

#perintah[```bash
make infra-up
docker compose ps kafka
```]

Kolom `PORTS` menampilkan `19092` dan `19093`.

=== Seluruh Sistem di Docker Compose (_Profile_ `apps`)

Sebelum masuk ke Kubernetes, _image_ diuji terlebih dahulu di Docker Compose. Tahap ini memisahkan dua jenis masalah: masalah pada _image_ (_binary_ gagal dijalankan, ada yang menulis ke _filesystem_) muncul di sini, sedangkan masalah jaringan k3d baru muncul di tahap berikutnya.

Alamat yang digunakan berubah. Di dalam _container_, `localhost` merujuk ke _container_ itu sendiri, sehingga setiap alamat infrastruktur diganti dengan nama _compose service_ (`db-account:5432`, `kafka:29092`, `hydra:4444`, `otel-lgtm:4317`). Pengecualiannya `OAUTH_ISSUER`: nilainya tetap `http://localhost:14444/`, karena Hydra selalu menulis _issuer_ yang dikonfigurasi (`URLS_SELF_ISSUER`) ke _claim_ `iss`, apa pun alamat yang digunakan untuk meminta _token_. Jika `OAUTH_ISSUER` diubah menjadi `http://hydra:4444/`, setiap _token_ ditolak karena nilai `iss` tidak cocok.

`read_only: true` menerapkan _root filesystem_ _read-only_ yang sama dengan `readOnlyRootFilesystem` di Kubernetes. Service yang mencoba menulis _file_ akan gagal di sini lebih dahulu.

Tambahkan juga komentar berikut di akhir komentar pembuka `compose.yaml`, tepat sebelum baris `services:`:

#perintah[```yaml
#
# Lab 9: profile "apps" runs the three services as containers too (make
# apps-up); in k3d only the services run in the cluster and reach this
# infrastructure through host.k3d.internal and the published ports.
```]

Tambahkan ketiga service berikut di `compose.yaml`, di bawah `hydra-init` dan sebelum bagian `volumes:`:

#perintah[```yaml
  # Lab 9: the three services as containers (make apps-up), built from the
  # Dockerfile of each service with studi-kasus/ as build context. Same
  # variables as in the service Makefiles, but the addresses are compose
  # service names: inside a container, localhost is the container itself.
  # Exception: OAUTH_ISSUER stays http://localhost:14444/, because that is the
  # "iss" Hydra writes into every token (URLS_SELF_ISSUER), whichever address
  # the token was requested from.
  # read_only: the same read-only root filesystem as in Kubernetes
  # (readOnlyRootFilesystem), so a service that tries to write a file fails
  # here first.
  # Stop the services started with make -C <service> run first: the published
  # ports are the same.
  account:
    profiles: ["apps"]
    build:
      context: .
      dockerfile: account/Dockerfile
    read_only: true
    environment:
      HTTP_ADDR: ":8081"
      GRPC_ADDR: ":9091"
      DATABASE_URL: postgres://account:account123@db-account:5432/account
      OAUTH_ISSUER: http://localhost:14444/
      OAUTH_JWKS_URL: http://hydra:4444/.well-known/jwks.json
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-lgtm:4317
      OTEL_SERVICE_NAME: account
    # REST only (28081 -> 8081): the gRPC API is internal, transfer reaches it as account:9091.
    # Published, so make fault-* and the Prometheus scrape over
    # host.docker.internal keep working.
    ports:
      - "28081:8081"
    depends_on:
      db-account:
        condition: service_healthy
      hydra:
        condition: service_healthy

  transfer:
    profiles: ["apps"]
    build:
      context: .
      dockerfile: transfer/Dockerfile
    read_only: true
    environment:
      HTTP_ADDR: ":8082"
      DATABASE_URL: postgres://transfer:transfer123@db-transfer:5432/transfer
      ACCOUNT_GRPC_ADDR: account:9091
      KAFKA_BROKERS: kafka:29092
      KAFKA_TOPIC: transfer-events
      OAUTH_ISSUER: http://localhost:14444/
      OAUTH_JWKS_URL: http://hydra:4444/.well-known/jwks.json
      OAUTH_CLIENT_ID: transfer-service
      # Lab value, visible in the repository. Production: a secret store.
      OAUTH_CLIENT_SECRET: transfer-service-secret
      OAUTH_TOKEN_URL: http://hydra:4444/oauth2/token
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-lgtm:4317
      OTEL_SERVICE_NAME: transfer
    # Docker sends SIGKILL 10 s after SIGTERM by default; transfer waits up to
    # 60 s for sagas in flight (shutdownGrace in main.go) plus 5 s for the
    # telemetry flush.
    stop_grace_period: 70s
    ports:
      - "28082:8082"
    depends_on:
      db-transfer:
        condition: service_healthy
      kafka:
        condition: service_healthy
      hydra:
        condition: service_healthy
      account:
        condition: service_started

  notification:
    profiles: ["apps"]
    build:
      context: .
      dockerfile: notification/Dockerfile
    read_only: true
    environment:
      HTTP_ADDR: ":8083"
      DATABASE_URL: postgres://notification:notification123@db-notification:5432/notification
      KAFKA_BROKERS: kafka:29092
      KAFKA_TOPIC: transfer-events
      KAFKA_GROUP_ID: notification
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-lgtm:4317
      OTEL_SERVICE_NAME: notification
    ports:
      - "28083:8083"
    depends_on:
      db-notification:
        condition: service_healthy
      kafka:
        condition: service_healthy
```]

`stop_grace_period: 70s` pada `transfer` mengikuti _timeout_ _graceful shutdown_ `transfer`. Setelah menerima `SIGTERM`, `transfer` menunggu transfer yang sedang berjalan hingga 60 detik agar tidak ada _saga_ yang terpotong di antara _debit_ dan _credit_. Batas ini ditetapkan oleh konstanta `shutdownGrace` di `transfer/main.go` pada _checkpoint_ `lab-08`. Nilainya mencakup durasi terburuk satu _saga_: _debit_ dan _credit_ masing-masing 11,75 detik (4 percobaan × 2 detik + 3 jeda _backoff_ × 1,25 detik), _reversal_ 32 detik, ditambah beberapa detik untuk penulisan ke database. Jika `transfer/main.go` hasil kerja peserta masih menggunakan `10*time.Second` sebagai _timeout_ `srv.Shutdown`, tambahkan konstanta berikut di atas `func main()`:

```go
// shutdownGrace is how long the HTTP server waits on SIGTERM for transfers in
// flight. A saga cut mid-way leaves a PENDING or DEBITED row that nothing
// resumes (see README), so the wait covers the worst case of one saga under
// accountclient.ProductionSettings:
//
//	debit    4 attempts x 2 s + 3 backoffs x 1.25 s  = 11.75 s
//	credit   same                                    = 11.75 s
//	reversal 30 s retry window + one last 2 s attempt = 32 s
//	                                                    55.5 s
//
// plus a few seconds for the database writes in between. The platform must
// give the process at least this long before SIGKILL (Kubernetes:
// terminationGracePeriodSeconds).
const shutdownGrace = 60 * time.Second
```

lalu ganti `10*time.Second` pada `context.WithTimeout` sebelum `srv.Shutdown` dengan `shutdownGrace`.

Docker secara _default_ mengirim `SIGKILL` 10 detik setelah `SIGTERM`, sehingga tanpa pengaturan ini _saga_ yang sedang berjalan dapat terhenti di tengah.

Karena berada di _profile_ `apps`, ketiga service tersebut tidak ikut berjalan saat `make infra-up` dan baru berjalan jika _profile_ tersebut diaktifkan. Sisipkan kedua target berikut tepat di bawah komentar `# Lab 9 helpers.` di `Makefile`, sebelum `IMAGE_REPO :=`, dan tambahkan keduanya ke daftar `.PHONY`:

#perintah[```makefile
# The three services as containers next to the infrastructure (compose profile
# apps), rebuilt from the Dockerfiles. Run make infra-up first, and stop the
# services started with make -C <service> run: the ports are the same.
apps-up:
	docker compose --profile apps up -d --build account transfer notification

apps-down:
	docker compose --profile apps rm -sf account transfer notification
```]

Ubah juga `infra-down` dan `infra-reset`. Perintah `docker compose down` melewati service dari _profile_ yang tidak aktif, dan _container_ service yang tertinggal mencegah _network_ dihapus:

#perintah[```makefile
# --profile init/apps: down skips services of inactive profiles, and a leftover
# kafka-init or service container would keep the network from being removed.
infra-down:
	docker compose --profile init --profile apps down

# Removes the database and Kafka volumes too: all lab data is lost.
infra-reset:
	docker compose --profile init --profile apps down -v
```]

Jalankan dan coba satu transfer. Port yang digunakan sama dengan Lab 8, sehingga perintah dari lab sebelumnya tetap berlaku:

#perintah[```bash
make apps-up
docker compose ps account transfer notification
TOKEN=$(make -s token)
curl -i -X POST localhost:28082/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
make apps-down
```]

Transfer yang berhasil menghasilkan `HTTP/1.1 201 Created` dengan `"status":"COMPLETED"`. Jika rekening `1111111111` atau `2222222222` belum ada (misalnya setelah `make infra-reset`), buat terlebih dahulu dengan `POST /accounts` seperti di Lab 1, misalnya `curl -X POST localhost:28081/accounts -d '{"number":"1111111111","owner_name":"Budi","initial_balance":"1000000"}'`.

Jalankan `make apps-down` sebelum melanjutkan. Jika _container_ `notification` dari _profile_ `apps` tetap berjalan, _container_ tersebut berbagi _consumer group_ dengan _pod_ `notification` di k3d.

=== _Manifest_ Kubernetes

_Manifest_ untuk lab ini sudah disediakan. Ambil direktori `k8s/` dan `README.md` dari _checkpoint_ `lab-09` tanpa mengubah _file_ lain. `README.md` berisi bagian Lab 9 sebagai bahan rujukan:

#perintah[```bash
git checkout lab-09 -- k8s README.md
```]

Strukturnya mengikuti pola Kustomize _base_ dan _overlay_:

#perintah[```
k8s/
  base/                 sama di semua environment
    kustomization.yaml
    account/            configmap, secret (kosong), deployment, service
    transfer/           configmap, secret (kosong), deployment, service, ingress
    notification/       configmap, secret (kosong), deployment, service
  overlays/k3d/         namespace bank, alamat infrastruktur, credential lab, tag image
    kustomization.yaml
    namespace.yaml
    config.yaml
    secrets.yaml
```]

_Base_ berisi konfigurasi yang berlaku sama di semua _environment_: k3d di laptop, _server_ latihan bersama di Lab 10, dan _production_. _Base_ tidak dapat di-_deploy_ sendiri, karena alamat infrastruktur, _credential_, _tag image_, dan _namespace_ diisi di _overlay_. Jika ada _key_ yang tidak diisi di _overlay_, service berhenti saat _startup_ dengan pesan `missing required environment variables: ...`, dan _pod_ masuk status `CrashLoopBackOff`. Perilaku ini lebih mudah didiagnosis dibandingkan service yang berjalan dengan nilai tebakan.

Hasil gabungan _base_ dan _overlay_ dapat dilihat tanpa menerapkannya ke _cluster_:

#perintah[```bash
kubectl kustomize k8s/overlays/k3d | less
```]

Bagian berikut membahas pengaturan penting di _manifest_ tersebut. Baca _file_-nya sambil mengikuti penjelasan.

==== Deployment: _Probe_ dan _Rolling Update_

Kutipan dari `k8s/base/account/deployment.yaml`:

#perintah[```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  ...
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            failureThreshold: 3
```]

Konsep _liveness_ dan _readiness_, termasuk tabel kondisinya, sudah dibahas di Lab 1 (@lab01-liveness-readiness). _Manifest_ di atas menghubungkan kedua _endpoint_ tersebut dengan tindakan Kubernetes:

#table(
  columns: (1fr, 1.5fr, 2.4fr),
  table.header([_Probe_], [Pemeriksaan], [Tindakan Kubernetes saat Gagal]),
  [`readinessProbe`], [`GET /readyz` setiap 5 detik dengan batas waktu 3 detik. Dianggap gagal setelah 2 kegagalan berturut-turut], [_Pod_ dikeluarkan dari daftar _endpoint_ Service sehingga tidak menerima _request_ baru, tetapi _container_ tidak di-_restart_. Kolom `READY` di `kubectl get pods` menjadi `0/1`. _Pod_ kembali menerima _request_ setelah `/readyz` kembali berhasil],
  [`livenessProbe`], [`GET /healthz` setiap 10 detik. Dianggap gagal setelah 3 kegagalan berturut-turut], [kubelet menghentikan lalu menjalankan ulang _container_. Kolom `RESTARTS` bertambah],
)

`/readyz` hanya memeriksa database milik service itu sendiri. `transfer` tidak memeriksa `account` maupun Kafka di _readiness probe_, karena gangguan pada keduanya sudah ditangani _circuit breaker_ dan _outbox_. `/healthz` tidak memeriksa dependensi apa pun, sehingga database yang mati tidak memicu _restart_ massal. _Readiness probe_ diberi `timeoutSeconds: 3`, lebih panjang dari batas 2 detik untuk _ping_ database di `/readyz`. Dengan begitu, hasil _ping_ yang menentukan _pod_ siap atau tidak. _Liveness probe_ tetap menggunakan nilai bawaan Kubernetes (`timeoutSeconds: 1`), karena `/healthz` tidak menunggu apa pun.

_Manifest_ tidak memuat `startupProbe`, karena _service_ Go di studi kasus selesai _startup_ dalam waktu kurang dari satu detik. _Service_ dengan _startup_ lambat menambahkan `startupProbe`. Selama _probe_ ini belum berhasil, kubelet menunda _liveness_ dan _readiness probe_, sehingga _container_ tidak di-_restart_ sebelum selesai _startup_.

- *`maxSurge: 1`, `maxUnavailable: 0`.* Saat _rolling update_, Kubernetes membuat satu _pod_ baru terlebih dahulu dan baru menghentikan _pod_ lama setelah _pod_ baru lolos _readiness probe_. Jika _image_ baru gagal berjalan, _rollout_ terhenti dan _pod_ lama tetap melayani _request_.

==== Deployment: Menghentikan _Pod_ dengan Aman

Kutipan lain dari `k8s/base/account/deployment.yaml`:

#perintah[```yaml
      terminationGracePeriodSeconds: 30
      containers:
        - name: account
          ...
          lifecycle:
            preStop:
              sleep:
                seconds: 5
```]

Saat _pod_ dihentikan (_rolling update_, _scale down_), Kubernetes mengeluarkan _pod_ dari daftar _endpoint_ Service dan dari Traefik bersamaan dengan saat _pod_ mulai dihentikan. Akibatnya, selama beberapa detik _request_ baru masih dikirim ke _pod_ tersebut. Tanpa jeda, server di dalam _pod_ sudah mulai ditutup dan menolak _request_ tersebut.

_Hook_ `preStop` dijalankan kubelet sebelum `SIGTERM`. Aksi `sleep` menunda `SIGTERM` selama 5 detik untuk memberi waktu hingga _pod_ tidak lagi menerima _request_ baru. Setelah itu, _graceful shutdown_ di `main.go` menyelesaikan _request_ yang sedang diproses. Aksi `sleep` bawaan Kubernetes (tersedia sejak versi 1.30) tidak membutuhkan _shell_. Bentuk `exec` dengan perintah `sleep 5` tidak dapat digunakan, karena _image_ `scratch` tidak memiliki _shell_ maupun _binary_ `sleep`.

`terminationGracePeriodSeconds` dihitung sejak `preStop` dimulai. Setelah batas tersebut lewat, kubelet mengirim `SIGKILL`. Nilainya harus mencakup jeda `preStop`, _timeout_ _shutdown_ service, dan 5 detik untuk mengirim sisa telemetri:

#table(
  columns: (auto, auto, 1fr),
  [Service], [`terminationGracePeriodSeconds`], [Rincian],
  [`account`], [30], [5 detik `preStop` + 10 detik untuk panggilan HTTP dan gRPC yang sedang berjalan + 5 detik telemetri, ditambah cadangan],
  [`notification`], [30], [5 detik `preStop` + 10 detik untuk _request_ HTTP yang sedang diproses (setelah _consumer_ Kafka dihentikan) + 5 detik telemetri, ditambah cadangan],
  [`transfer`], [75], [5 detik `preStop` + 60 detik `shutdownGrace` agar _saga_ tidak terpotong di antara _debit_ dan _credit_ + 5 detik telemetri, ditambah cadangan],
)

Nilai _default_ Kubernetes (30 detik) tidak cukup untuk `transfer`. Jika `shutdownGrace` di `transfer/main.go` diperbesar, `terminationGracePeriodSeconds` harus ikut diperbesar.

==== _Security Context_ tanpa `runAsUser`

#perintah[```yaml
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      ...
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```]

Kombinasi ini sesuai dengan _Pod Security Standard_ `restricted` di Kubernetes dan dengan _restricted SCC_ di OpenShift. `runAsUser` sengaja tidak diisi. _Image_ sudah berjalan sebagai UID 65532 karena instruksi `USER` di `Dockerfile`, sedangkan OpenShift menetapkan UID sendiri dari rentang milik _namespace_ dan menolak _pod_ yang meminta UID tetap di luar rentang tersebut. `runAsNonRoot: true` membuat kubelet menolak menjalankan _image_ yang _user_-nya `root`. Pemeriksaan ini hanya dapat dilakukan karena `USER` di `Dockerfile` berupa angka.

==== Service dan Koneksi gRPC

Service `account` (`k8s/base/account/service.yaml`) membuka dua port: 8081 untuk REST dan 9091 untuk gRPC. ConfigMap `transfer` mengisi `ACCOUNT_GRPC_ADDR` dengan `account:9091`, dan DNS _cluster_ me-_resolve_ nama pendek `account` ke Service di _namespace_ yang sama.

Service bertipe ClusterIP melakukan _load balancing_ per koneksi TCP. gRPC menggunakan satu koneksi HTTP/2 yang terus terbuka per klien, sehingga semua panggilan dari satu _pod_ `transfer` tetap menuju _pod_ `account` yang sama, walaupun `account` di-_scale_ menjadi beberapa _replica_. _Load balancing_ per panggilan membutuhkan _headless Service_ dengan _load balancing_ `round_robin` di sisi klien, atau _service mesh_.

==== Ingress

`k8s/base/transfer/ingress.yaml` meneruskan _path_ `/transfers` ke Service `transfer`. k3s menyertakan Traefik sebagai _ingress controller_, dan `make k3d-up` memetakan port 28080 di laptop ke port 80 Traefik. Hanya `/transfers` yang diteruskan, sedangkan _probe_, `/metrics`, dan `/debug/circuit-breaker` tetap berada di dalam _cluster_ dan dijangkau dengan `kubectl port-forward`. OpenShift menggunakan objek Route untuk keperluan yang sama, tetapi juga menerima Ingress dan membuat Route dari objek tersebut.

==== _Overlay_ k3d: Alamat Infrastruktur

`k8s/overlays/k3d/config.yaml` menambahkan _key_ khusus k3d ke ConfigMap dari _base_:

#perintah[```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: transfer
data:
  KAFKA_BROKERS: host.k3d.internal:19093
  KAFKA_TOPIC: transfer-events
  OAUTH_ISSUER: http://localhost:14444/
  OAUTH_JWKS_URL: http://host.k3d.internal:14444/.well-known/jwks.json
  OAUTH_CLIENT_ID: transfer-service
  OAUTH_TOKEN_URL: http://host.k3d.internal:14444/oauth2/token
  OTEL_EXPORTER_OTLP_ENDPOINT: http://host.k3d.internal:14317
```]

`host.k3d.internal` adalah nama yang ditambahkan k3d ke DNS _cluster_ dan mengarah ke laptop. Melalui nama tersebut, _pod_ menjangkau port yang dibuka Docker Compose di laptop:

#table(
  columns: (auto, 1fr),
  [Infrastruktur], [Alamat dari _pod_],
  [PostgreSQL], [`host.k3d.internal:15432`, `15433`, `15434` (di Secret, sebagai bagian dari `DATABASE_URL`)],
  [Kafka], [`host.k3d.internal:19093`, _listener_ `K3D` dari langkah sebelumnya],
  [Hydra], [JWKS dan _token endpoint_ melalui `http://host.k3d.internal:14444`; `OAUTH_ISSUER` tetap `http://localhost:14444/`],
  [OTLP], [`http://host.k3d.internal:14317`],
  [gRPC `account`], [`account:9091`, Service di _namespace_ yang sama],
)

Alasan `OAUTH_ISSUER` tetap `http://localhost:14444/` sama dengan di _profile_ `apps`: nilai tersebut dibandingkan dengan _claim_ `iss`, dan Hydra menulis _issuer_ yang dikonfigurasi, apa pun alamat yang digunakan untuk meminta _token_. Yang berubah hanya alamat untuk mengambil _key_ (JWKS) dan _token_.

_Trace_ dan log tetap masuk ke `otel-lgtm` melalui OTLP. _Metric_ dari _pod_ tidak terambil, karena Prometheus di `otel-lgtm` mengambil data dari port 28081–28083 di laptop, sedangkan _pod_ tidak membuka port di laptop.

==== _Overlay_ k3d: Secret dan _Tag Image_

`k8s/overlays/k3d/secrets.yaml` mengisi `DATABASE_URL` setiap service dan `OAUTH_CLIENT_SECRET` milik `transfer` melalui `stringData`. _Credential_ lab ini boleh ikut di-_commit_ karena hanya berlaku untuk infrastruktur di laptop peserta. Di _environment_ sungguhan, Secret tidak pernah disimpan di _repository_: Secret diambil dari _vault_ atau _secret operator_ (External Secrets, Sealed Secrets), atau dibuat oleh _pipeline_ dari _credential store_ miliknya.

Secret di Kubernetes hanya di-_encode_ base64 di etcd, tidak dienkripsi, kecuali _cluster_ mengaktifkan _encryption at rest_. Hak akses untuk membaca Secret diatur dengan RBAC.

Bagian `images:` di `k8s/overlays/k3d/kustomization.yaml` menetapkan _tag_ ketiga _image_:

#perintah[```yaml
images:
  - name: studi-kasus/account
    newTag: "1.0.0"
  - name: studi-kasus/transfer
    newTag: "1.0.0"
  - name: studi-kasus/notification
    newTag: "1.0.0"
```]

Deployment di _base_ hanya menyebut nama _image_ (`studi-kasus/account`) dengan `imagePullPolicy: IfNotPresent`. _Image_ dimasukkan langsung ke _cluster_ dengan `k3d image import`, sehingga kubelet menggunakan _image_ yang sudah ada dan tidak mencoba melakukan _pull_ dari _registry_.

=== Target `make` untuk k3d

Tambahkan target berikut ke bagian Lab 9 di `Makefile` (dan ke daftar `.PHONY`):

#perintah[```makefile
# One server node; port 28080 on the laptop goes to the cluster's ingress
# controller (Traefik, port 80). The k3s image is pinned; k3d itself pulls its
# helper images (k3d-proxy, k3d-tools) in the version of the k3d binary.
# k3d writes host.k3d.internal into the CoreDNS ConfigMap, but CoreDNS answers
# for it only after the ConfigMap reaches its pod, up to a minute later; pods
# started before that crash with "lookup host.k3d.internal ... no such host".
# So k3d-up waits until the cluster DNS (k3s default 10.43.0.10) resolves the
# name, asked from the server node container (its image has nslookup).
k3d-up:
	k3d cluster create $(CLUSTER) --image rancher/k3s:v1.36.5-k3s1 -p 28080:80@loadbalancer
	@echo "waiting until the cluster DNS resolves host.k3d.internal"
	@for i in $$(seq 90); do \
		docker exec k3d-$(CLUSTER)-server-0 nslookup host.k3d.internal 10.43.0.10 >/dev/null 2>&1 && exit 0; \
		sleep 2; \
	done; \
	echo "host.k3d.internal does not resolve in the cluster DNS after 180 s" >&2; exit 1

# Copies the images from the local Docker into the cluster's containerd, so no
# registry is needed (Lab 10 pushes to one).
k3d-import:
	@test -n "$(VERSION)" || { echo "VERSION is required, e.g. make k3d-import VERSION=1.0.0" >&2; exit 1; }
	$(call k3d-load,$(IMAGES))

# $(call k3d-load,IMAGE ...) imports images into the cluster and checks that
# the node's containerd really has each one (crictl resolves the name the way
# the kubelet does). k3d image import can report success while an image never
# arrives; the pod then tries to pull it from the network (ImagePullBackOff).
# A missing image is imported once more, directly into the node.
K3D_NODE = k3d-$(CLUSTER)-server-0
k3d-load = k3d image import -c $(CLUSTER) $(1) && \
	for img in $(1); do \
		docker exec $(K3D_NODE) crictl inspecti -q $$img >/dev/null 2>&1 && continue; \
		echo "$$img not found in the cluster after import, importing again" >&2; \
		k3d image import --mode direct -c $(CLUSTER) $$img && \
		docker exec $(K3D_NODE) crictl inspecti -q $$img >/dev/null 2>&1 || \
		{ echo "$$img is not in cluster $(CLUSTER) after two imports" >&2; exit 1; }; \
	done

# Applies the k3d overlay, then waits until every Deployment is rolled out
# (readiness probes pass) or reports which one is not.
k8s-apply:
	kubectl apply -k k8s/overlays/k3d
	@for s in $(SERVICES); do kubectl -n $(NAMESPACE) rollout status deployment/$$s --timeout=120s || exit 1; done

k3d-down:
	k3d cluster delete $(CLUSTER)
```]

_Image_ k3s di-_pin_ ke `rancher/k3s:v1.36.5-k3s1`. k3d me-_pull_ sendiri _image_ pendukungnya (`k3d-proxy` untuk _load balancer_ dan `k3d-tools` untuk `image import`) dengan versi yang sama dengan _binary_ k3d.

Bagian kedua `k3d-up` menunggu DNS _cluster_. k3d menulis nama `host.k3d.internal` ke ConfigMap CoreDNS, tetapi CoreDNS baru menjawab nama tersebut setelah perubahan ConfigMap dimuat oleh _pod_ CoreDNS, hingga sekitar satu menit kemudian. _Pod_ yang dijalankan sebelum itu berhenti dengan pesan `lookup host.k3d.internal ... no such host` dan di-_restart_ berulang kali. Perulangan di atas menanyakan nama tersebut ke DNS _cluster_ (alamat _default_ k3s `10.43.0.10`) dari _container node_ k3d setiap 2 detik, dan berhenti dengan pesan _error_ jika nama tersebut belum dapat di-_resolve_ setelah 180 detik.

`k3d-import` tidak berhenti pada pesan sukses `k3d image import`. Fungsi `k3d-load` memeriksa setiap _image_ di _containerd_ milik _node_ k3d dengan `crictl inspecti`, yaitu pencarian nama yang sama dengan yang dilakukan kubelet. Pemeriksaan ini diperlukan karena `k3d image import` pernah melaporkan sukses, padahal _image_ tidak sampai ke _node_. Akibatnya _pod_ mencoba mengambil _image_ dari jaringan dan berakhir di `ImagePullBackOff`. _Image_ yang tidak ditemukan di-_import_ ulang satu kali langsung ke _node_ (`--mode direct`). Bila _image_ tetap tidak ada, _target_ berhenti dengan pesan yang menyebut nama _image_ tersebut.

=== Menjalankan Sistem di k3d

Pastikan infrastruktur berjalan dan _image_ sudah di-_build_, lalu buat _cluster_, masukkan _image_, dan terapkan _manifest_:

#perintah[```bash
make infra-up
make images VERSION=1.0.0
make k3d-up
make k3d-import VERSION=1.0.0
make k8s-apply
```]

`make k3d-up` membuat _cluster_ bernama `bank` dan menjadikan _context_ `k3d-bank` sebagai _context_ aktif kubectl. Setelah baris `waiting until the cluster DNS resolves host.k3d.internal`, perintah ini biasanya menunggu sekitar 40–60 detik sebelum selesai. `make k8s-apply` selesai jika ketiga Deployment sudah _rolled out_:

// TODO(endy): confirm the exact rollout status lines on a real k3d 5.9.0 run before D-1.
#perintah[```
namespace/bank created
configmap/account created
...
ingress.networking.k8s.io/transfer created
deployment "account" successfully rolled out
deployment "transfer" successfully rolled out
deployment "notification" successfully rolled out
```]

Periksa objek yang dibuat:

#perintah[```bash
kubectl -n bank get pods,svc,ingress
```]

Ketiga _pod_ berstatus `Running` dengan kolom `READY` bernilai `1/1`, dan kolom `RESTARTS` bernilai `0`.

=== Transfer melalui Ingress

`make fault-*` dan pembuatan rekening menggunakan REST `account` di `localhost:28081`. Di k3d, port tersebut tidak terbuka di laptop. Buka terminal lain dan teruskan port Service `account` ke laptop; biarkan perintah ini berjalan:

#perintah[```bash
kubectl -n bank port-forward svc/account 28081:8081
```]

Rekening dari lab sebelumnya tetap ada, karena `account` di k3d menggunakan database `db-account` yang sama. Periksa saldonya, lalu kirim transfer melalui Ingress di port 28080:

#perintah[```bash
curl -sS localhost:28081/accounts/1111111111
TOKEN=$(make -s token)
curl -i -X POST localhost:28080/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

`make -s token` meminta _token_ ke Hydra di `localhost:14444` dari laptop, sehingga _claim_ `iss` bernilai `http://localhost:14444/`, sama dengan nilai `OAUTH_ISSUER` di _pod_. Respons yang diharapkan:

#perintah[```
HTTP/1.1 201 Created
Content-Type: application/json
Location: /transfers/3f0c...

{"id":"3f0c...","from_account":"1111111111","to_account":"2222222222","amount":"100000","status":"COMPLETED","created_at":"...","updated_at":"..."}
```]

Log _pod_ `transfer` memuat baris `"msg":"transfer completed"`, dan log _pod_ `notification` memuat `"msg":"notification sent"` dengan `transfer_id` yang sama:

#perintah[```bash
kubectl -n bank logs deploy/transfer --tail=20
kubectl -n bank logs deploy/notification --tail=20
```]

=== Latihan Mengubah Sistem di _Cluster_

Latihan berikut mengubah sistem yang sedang berjalan. Selama latihan, buka terminal lain dan amati perubahan _pod_:

#perintah[```bash
kubectl -n bank get pods -w
```]

==== _Scale_ `notification`

_Topic_ `transfer-events` memiliki tiga _partition_ dan semua _pod_ `notification` bergabung ke _consumer group_ `notification`. Kafka membagi _partition_ di antara anggota _group_, sehingga hingga tiga _pod_ dapat berbagi pekerjaan:

#perintah[```bash
kubectl -n bank scale deployment/notification --replicas=3
docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:19092 --describe --group notification
```]

Setelah _rebalance_ selesai, setiap _partition_ (0, 1, 2) memiliki `CONSUMER-ID` yang berbeda. Ulangi dengan `--replicas=4`: satu _pod_ tidak mendapat _partition_ dan tidak memproses _event_ apa pun, walaupun statusnya `Running` dan _ready_. Paralelisme _consumer group_ dibatasi oleh jumlah _partition_.

Kembalikan ke satu _replica_ setelah selesai:

#perintah[```bash
kubectl -n bank scale deployment/notification --replicas=1
```]

#note[*Jeda _rebalance_.* _Pod_ yang dihentikan dengan `SIGTERM` menutup _reader_ Kafka dan keluar dari _consumer group_ secara teratur, sehingga _partition_ miliknya segera dibagi ulang. Jika sebuah _container_ `notification` dihentikan paksa (`SIGKILL`, misalnya `kubectl delete pod --force --grace-period=0` atau _OOM kill_), Kafka baru membagi ulang _partition_ milik _container_ tersebut setelah _session timeout_, sekitar 30 detik. Selama jeda tersebut, _event_ di _partition_ yang bersangkutan belum diproses. Kondisi ini normal; tunggu sekitar 30 detik sebelum menyimpulkan bahwa _event_ hilang.]

==== Mengubah Konfigurasi

_Environment variable_ hanya dibaca saat proses dimulai. Perubahan ConfigMap tidak terlihat oleh _pod_ yang sedang berjalan, sehingga _pod_ baru harus dibuat dengan `kubectl rollout restart`.

Latihan ini sengaja membuat konfigurasi salah untuk mengamati perlindungan `maxUnavailable: 0`. Hapus baris `KAFKA_GROUP_ID: notification` dari ConfigMap `notification` di `k8s/overlays/k3d/config.yaml`, lalu terapkan dan _restart_:

#perintah[```bash
kubectl apply -k k8s/overlays/k3d
kubectl -n bank rollout restart deployment/notification
kubectl -n bank rollout status deployment/notification --timeout=60s
```]

`rollout status` berhenti dengan pesan _timeout_. _Pod_ baru masuk status `CrashLoopBackOff`, sedangkan _pod_ lama tetap `Running` dan terus memproses _event_, karena Kubernetes tidak menghentikan _pod_ lama sebelum _pod_ pengganti _ready_. Log _pod_ baru menyebut variabel yang hilang:

#perintah[```bash
kubectl -n bank get pods -l app.kubernetes.io/name=notification
kubectl -n bank logs <nama-pod-baru>
```]

#perintah[```
{"time":"...","level":"ERROR","msg":"notification service stopped","error":"missing required environment variables: KAFKA_GROUP_ID"}
```]

Kembalikan baris `KAFKA_GROUP_ID: notification`, terapkan lagi, lalu _restart_:

#perintah[```bash
kubectl apply -k k8s/overlays/k3d
kubectl -n bank rollout restart deployment/notification
kubectl -n bank rollout status deployment/notification
```]

`rollout restart` tetap diperlukan setelah nilai dikembalikan. _Pod_ yang berstatus `CrashLoopBackOff` baru mencoba berjalan lagi setelah jeda _backoff_, yang dapat mencapai 5 menit, sedangkan `rollout restart` langsung membuat _pod_ baru.

Setiap `kubectl apply -k k8s/overlays/k3d` melaporkan Secret sebagai `configured`, walaupun isinya tidak berubah. Penyebabnya bagian `stringData` di _overlay_: API _server_ memindahkan isinya ke `data`, sehingga `kubectl apply` selalu melihat perbedaan. Laporan tersebut tidak menandakan masalah.

#note[*Mengapa latihan ini mengubah ConfigMap, bukan Secret.* `kubectl apply` menghapus _key_ yang dihilangkan dari bagian `data` ConfigMap. Untuk Secret yang ditulis dengan `stringData`, hal tersebut tidak terjadi: API _server_ menyimpan isinya di bagian `data` dalam bentuk base64, sehingga _key_ yang dihapus dari `stringData` tetap ada di objek Secret yang tersimpan di _cluster_. Untuk menghapus _key_ dari Secret, hapus objek Secret-nya (`kubectl -n bank delete secret notification`), lalu _apply_ lagi.]

==== _Rolling Update_ dengan _Tag_ Baru

Setiap versi aplikasi mendapat _tag image_ sendiri. _Build_ _image_ dengan _tag_ `1.0.1`, masukkan ke _cluster_, lalu ganti _image_ Deployment `transfer`:

#perintah[```bash
make images VERSION=1.0.1
make k3d-import VERSION=1.0.1
kubectl -n bank set image deployment/transfer transfer=studi-kasus/transfer:1.0.1
kubectl -n bank rollout status deployment/transfer
```]

Kode tidak perlu diubah. Perubahan _tag_ di _pod template_ sudah cukup untuk memicu _rollout_. Sebaliknya, _build_ ulang dengan _tag_ `1.0.0` yang sama tidak memicu _rollout_ apa pun, karena referensi _image_ di Deployment tidak berubah. Di terminal `get pods -w`, _pod_ baru dibuat dan menjadi _ready_ (`1/1`) terlebih dahulu, baru kemudian _pod_ lama berstatus `Terminating`. Riwayat _rollout_ dapat dilihat dengan:

#perintah[```bash
kubectl -n bank rollout history deployment/transfer
kubectl -n bank get deployment transfer -o jsonpath='{.spec.template.spec.containers[0].image}'
```]

Cara lain yang lebih sesuai dengan prinsip _manifest_ sebagai _source of truth_ (acuan tunggal kondisi _cluster_): ubah `newTag` milik `studi-kasus/transfer` di `k8s/overlays/k3d/kustomization.yaml` menjadi `"1.0.1"`, lalu jalankan `kubectl apply -k k8s/overlays/k3d`. `kubectl set image` mengubah objek di _cluster_ tanpa mengubah _file_, sehingga `make k8s-apply` berikutnya mengembalikan _tag_ ke nilai di `kustomization.yaml`.

==== _Rollback_

#perintah[```bash
kubectl -n bank rollout undo deployment/transfer
kubectl -n bank rollout status deployment/transfer
kubectl -n bank get deployment transfer -o jsonpath='{.spec.template.spec.containers[0].image}'
```]

_Image_ kembali ke `studi-kasus/transfer:1.0.0`, dengan pola penggantian _pod_ yang sama seperti _rolling update_. `rollout undo` dapat menampilkan peringatan tentang anotasi `last-applied-configuration`. Peringatan tersebut tidak berpengaruh pada _rollback_ dan dapat diabaikan.

=== _Horizontal Pod Autoscaler_ (Opsional)

Bagian ini tidak dikerjakan di kelas karena keterbatasan waktu, tetapi semua bahannya tersedia di repositori. _Horizontal Pod Autoscaler_ (HPA) menambah _replica_ ketika beban naik dan menguranginya ketika beban turun. _Manifest_-nya ada di `k8s/hpa/transfer.yaml`, terpisah dari _overlay_ k3d, sehingga Lab 9 dan Lab 10 tetap berjalan tanpa HPA.

#perintah[```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: transfer
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: transfer
  minReplicas: 1
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```]

HPA membandingkan pemakaian CPU setiap _pod_ dengan `resources.requests.cpu` di Deployment `transfer`, yaitu 50m. Target 70% berarti rata-rata 35m per _pod_. Bila rata-rata melewati angka tersebut, HPA menambah _pod_ hingga paling banyak 4. Data pemakaian CPU berasal dari _metrics-server_, yang sudah berjalan di k3s. Pada _cluster_ lain, _metrics-server_ perlu dipasang terlebih dahulu. `stabilizationWindowSeconds: 60` membuat HPA menunggu 60 detik dengan beban rendah sebelum mengurangi _pod_. Nilai bawaannya 300 detik, terlalu lama untuk diamati dalam latihan.

Pasang HPA, lalu pastikan _metrics-server_ sudah memberikan data:

#perintah[```bash
make hpa-apply
```]

Di terminal kedua, pantau HPA:

#perintah[```bash
make hpa-watch
```]

Kolom `TARGETS` menampilkan `<unknown>/70%` sampai _metrics-server_ memiliki sampel pertama, sekitar satu menit. Di terminal ketiga, kirim transfer melalui Ingress dari 10 _loop_ paralel selama 180 detik:

#perintah[```bash
make hpa-load DURATION=180 CONCURRENCY=10
```]

Target `hpa-load` membuat dua rekening baru melalui `port-forward` ke `account`, mengambil _token_ dari Hydra, lalu mengirim transfer berulang kali. Di akhir, target tersebut menampilkan jumlah jawaban per kode HTTP. Selama beban berjalan, nilai di kolom `TARGETS` naik melewati 70% dan `REPLICAS` bertambah. Sekitar 60 detik setelah beban berhenti, `REPLICAS` kembali ke 1. Lihat alasan setiap perubahan dengan:

#perintah[```bash
kubectl -n bank describe hpa transfer
```]

Hapus HPA setelah selesai. Target ini juga mengembalikan `transfer` ke 1 _replica_:

#perintah[```bash
make hpa-delete
```]

Selama HPA terpasang, _field_ `replicas` di Deployment dikelola oleh HPA. `make k8s-apply` berikutnya mengisi kembali `replicas: 1` dari `base`, lalu HPA menaikkannya lagi pada pemeriksaan berikutnya. Karena itu, di _production_ _field_ `replicas` dihapus dari Deployment yang dikelola HPA.

=== Menghapus _Cluster_

Setelah selesai, _cluster_ dapat dihapus. Infrastruktur di Docker Compose dan isi database tidak terpengaruh:

#perintah[```bash
make k3d-down
```]

Untuk menjalankan sistem di k3d lagi, buat ulang _cluster_ dengan `make k3d-up`, `make k3d-import VERSION=1.0.0`, dan `make k8s-apply`. _Image_ perlu di-_import_ ulang karena _image_ tersimpan di dalam _cluster_ yang sudah dihapus.

== Verifikasi

Jalankan pemeriksaan berikut dari direktori `studi-kasus/` dengan _cluster_ `bank` dan infrastruktur yang berjalan.

+ Ketiga _image_ ada, masing-masing dengan `CONTENT SIZE` sekitar 8–9 MB (_containerd image store_) atau `SIZE` sekitar 21–23 MB (_image store_ klasik):
  #perintah[```bash
  docker images 'studi-kasus/*'
  ```]
+ _Image_ berjalan dengan UID sembarang dan _root filesystem_ _read-only_, lalu berhenti dengan pesan `missing required environment variables: ...` karena tidak ada _environment variable_:
  #perintah[```bash
  docker run --rm --user 1000690000:0 --read-only studi-kasus/transfer:1.0.0
  ```]
+ _Manifest_ dapat di-_render_ tanpa _error_, dan Deployment hasil _render_ tidak memuat `runAsUser`. Perintah kedua tidak menghasilkan _output_ apa pun:
  #perintah[```bash
  kubectl kustomize k8s/overlays/k3d > /dev/null && echo OK
  kubectl kustomize k8s/overlays/k3d | grep runAsUser
  ```]
+ Ketiga _pod_ `Running` dan `1/1`, Ingress `transfer` terdaftar dengan _class_ `traefik`:
  #perintah[```bash
  kubectl -n bank get pods,ingress
  ```]
+ Transfer melalui Ingress menghasilkan `201 Created` dan `"status":"COMPLETED"`, sedangkan _request_ tanpa _header_ `Authorization` mendapat respons `401 Unauthorized`:
  #perintah[```bash
  TOKEN=$(make -s token)
  curl -sS -X POST localhost:28080/transfers -H "Authorization: Bearer $TOKEN" \
    -d '{"from_account":"1111111111","to_account":"2222222222","amount":"1000"}'
  curl -i -X POST localhost:28080/transfers \
    -d '{"from_account":"1111111111","to_account":"2222222222","amount":"1000"}'
  ```]
+ Notifikasi tercatat untuk transfer tersebut. Teruskan port `notification` di terminal lain, lalu ganti `<id>` dengan nilai `id` dari respons transfer:
  #perintah[```bash
  kubectl -n bank port-forward svc/notification 28083:8083
  curl -sS 'localhost:28083/notifications?transfer_id=<id>'
  ```]
  Hasilnya _array_ JSON berisi satu notifikasi dengan `"event_type":"TransferCompleted"`.
+ _Trace_ transfer dari _pod_ tetap masuk ke Grafana (`http://localhost:13000`, Tempo), dengan _span_ dari `transfer`, `account`, dan `notification` dalam satu _trace_.

// TODO(endy): run the whole Verifikasi list once on Docker Desktop with k3d 5.9.0 (verified on Linux Docker Engine 29.9.1, 20 Okt).

== Masalah Umum

*_Pod_ berstatus `ErrImagePull` atau `ImagePullBackOff`.* _Image_ dengan _tag_ yang diminta tidak ada di _cluster_, sehingga kubelet mencoba melakukan _pull_ dari Docker Hub. Penyebabnya `make k3d-import` belum dijalankan, dijalankan dengan `VERSION` yang berbeda, atau _cluster_ dibuat ulang setelah _import_. Jalankan `make k3d-import VERSION=<tag>` dengan _tag_ yang sama dengan `newTag` di `kustomization.yaml`, lalu hapus _pod_ yang gagal agar dibuat ulang.

*_Pod_ berstatus `CrashLoopBackOff` setelah Docker atau laptop di-_restart_.* _Container_ k3d berjalan lagi tanpa nama `host.k3d.internal` di DNS _cluster_, dan log _pod_ memuat `lookup host.k3d.internal ... no such host`. Jalankan `k3d cluster stop bank`, lalu `k3d cluster start bank`. k3d menulis nama tersebut lagi, dan _pod_ berjalan normal dalam satu hingga dua menit tanpa perintah tambahan.

*_Pod_ berstatus `CrashLoopBackOff`.* Baca lognya dengan `kubectl -n bank logs <pod> --previous`. Pesan `missing required environment variables` berarti ada _key_ yang belum diisi di ConfigMap atau Secret _overlay_. Pesan koneksi database atau Kafka yang gagal berarti port di laptop tidak dapat dijangkau melalui `host.k3d.internal`; pastikan `make infra-up` sudah berjalan dan `docker compose ps` menampilkan port yang dibutuhkan.

*_Pod_ `Running` tetapi `READY` bernilai `0/1`.* _Readiness probe_ gagal karena database milik service tidak dapat dijangkau. Jalankan `kubectl -n bank describe pod <pod>` dan baca bagian `Events`.

*`notification` tidak menerima _event_, log menyebut `localhost:19092`.* Kafka masih menggunakan konfigurasi lama tanpa _listener_ `K3D`. Periksa `KAFKA_ADVERTISED_LISTENERS` di `compose.yaml`, lalu jalankan `make infra-up` agar _container_ `kafka` dibuat ulang.

*`curl localhost:28080/transfers` menghasilkan `404 page not found`.* Traefik membutuhkan beberapa puluh detik setelah `make k3d-up` hingga siap, dan Ingress baru dikenali setelah _manifest_ diterapkan. Periksa `kubectl -n kube-system get pods` dan `kubectl -n bank get ingress`. _Path_ selain `/transfers` memang tidak diteruskan oleh Ingress.

*`curl: (52) Empty reply from server` tepat setelah `make k8s-apply`.* `rollout status` sudah melaporkan _pod_ siap, tetapi Traefik baru menerima daftar _endpoint_ yang baru satu atau dua detik kemudian. Tunggu sebentar, lalu ulangi _request_. Jawaban `401` untuk _request_ tanpa _token_ menandakan bahwa _request_ sudah sampai ke `transfer`.

*Transfer ditolak `401` dengan _token_ yang baru dibuat.* `OAUTH_ISSUER` di ConfigMap tidak sama dengan nilai `iss` di _token_. Nilainya harus tepat `http://localhost:14444/`, termasuk garis miring di akhir. Jika Hydra di-_restart_, `make infra-up` membuat ulang _client_ OAuth2, dan _token_ lama tidak berlaku lagi.

*Transfer `FAILED` atau `503` dengan alasan `account` tidak tersedia.* _Pod_ `account` belum _ready_ atau DNS _cluster_ belum menjawab `account`. Periksa `kubectl -n bank get endpoints account` dan log `transfer`.

*`make k3d-up` gagal karena port 28080 sudah digunakan.* Hentikan proses lain yang membuka port 28080, lalu jalankan `make k3d-down` dan `make k3d-up` lagi.

*Notifikasi ganda atau _event_ diproses oleh proses di laptop.* Masih ada `notification` atau `transfer` di luar _cluster_ (`make -C ... run` atau _profile_ `apps`). Hentikan service di laptop dan jalankan `make apps-down`.

*`kubectl port-forward` berhenti dengan sendirinya.* `port-forward` terhubung ke satu _pod_. Jika _pod_ tersebut diganti (misalnya saat _rolling update_), jalankan ulang perintahnya.

== Eksplorasi Mandiri

+ *_Scale_ `account` dan koneksi gRPC.* Jalankan `kubectl -n bank scale deployment/account --replicas=3`, kirim sepuluh transfer, lalu bandingkan log ketiga _pod_ `account` (`kubectl -n bank logs <pod>`). Semua panggilan gRPC dari satu _pod_ `transfer` tetap menuju satu _pod_ `account`. Jelaskan penyebabnya dan cari tahu cara mengubahnya dengan _headless Service_ serta konfigurasi `round_robin` di klien gRPC. Perhatikan juga bahwa `make fault-slow` melalui `port-forward` hanya mengenai satu _pod_ `account`, karena _fault injection_ disimpan di memori setiap _pod_.
+ *_Debugging_ tanpa _shell_.* _Image_ `scratch` tidak memiliki _shell_. Masukkan _image_ `golang:1.27.2-alpine` (yang sudah di-_pull_ untuk _build_ dan memiliki _shell_) ke _cluster_ dengan `k3d image import -c bank golang:1.27.2-alpine`, lalu jalankan perintah berikut untuk menambahkan _ephemeral container_ ke _pod_ tersebut: `echo '{"securityContext":{"runAsUser":65532}}' > /tmp/debug.json`, kemudian `kubectl -n bank debug -it <pod-transfer> --image=golang:1.27.2-alpine --target=transfer --custom=/tmp/debug.json -- sh`. `runAsNonRoot: true` di _security context_ _pod_ juga berlaku untuk _ephemeral container_, sedangkan `golang:1.27.2-alpine` tidak memiliki instruksi `USER` sehingga berjalan sebagai `root`; tanpa _profile_ `--custom` tersebut, kubelet menolak menjalankan _container_ dengan status `CreateContainerConfigError`. Dari dalamnya, coba `wget -qO- localhost:8082/readyz`. _Ephemeral container_ berbagi _network namespace_ dengan _pod_ target, sehingga `localhost` di dalamnya adalah _pod_ `transfer`.
+ *Simulasi UID OpenShift.* Tambahkan _patch_ di _overlay_ k3d yang mengisi `runAsUser: 1000690000` pada `securityContext` _pod_ `transfer`, terapkan, dan pastikan _pod_ tetap _ready_. Setelah itu, coba _image_ dengan `USER root` (atau tanpa `USER`) dan amati pesan kubelet ketika `runAsNonRoot: true` menolak _image_ tersebut (`kubectl describe pod`).
+ *Dua _replica_ `transfer`.* _Scale_ `transfer` menjadi 2, kirim beberapa transfer, lalu pastikan dengan `make outbox` bahwa setiap baris _outbox_ hanya dikirim sekali ke Kafka, karena _relay_ mengunci baris dengan `for update skip locked`. Aktifkan `make fault-error RATE=1` dan amati `/debug/circuit-breaker` di setiap _pod_ `transfer` (dengan `kubectl port-forward pod/<nama> 28082:8082`): setiap _replica_ memiliki status _circuit breaker_ sendiri.

== Checkpoint

Kondisi kode di akhir lab ini tersedia di _tag_ `lab-09`. Bandingkan hasil kerja dengan _checkpoint_ tersebut:

#perintah[```bash
git diff lab-09 -- .
```]

Peserta yang ingin langsung melanjutkan ke Lab 10 dari kondisi akhir Lab 9:

#perintah[```bash
git checkout lab-09
```]
