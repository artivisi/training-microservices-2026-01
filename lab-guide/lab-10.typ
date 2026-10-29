#import "../_template/panduan.typ": note, perintah

= Lab 10: _Pipeline_ CI/CD per Service

== Tujuan

Setelah lab ini, peserta mampu:

- menyusun _target_ `make` yang sama untuk laptop, runner CI, dan Jenkins: `image`, `push`, `apply`, `deploy`;
- menulis _workflow_ per service yang hanya berisi _step_ `run:` dan dipicu oleh perubahan di direktori service tersebut;
- memetakan setiap _step_ _workflow_ ke _stage_ _declarative pipeline_ Jenkins;
- menjalankan tahapan _pipeline_ satu service di laptop hingga _deploy_ ke k3d, lalu menelusuri versi yang berjalan lewat `kubectl rollout history`;
- menjelaskan _drift_ (selisih antara isi repository dan isi _cluster_) yang menjadi alasan GitOps.

== Gambaran

Hingga Lab 9, _image_ di-_build_ dan di-_deploy_ ke k3d dengan perintah manual: `make images`, `make k3d-import`, lalu `kubectl set image`. Lab 10 mengubah urutan perintah itu menjadi _pipeline_: setiap _commit_ ke `main` yang mengubah satu service menjalankan _test_, mem-_build_ _image_ dengan _tag_ berupa SHA _commit_, mengirim _image_ ke _container registry_, lalu menjalankan _rolling update_ Deployment service tersebut.

Ada tiga keputusan desain dalam lab ini.

*Satu _pipeline_ per service.* _Commit_ yang hanya mengubah `account` tidak perlu menguji ulang dan men-_deploy_ ulang `notification`. Setiap service punya _workflow_ dan `Jenkinsfile` sendiri dengan filter _path_. Perubahan di direktori bersama (`proto/`, `go.work`, `pipeline.mk`) memicu _pipeline_ semua service yang bergantung padanya.

*_Step_ hanya memanggil `make`.* _Workflow_ tidak menggunakan _action_ siap pakai (`uses:`). Setiap _step_ berisi perintah `make` yang juga bisa dijalankan di laptop, sehingga setiap _step_ setara dengan satu _stage_ Jenkins dan perpindahan dari satu CI ke CI lain cukup mengganti _file_ definisi tanpa mengubah logikanya.

*Tidak ada nilai _default_.* `REGISTRY`, `IMAGE_OWNER`, `VERSION`, dan `NAMESPACE` wajib diisi oleh pemanggil. Lebih aman bila _pipeline_ berhenti dengan pesan error dibandingkan mengirim _image_ ke registry yang salah atau men-_deploy_ ke _namespace_ orang lain.

Alur _pipeline_ di server pelatihan:

```
 laptop peserta          git server                   server pelatihan
 ──────────────          ──────────                   ────────────────
 git push main  ──────▶  repository  ──── job ─────▶  runner CI (label host)
                         container registry ◀─ push ─   1 Checkout   git fetch <sha>
                               │                        2 Test       make test
                               │                        3 Build      make image
                               │                        4 Push       make push
                               │                        5 Deploy     make deploy
                               │                               │
                               └──── pull image ─────▶  cluster, namespace peserta
                                     (registry-credentials)   apply (deploy pertama)
                                                              kubectl set image
                                                              rollout status
```

Alur yang sama di laptop, tanpa git server dan registry:

```
 git commit ─▶ make pipeline-k3d SERVICE=transfer
                 make test ─▶ make image ─▶ k3d image import ─▶ make deploy ─▶ k3d (namespace bank)
```

#note[
  *Status server pelatihan.* _Workflow_ dan _overlay_ `k8s/overlays/server` sudah dijalankan dari awal hingga akhir di server pelatihan (Langkah 10): _deploy_ pertama ke _namespace_ kosong, _rolling update_, dan dua peserta yang melakukan _push_ bersamaan. Ketiga `Jenkinsfile` sudah dijalankan di Jenkins LTS 2.580.1 dengan _deploy_ ke k3d (Langkah 6). Latihan yang bisa dijalankan sepenuhnya di laptop adalah `make pipeline-k3d` pada Langkah 8. Setelah training, Langkah 10 bisa diulang di VPS sendiri dengan `studi-kasus/server/setup.sh` (Langkah 11), yang sudah diuji dari VPS kosong hingga transfer lewat Ingress.
]

== Titik Awal

Lab ini melanjutkan kondisi akhir Lab 9: _image_ ketiga service bisa di-_build_, k3d bisa dibuat, dan _manifest_ `k8s/overlays/k3d` bisa di-_apply_. Ambil kode Lab 10 dari _tag_ `lab-10`, lalu tampilkan perubahannya terhadap Lab 9 (lihat bagian Cara Mengerjakan Lab di Lab 1). Jalankan dari folder repositori:

#perintah[```bash
git checkout -b lab-10-saya lab-09
git checkout lab-10 -- studi-kasus .forgejo .github .gitignore
git diff --staged lab-09 -- studi-kasus .forgejo .github .gitignore
cd studi-kasus
```]

Selain folder `studi-kasus`, Lab 10 menambahkan _workflow_ di `.forgejo` dan `.github` serta satu baris di `.gitignore`. Langkah 8 membuat _commit_ di _branch_ kerja `lab-10-saya`.

Pastikan prasyarat Lab 9 masih berjalan:

#perintah[
```bash
make infra-up
k3d version
kubectl version --client
```
]

== Langkah

=== Langkah 1: _Target_ _pipeline_ bersama di `pipeline.mk`

Ketiga service membutuhkan _target_ yang sama: mem-_build_ _image_, mengirimnya ke registry, membuat objek service di _cluster_ pada _deploy_ pertama, dan mengganti _image_ pada _deploy_ berikutnya. Agar tidak ditulis tiga kali, _target_ tersebut diletakkan di satu _file_ `studi-kasus/pipeline.mk` yang di-_include_ oleh `Makefile` setiap service. `Makefile` service cukup mengisi variabel `SERVICE`; nilai lainnya diisi oleh pemanggil.

Beberapa hal yang perlu diperhatikan sebelum menulis _file_-nya:

- Fungsi `require` memeriksa variabel yang kosong dan menghentikan `make` dengan daftar nama variabelnya, sama seperti `LoadConfig` di service.
- `image` menggunakan _build context_ `..` (direktori `studi-kasus/`), sama seperti Lab 9, karena `Dockerfile` menyalin `proto/`. Label `org.opencontainers.image.revision` menghubungkan _image_ dengan _commit_ asalnya.
- `push` membuat `DOCKER_CONFIG` sementara untuk setiap pemanggilan dan menghapusnya ketika _recipe_ (baris perintah di bawah _target_) selesai, sehingga _token_ registry tidak tertinggal di `~/.docker/config.json` milik pengguna runner setelah _job_ selesai. Mekanisme ini tidak mengisolasi peserta satu sama lain: runner digunakan bersama, dan siapa pun yang bisa mengubah _workflow_ bisa menjalankan perintah apa saja di _host_ runner. `REGISTRY_USER` dan `REGISTRY_PASSWORD` hanya dibaca dari _environment variable_, karena argumen baris perintah terlihat di daftar proses. Setelah _push_ berhasil, _image_ lokal dihapus dengan `docker image rm`. _Image_ itu sudah tersimpan di registry. Bila tidak dihapus, _image_ dari setiap _commit_ setiap peserta akan memenuhi disk runner. _Build cache_ tetap ada, sehingga _build_ berikutnya menggunakan ulang _layer_ yang tidak berubah.
- `apply` memasang bagian _overlay_ `k8s/overlays/server` milik satu service: ConfigMap, Service, dan Deployment, ditambah Ingress khusus untuk `transfer`. _Overlay_ itu tidak menyebut _namespace_ dan _tag image_. `apply` menulis _kustomization_ sementara di atas _overlay_ yang mengisi keduanya dari `NAMESPACE` dan `IMAGE`, lalu `kubectl apply -l app.kubernetes.io/name=<service>` hanya memasang objek yang berlabel service tersebut (label dipasang di Langkah 7). Tanpa filter label, Deployment service lain ikut terpasang dengan nama _image_ yang belum diganti. Direktori sementara `.apply.XXXXXX` dibuat di samping `Makefile` service, bukan di `/tmp`, karena _kustomize_ menolak _path_ absolut di `resources`. `apply` juga berhenti dengan pesan error selama _overlay_ masih berisi _placeholder_ `replace-me` (Langkah 7).
- `deploy` memeriksa terlebih dahulu apakah Deployment service sudah ada. `kubectl get --ignore-not-found` tidak mencetak apa pun hanya bila Deployment belum ada. Dalam kondisi itu `deploy` memanggil `apply`, sehingga _pipeline_ pertama setiap service membuat objeknya sendiri di _namespace_ kosong. Error lain, misalnya akses ditolak atau _cluster_ tidak bisa dihubungi, menghentikan `deploy` di baris itu. Setelah itu `deploy` menjalankan `kubectl set image`, lalu menulis anotasi `kubernetes.io/change-cause`. Anotasi disalin _controller_ ke ReplicaSet yang sedang aktif, sehingga `kubectl rollout history` menampilkan versi setiap revisi. Urutannya penting: anotasi yang ditulis sebelum `set image` akan menimpa catatan versi revisi sebelumnya. Bila _rollout_ gagal, `kubectl rollout status` ikut gagal sehingga _pipeline_ berhenti, sementara _pod_ lama tetap melayani karena Deployment menggunakan `maxUnavailable: 0`.

Buat _file_ `studi-kasus/pipeline.mk`:

#perintah[
```makefile
# Pipeline targets shared by the three service Makefiles (Lab 10). The
# workflows in .forgejo/workflows and the Jenkinsfile of each service call
# these targets and nothing else, so a laptop, the git server's runner and a
# Jenkins agent run the same commands.
#
# The including Makefile sets SERVICE. Everything else comes from the caller
# (command line or environment) and has no default: an image pushed to the
# wrong registry or a deploy into the wrong namespace is worse than a stopped
# pipeline.
#   REGISTRY       registry host, e.g. registry.example.com
#   IMAGE_OWNER    user or organization that owns the image in the registry
#   VERSION        image tag; the pipeline passes the commit SHA, so every
#                  commit has its own image and a tag is never overwritten
#   NAMESPACE      Kubernetes namespace of the deploy target
#   REGISTRY_USER, REGISTRY_PASSWORD   push credentials, environment only
#                  (a command-line argument shows up in the process list)

IMAGE = $(REGISTRY)/$(IMAGE_OWNER)/$(SERVICE):$(VERSION)

# $(call require,VAR ...) stops with the names of the empty variables, the
# same message style as the services' LoadConfig.
missing = $(strip $(foreach v,$(1),$(if $(strip $($(v))),,$(v))))
require = $(if $(call missing,$(1)),$(error missing required variables: $(call missing,$(1))))

.PHONY: image push apply deploy

# Build context is studi-kasus/ (..), as in Lab 9: the Dockerfile copies proto/
# next to the service. The revision label ties a running image back to its
# commit (docker inspect, or the registry UI).
image:
	$(call require,REGISTRY IMAGE_OWNER VERSION)
	docker build -f Dockerfile --label org.opencontainers.image.revision=$(VERSION) -t $(IMAGE) ..

# A throwaway DOCKER_CONFIG per call, removed when the recipe ends: the
# registry token is not left in the runner user's ~/.docker/config.json after
# the job. That is all it does. It is no isolation between participants on a
# shared runner: anyone who can edit a workflow runs commands on the runner
# host as the runner user, and can read whatever another job has on disk or in
# its environment while it runs.
# The local image is removed after a successful push: the registry has it,
# and on a shared runner one image per commit per participant fills the disk.
# The build cache stays, so the next build reuses unchanged layers.
push:
	$(call require,REGISTRY IMAGE_OWNER VERSION REGISTRY_USER REGISTRY_PASSWORD)
	@cfg=$$(mktemp -d) && trap 'rm -rf "$$cfg"' EXIT && \
	printf '%s' "$$REGISTRY_PASSWORD" | DOCKER_CONFIG="$$cfg" docker login $(REGISTRY) -u "$$REGISTRY_USER" --password-stdin && \
	DOCKER_CONFIG="$$cfg" docker push $(IMAGE)
	docker image rm $(IMAGE)

# Applies this service's part of OVERLAY into NAMESPACE with the image
# IMAGE: the ConfigMap, Service, Deployment (and Ingress of transfer). The
# overlay has no namespace and no image tag; a generated kustomization on top
# of it sets both, and kubectl apply -l keeps only the objects labelled with
# this service (the other services' Deployments would get an unresolved
# image). Refuses while the overlay still has a replace-me placeholder.
# make deploy calls it when the Deployment does not exist yet; make
# k8s-apply-server (top-level Makefile) calls it to bring a config change to
# the cluster.
# The generated kustomization lives in a temporary directory next to this
# Makefile, removed when the recipe ends: kustomize refuses an absolute path
# in resources, so the overlay is referenced relative to it.
OVERLAY := ../k8s/overlays/server
SELECTOR := app.kubernetes.io/name=$(SERVICE)

apply:
	$(call require,REGISTRY IMAGE_OWNER VERSION NAMESPACE)
	@if kubectl kustomize $(OVERLAY) | grep -n replace-me; then \
		echo "$(OVERLAY) still has replace-me placeholders (lines above)" >&2; exit 1; fi
	@k=$$(mktemp -d .apply.XXXXXX) && trap 'rm -rf "$$k"' EXIT && \
	printf '%s\n' \
		'apiVersion: kustomize.config.k8s.io/v1beta1' \
		'kind: Kustomization' \
		'namespace: $(NAMESPACE)' \
		'resources:' \
		'  - ../$(OVERLAY)' \
		'images:' \
		'  - name: studi-kasus/$(SERVICE)' \
		'    newName: $(REGISTRY)/$(IMAGE_OWNER)/$(SERVICE)' \
		'    newTag: "$(VERSION)"' > "$$k/kustomization.yaml" && \
	echo "apply $(OVERLAY) to namespace $(NAMESPACE), objects $(SELECTOR), image $(IMAGE)" && \
	kubectl -n $(NAMESPACE) apply -k "$$k" -l $(SELECTOR)

# Rolling update to the new image: the same "kubectl set image" + "rollout
# status" as the Lab 9 exercise. The first run of a service, in an empty
# namespace, creates the Deployment with make apply instead; set image then
# changes nothing and rollout status waits for the first pods.
# "get --ignore-not-found" prints nothing only when the Deployment does not
# exist; any other error (no access, cluster unreachable) stops here.
# The change-cause annotation is copied to the new ReplicaSet, so "kubectl
# rollout history" lists the version per revision. It comes after set image:
# the controller copies it to the ReplicaSet that is current at that moment,
# and annotating first would relabel the previous revision with the new
# version.
# A failed rollout fails the pipeline and leaves the old pods serving
# (maxUnavailable: 0); rolling back stays a human decision
# (kubectl rollout undo).
# kubectl uses KUBECONFIG; the pipeline points it at a kubeconfig that is
# limited to NAMESPACE.
deploy:
	$(call require,REGISTRY IMAGE_OWNER VERSION NAMESPACE)
	@d=$$(kubectl -n $(NAMESPACE) get deployment/$(SERVICE) --ignore-not-found -o name) || exit 1; \
	if [ -z "$$d" ]; then \
		echo "deployment/$(SERVICE) not in namespace $(NAMESPACE): first deploy, applying the overlay"; \
		$(MAKE) --no-print-directory apply || exit 1; \
	fi
	kubectl -n $(NAMESPACE) set image deployment/$(SERVICE) $(SERVICE)=$(IMAGE)
	kubectl -n $(NAMESPACE) annotate deployment/$(SERVICE) kubernetes.io/change-cause="$(SERVICE) $(VERSION)" --overwrite
	kubectl -n $(NAMESPACE) rollout status deployment/$(SERVICE) --timeout=180s
```
]

Baris _recipe_ di `Makefile` harus diawali karakter _Tab_, bukan spasi. Saat kode disalin dari PDF, _Tab_ biasanya berubah menjadi spasi, dan `make` lalu berhenti dengan pesan `missing separator`.

=== Langkah 2: _Include_ di `Makefile` setiap service

Tambahkan dua baris berikut di akhir `account/Makefile`, `transfer/Makefile`, dan `notification/Makefile`. Ketiga _file_ itu sudah mengisi `SERVICE := <nama service>` di baris awal sejak service tersebut dibuat (Lab 1, 2, dan 5), dan `pipeline.mk` membaca variabel tersebut.

#perintah[
```makefile

# image, push, deploy (Lab 10).
include ../pipeline.mk
```
]

Periksa bahwa _target_ baru berhenti dengan pesan error bila variabelnya kosong:

#perintah[
```bash
make -C transfer image
make -C transfer deploy REGISTRY=r IMAGE_OWNER=o VERSION=v
```
]

_Output_ yang diharapkan:

#perintah[
```
../pipeline.mk:31: *** missing required variables: REGISTRY IMAGE_OWNER VERSION.  Stop.
../pipeline.mk:100: *** missing required variables: NAMESPACE.  Stop.
```
]

Angka setelah `pipeline.mk:` adalah nomor baris pemanggilan `require`, sehingga bisa berbeda bila komentar ditulis dengan kata-kata sendiri. GNU make 4.x (umumnya di Linux) juga mencetak baris `make: Entering directory '.../studi-kasus/transfer'` dan `make: Leaving directory ...` di sekitar _output_ setiap perintah `make -C`, termasuk perintah `make -n -C` di bawah. GNU make 3.81 bawaan macOS tidak mencetak baris tersebut.

Opsi `-n` menampilkan perintah tanpa menjalankannya. Dengan opsi ini, isi _target_ `image` bisa diperiksa tanpa Docker:

#perintah[
```bash
make -n -C transfer image REGISTRY=k3d.local IMAGE_OWNER=studi-kasus VERSION=abc
```
]

#perintah[
```
docker build -f Dockerfile --label org.opencontainers.image.revision=abc -t k3d.local/studi-kasus/transfer:abc ..
```
]

Opsi `-n` tidak cocok untuk `deploy`. Baris _recipe_ yang berisi `$(MAKE)` tetap dijalankan walaupun ada `-n`, dan baris pertama `deploy` berisi `$(MAKE) apply`. Akibatnya `kubectl get deployment` benar-benar dijalankan, dan tanpa _cluster_ perintah itu berhenti dengan error koneksi. Urutan perintah `deploy` cukup dibaca dari `pipeline.mk`: `kubectl get` (dan `apply` bila Deployment belum ada), `kubectl set image`, `kubectl annotate`, lalu `kubectl rollout status`.

Nama _container_ di `kubectl set image` (`transfer=...`) mengacu pada nama _container_ di `k8s/base/transfer/deployment.yaml`, yaitu nama service itu sendiri.

=== Langkah 3: `.dockerignore` dan `.gitignore`

`Jenkinsfile` dan `pipeline.mk` tidak dibutuhkan untuk mem-_build_ _binary_. `Jenkinsfile` berada di dalam direktori service yang disalin oleh `COPY transfer/ /src/transfer/`, sehingga setiap perubahan `Jenkinsfile` membuat _cache layer_ tersebut tidak terpakai lagi dan membuat _build_ berikutnya lebih lama. `pipeline.mk` tidak disalin ke _image_, tetapi tetap ikut terkirim ke _builder_ sebagai bagian dari _build context_. Tambahkan keduanya ke `.dockerignore`, sama seperti `Makefile` dan `compose.yaml`, dengan dua baris di akhir `studi-kasus/.dockerignore`:

#perintah[
```
**/Jenkinsfile
pipeline.mk
```
]

Direktori sementara `.apply.XXXXXX` dari _target_ `apply` dihapus ketika _recipe_ selesai. Agar direktori yang tertinggal karena proses terhenti di tengah jalan tidak ikut ter-_commit_, tambahkan satu baris di akhir `.gitignore` di direktori _root_ repository:

#perintah[
```
.apply.*
```
]

=== Langkah 4: _Helper_ Lab 10 di `Makefile` utama

`Makefile` di `studi-kasus/` mendapat dua _target_ baru:

- `pipeline-k3d` menjalankan tahapan _pipeline_ satu service di laptop hingga _deploy_ ke k3d. Laptop tidak punya registry, sehingga `push` diganti `k3d image import`. _Tag_ _image_ diambil dari 12 karakter pertama SHA _commit_ saat ini. Karena itu _target_ ini berhenti dengan pesan error selama ada perubahan yang belum di-_commit_ di `studi-kasus/`: tanpa pemeriksaan tersebut, _image_ bisa berisi kode yang tidak ada di _commit_ yang namanya tertulis di _tag_.
- `k8s-apply-server` memanggil _target_ `apply` milik satu service. _Pipeline_ pertama sudah membuat objek service lewat `deploy`, sehingga _target_ ini hanya diperlukan untuk membawa perubahan `config.yaml` atau `ingress.yaml` di _overlay_ server ke _cluster_ (Langkah 10). Variabelnya sama dengan `apply`: `SERVICE`, `VERSION`, `REGISTRY`, `IMAGE_OWNER`, `NAMESPACE`.

Tambahkan kedua nama _target_ ke baris `.PHONY` yang sudah ada:

#perintah[
```makefile
.PHONY: infra-up infra-down infra-reset test proto fault-slow fault-error fault-clear fault-status breaker \
	events outbox replay duplicates token metrics apps-up apps-down images k3d-up k3d-import k8s-apply k3d-down \
	pipeline-k3d k8s-apply-server
```
]

Variabel `NAMESPACE := bank` dari Lab 9 perlu diganti nama menjadi `K3D_NAMESPACE`. `pipeline.mk` mengambil `NAMESPACE` dari pemanggil. Bila `NAMESPACE` diekspor di _environment_, nilai `bank` di `Makefile` utama akan menimpanya, lalu ikut diteruskan ke `make` service yang dipanggil `k8s-apply-server`. Ganti definisinya:

#perintah[
```makefile
# K3D_NAMESPACE, not NAMESPACE: pipeline.mk takes NAMESPACE from the caller,
# and a top-level value would be passed on to it.
K3D_NAMESPACE := bank
```
]

Ganti juga penggunaannya di _target_ `k8s-apply`:

#perintah[
```makefile
	@for s in $(SERVICES); do kubectl -n $(K3D_NAMESPACE) rollout status deployment/$$s --timeout=120s || exit 1; done
```
]

Lalu tambahkan blok berikut di akhir `studi-kasus/Makefile`, setelah _target_ `k3d-down`. Variabel `CLUSTER` dan `IMAGE_REPO` sudah didefinisikan di Lab 9.

#perintah[
```makefile
# Lab 10 helpers. The pipeline itself is in .forgejo/workflows (git server's
# runner) and <service>/Jenkinsfile; its steps are the targets image, push and
# deploy in pipeline.mk.

# The pipeline of one service on the laptop, against k3d: test, image, then
# k3d image import in place of push (no registry on the laptop), then deploy.
# Usage: make pipeline-k3d SERVICE=transfer (after make k8s-apply of Lab 9).
# The tag is the current commit, as in the pipeline; uncommitted changes would
# end up in an image whose tag names a commit without them, so commit first.
# A later make k8s-apply sets the images back to the tag in overlays/k3d.
PIPELINE_REGISTRY := k3d.local
pipeline-k3d:
	@test -n "$(SERVICE)" || { echo "SERVICE is required, e.g. make pipeline-k3d SERVICE=transfer" >&2; exit 1; }
	@test -z "$$(git status --porcelain -- .)" || { echo "uncommitted changes in studi-kasus/: commit first, the image tag is the commit" >&2; exit 1; }
	@v=$$(git rev-parse --short=12 HEAD) && \
	$(MAKE) -C $(SERVICE) test && \
	$(MAKE) -C $(SERVICE) image REGISTRY=$(PIPELINE_REGISTRY) IMAGE_OWNER=$(IMAGE_REPO) VERSION=$$v && \
	$(call k3d-load,$(PIPELINE_REGISTRY)/$(IMAGE_REPO)/$(SERVICE):$$v) && \
	$(MAKE) -C $(SERVICE) deploy REGISTRY=$(PIPELINE_REGISTRY) IMAGE_OWNER=$(IMAGE_REPO) VERSION=$$v NAMESPACE=$(K3D_NAMESPACE)

# The server overlay for one service, the same apply that the pipeline's
# first deploy runs (make apply in pipeline.mk): to bring a change in
# k8s/overlays/server (config.yaml, ingress.yaml) to the cluster. VERSION is
# the image to keep or to roll out, usually the commit already deployed
# (kubectl rollout history). Pods read ConfigMaps only at start: kubectl
# rollout restart deployment/<service> after a config change.
# Refuses while a placeholder is left: the instructor hands out the training
# server's addresses (~/lab10.txt on the server).
# Usage: make k8s-apply-server SERVICE=transfer VERSION=<sha> REGISTRY=...
#        IMAGE_OWNER=... NAMESPACE=...  (KUBECONFIG of the training server)
k8s-apply-server:
	@test -n "$(SERVICE)" || { echo "SERVICE is required, e.g. make k8s-apply-server SERVICE=transfer VERSION=<sha>" >&2; exit 1; }
	$(MAKE) -C $(SERVICE) apply
```
]

=== Langkah 5: _Workflow_ per service

Runner CI membaca _workflow_ dari direktori `.forgejo/workflows/` di _root_ repository, bukan di `studi-kasus/`. Format _file_-nya sama dengan format _workflow_ CI berbasis YAML yang umum: `on` untuk _trigger_, `jobs` untuk _job_, `steps` untuk urutan perintah.

Bagian-bagian _workflow_ `transfer`:

- `on.push.paths` membatasi _trigger_ pada perubahan di `studi-kasus/transfer/`, `studi-kasus/proto/` (kontrak gRPC yang di-_import_ `transfer`), `go.work`, `pipeline.mk`, dan _file_ _workflow_ itu sendiri.
- `concurrency` dengan `cancel-in-progress: false` membuat _workflow_ satu service berjalan satu per satu. _Push_ berikutnya menunggu _pipeline_ yang sedang berjalan selesai, bukan membatalkannya. Dua _deploy_ satu service yang berjalan bersamaan akan saling berebut Deployment yang sama. Padanannya di Jenkins adalah `disableConcurrentBuilds()`.
- `runs-on: host` menjalankan _job_ langsung di server tempat runner berjalan, tanpa _container_ _job_. Server tersebut sudah menyediakan `git`, `make`, `go`, `docker`, dan `kubectl`. Runner digunakan bersama oleh semua peserta tanpa pemisahan hak akses: _job_ berjalan sebagai pengguna runner, sehingga siapa pun yang bisa mengubah _workflow_ bisa menjalankan perintah apa saja di _host_ tersebut.
- `env` di tingkat _job_ mengisi variabel untuk `pipeline.mk`. `REGISTRY` dan `NAMESPACE` diambil dari _variable_ repository, `IMAGE_OWNER` diisi nama pemilik repository, dan `VERSION` diisi SHA _commit_ yang memicu _pipeline_. Satu _commit_ menghasilkan satu _image_, sehingga _tag_ tidak pernah tertimpa.
- _Step_ Checkout menggunakan `git` biasa dengan _token_ yang diterbitkan runner untuk _job_ ini (akses baca ke repository, berlaku selama _job_ berjalan). Karena isi _workspace_ runner _host_ bisa tersisa dari _job_ sebelumnya, `fetch`, `checkout -f`, dan `clean -ffdx` menyamakan isinya tepat dengan _commit_ ini.
- _Secret_ `REGISTRY_USER` dan `REGISTRY_PASSWORD` hanya tersedia di _step_ Push.
- _Step_ Deploy menulis _secret_ `KUBE_CONFIG` ke _file_ sementara yang dihapus ketika _step_ selesai (`trap ... EXIT`). Dengan `KUBECONFIG` yang menunjuk ke _file_ itu, `kubectl` tidak pernah menggunakan _kubeconfig_ milik pengguna runner. RBAC _kubeconfig_ tersebut harus mengizinkan pembuatan ConfigMap, Service, Deployment, dan Ingress di _namespace_ peserta, karena _deploy_ pertama membuat objek-objek itu.

Bila _variable_ atau _secret_ belum diisi, _step_ menerimanya sebagai _string_ kosong. `pipeline.mk` menghentikan _step_ tersebut dengan pesan `missing required variables: ...`, dan _step_ Deploy memeriksa `KUBE_CONFIG` sendiri.

Buat _file_ `.forgejo/workflows/transfer.yaml` di direktori _root_ repository:

#perintah[
```yaml
# Pipeline of the transfer service (Lab 10): test, build the image, push it to the
# git server's container registry, roll it out on the training server.
# One workflow per service, so a change to transfer builds and deploys transfer only.
#
# Only run: steps that call make targets (no marketplace actions): every step
# maps 1:1 to a stage of studi-kasus/transfer/Jenkinsfile, and the same commands
# run on a laptop.
#
# Verified end to end on the training server (git server 16.0.6, runner
# 13.2.0, k3s v1.36.5+k3s1): first deploy into an empty namespace, rolling
# update, two participants pushing at the same time.
#
# The runner is shared by all participants and trusts them all: a job runs on
# the runner host as the runner user, so anyone who can push a workflow change
# can run any command there.
#
# What the runner and the repository must provide:
#   runner label "host"   jobs run directly on the server (no job container),
#                         where git, make, go, docker and kubectl are installed
#   variable  REGISTRY    registry host (the git server's host name)
#   variable  NAMESPACE   the participant's namespace on the training server
#   secret    REGISTRY_USER, REGISTRY_PASSWORD   an account and token allowed
#                         to push packages
#   secret    KUBE_CONFIG kubeconfig limited to NAMESPACE (RBAC), allowed to
#                         create ConfigMaps, Services, Deployments and
#                         Ingresses there (the first deploy creates them)
# A missing variable or secret arrives as an empty string; the make targets
# stop on it with "missing required variables: ...".
name: transfer

on:
  push:
    branches: [main]
    # proto/, go.work and pipeline.mk are shared: a gRPC contract change
    # rebuilds both account and transfer.
    paths:
      - studi-kasus/transfer/**
      - studi-kasus/proto/**
      - studi-kasus/go.work
      - studi-kasus/pipeline.mk
      - .forgejo/workflows/transfer.yaml

# One run of this workflow at a time: a newer push waits until the running one
# has finished instead of cancelling it (cancel-in-progress is true by default
# for push). Two deploys of one service at once would race on the same
# Deployment. The Jenkinsfile does the same with disableConcurrentBuilds().
concurrency:
  group: pipeline-transfer
  cancel-in-progress: false

jobs:
  pipeline:
    runs-on: host
    env:
      REGISTRY: ${{ vars.REGISTRY }}
      # Packages in the registry belong to the repository owner.
      IMAGE_OWNER: ${{ github.repository_owner }}
      NAMESPACE: ${{ vars.NAMESPACE }}
      # One image per commit: the tag says exactly which code runs.
      VERSION: ${{ github.sha }}
    steps:
      # Checkout with plain git and the token the runner issues for this job
      # (read access to this repository, valid while the job runs). The
      # workspace of a host runner can survive between jobs: fetch + checkout
      # -f + clean make it exactly this commit either way.
      - name: Checkout
        env:
          SERVER_URL: ${{ github.server_url }}
          REPOSITORY: ${{ github.repository }}
          TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -eu
          auth=$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')
          git init -q .
          git -c http.extraHeader="Authorization: basic $auth" fetch -q --depth 1 "$SERVER_URL/$REPOSITORY.git" "$VERSION"
          git checkout -q -f FETCH_HEAD
          git clean -q -ffdx

      - name: Test
        run: make -C studi-kasus/transfer test

      - name: Build image
        run: make -C studi-kasus/transfer image

      - name: Push
        env:
          REGISTRY_USER: ${{ secrets.REGISTRY_USER }}
          REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
        run: make -C studi-kasus/transfer push

      # The kubeconfig secret goes to a file that exists only during this
      # step; kubectl never falls back to the runner user's own kubeconfig.
      # The first run in an empty namespace creates the service's objects from
      # k8s/overlays/server with this commit's image; later runs only change
      # the image (pipeline.mk, target deploy).
      - name: Deploy
        env:
          KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
        run: |
          set -eu
          test -n "$KUBE_CONFIG" || { echo "missing required secret: KUBE_CONFIG" >&2; exit 1; }
          KUBECONFIG=$(mktemp)
          trap 'rm -f "$KUBECONFIG"' EXIT
          printf '%s\n' "$KUBE_CONFIG" > "$KUBECONFIG"
          export KUBECONFIG
          make -C studi-kasus/transfer deploy
```
]

Salin _file_ tersebut menjadi `account.yaml` dan `notification.yaml`, lalu ganti setiap `transfer` dengan nama service. Ada satu perbedaan: `notification` tidak meng-_import_ kontrak gRPC, sehingga baris `studi-kasus/proto/**` dihapus dari `paths` di `notification.yaml`.

#perintah[
```bash
cd ..   # akar repository
sed 's/transfer/account/g' .forgejo/workflows/transfer.yaml > .forgejo/workflows/account.yaml
sed -e 's/transfer/notification/g' -e '/studi-kasus\/proto/d' \
  .forgejo/workflows/transfer.yaml > .forgejo/workflows/notification.yaml
```
]

Periksa hasilnya dengan `git diff --no-index`. Perintah `sed` juga mengganti kata `transfer` di dalam komentar, sehingga komentar tentang `proto/` di kedua _file_ baru perlu diperbaiki. Di `account.yaml`, baris kedua komentar menjadi:

#perintah[
```yaml
    # rebuilds both account and transfer.
```
]

Di `notification.yaml`, ganti kedua baris komentar di atas `paths:` dengan:

#perintah[
```yaml
    # No proto/: notification does not import the gRPC contract, it only reads
    # the events on Kafka. go.work and pipeline.mk are shared by all services.
```
]

// Verified 20 Okt on git server 16.0.6 + runner 13.2.0: secrets.GITHUB_TOKEN, vars.REGISTRY, vars.NAMESPACE and github.repository_owner resolve as written; the job token works as basic auth (user x-access-token) for a fetch by SHA; concurrency groups are per repository.

=== Langkah 6: `Jenkinsfile` untuk pemetaan ke Jenkins

Banyak organisasi menjalankan CI _on-premise_ dengan Bitbucket dan Jenkins. `Jenkinsfile` _declarative_ berikut menjalankan _target_ `make` yang sama dengan _workflow_ pada Langkah 5. Setiap service mendapat satu _job_ Jenkins bertipe _Multibranch Pipeline_ dengan _Script Path_ `studi-kasus/<service>/Jenkinsfile`. Tipe _job_ lain tidak bisa digunakan. Kondisi `when { branch 'main' }` membaca `BRANCH_NAME`, dan variabel ini hanya diisi oleh _job_ _Multibranch_; di _job_ _Pipeline_ biasa semua _stage_ akan dilewati.

_Stage_ `Test` diawali blok `script` yang menghentikan _build_ bila `GIT_COMMIT` kosong. `GIT_COMMIT` diisi oleh _checkout_ SCM bawaan _declarative pipeline_. Bila _checkout_ ini dimatikan, misalnya dengan `options { skipDefaultCheckout() }`, `VERSION = "${env.GIT_COMMIT}"` berisi _string_ `null`, dan pemeriksaan variabel kosong di `pipeline.mk` akan meloloskan _image_ dengan _tag_ `null`. Pemeriksaan ini diletakkan di dalam _stage_ `Test`, bukan di _stage_ tersendiri, agar daftar _stage_ tetap setara satu per satu dengan _step_ _workflow_.

Pemetaan antara kedua format:

#table(
  columns: (1fr, 1fr, 1.4fr),
  [_Workflow_], [Jenkins], [Keterangan],
  [_Step_ Checkout], [_Checkout_ SCM bawaan], [Jenkins melakukan _checkout_ sebelum _stage_ pertama],
  [_Step_ Test], [_Stage_ `Test`], [`make -C studi-kasus/<service> test`],
  [_Step_ Build image], [_Stage_ `Build Image`], [`make ... image`],
  [_Step_ Push], [_Stage_ `Push`], [`make ... push`],
  [_Step_ Deploy], [_Stage_ `Deploy`], [`make ... deploy`],
  [`github.sha`], [`env.GIT_COMMIT`], [Nilai `VERSION`],
  [_Variable_ `REGISTRY`, `NAMESPACE`], [_Environment variable_ folder atau global], [`IMAGE_OWNER` juga diisi di sini],
  [_Secret_ `REGISTRY_USER`, `REGISTRY_PASSWORD`], [_Credential_ `registry` jenis _username with password_], [Dibuka dengan `withCredentials` hanya di _stage_ `Push`],
  [_Secret_ `KUBE_CONFIG`], [_Credential_ `kubeconfig` jenis _secret file_], [`withCredentials` mengisi `KUBECONFIG` dengan _path_ _file_ sementara],
  [`concurrency`], [`disableConcurrentBuilds()`], [Satu _build_ per service dalam satu waktu],
  [`on.push.branches` dan `paths`], [`when { branch ...; changeset ... }`], [Lihat catatan di bawah],
  [_Re-run_ sebuah _run_], [_Build Now_], [`triggeredBy 'UserIdCause'`: semua _stage_ berjalan untuk _commit_ terakhir tanpa memeriksa _changeset_],
)

#note[
  *_Changeset_ pada _build_ pertama dan setelah _build_ gagal.* Kondisi `changeset` membandingkan _build_ saat ini dengan _build_ sebelumnya pada _branch_ yang sama, apa pun hasil _build_ sebelumnya. _Build_ pertama sebuah _branch_ tidak punya pembanding, sehingga _changeset_-nya kosong dan semua _stage_ dilewati. Hal yang sama terjadi pada _build_ ulang setelah _build_ yang gagal: _commit_ yang sudah tercatat di _build_ gagal tidak masuk lagi ke _changeset_ berikutnya. Karena itu kondisi `when` juga menerima `triggeredBy 'UserIdCause'`. _Build_ yang dijalankan manual dengan _Build Now_ selalu menjalankan semua _stage_ untuk _commit_ terakhir, sama seperti _re-run_ di runner lab. _Build_ yang dipicu _webhook_ atau _branch indexing_ tetap mengikuti _changeset_.
]

Buat _file_ `studi-kasus/transfer/Jenkinsfile`:

#perintah[
```groovy
// Declarative pipeline of the transfer service for Jenkins, the mapping of
// .forgejo/workflows/transfer.yaml: the same stages calling the same make
// targets. Job setup: a Multibranch Pipeline on this repository with Script
// Path studi-kasus/transfer/Jenkinsfile, one job per service. Multibranch
// only: "when { branch 'main' }" reads BRANCH_NAME, which only a
// Multibranch job sets; in a plain Pipeline job every stage would be skipped.
//
// Verified on Jenkins LTS 2.580.1 (Multibranch Pipeline, plain Git branch
// source, built-in node with git, make, go, docker and kubectl) deploying to
// k3d: path filter per service, first deploy into an empty namespace, rolling
// update, disableConcurrentBuilds(), a missing variable stopping make.
//
// What Jenkins must provide (no defaults here; make stops with "missing
// required variables: ..." when one is absent):
//   REGISTRY, IMAGE_OWNER, NAMESPACE   environment variables of the folder or
//                                      global properties, per environment
//   credentials "registry"             Username with password, push access
//   credentials "kubeconfig"           Secret file, kubeconfig limited to
//                                      NAMESPACE; the first deploy creates
//                                      the service's objects there
//   agent                              git, make, go, docker and kubectl
pipeline {
    agent any

    options {
        // Two builds of one service deploying at once would race on the
        // same Deployment.
        disableConcurrentBuilds()
        timeout(time: 20, unit: 'MINUTES')
    }

    environment {
        // One image per commit, as in the workflow (github.sha). GIT_COMMIT
        // is set by the SCM checkout; without it this becomes the string
        // "null", which the Test stage rejects.
        VERSION = "${env.GIT_COMMIT}"
    }

    stages {
        // The workflow's "on: push: branches/paths" filter. changeset
        // compares with the previous build of the branch, whatever its
        // result: the first build of a branch has no changeset, and a build
        // after a failed one sees only the commits pushed since. Both would
        // skip the stages; "Build Now" (UserIdCause) runs them for the
        // current commit, the counterpart of re-running a workflow run.
        stage('transfer') {
            when {
                allOf {
                    branch 'main'
                    anyOf {
                        triggeredBy 'UserIdCause'
                        changeset 'studi-kasus/transfer/**'
                        changeset 'studi-kasus/proto/**'
                        changeset 'studi-kasus/go.work'
                        changeset 'studi-kasus/pipeline.mk'
                    }
                }
            }
            stages {
                stage('Test') {
                    steps {
                        // Fail before anything is built: make's check for
                        // empty variables would let an image tagged "null"
                        // through.
                        script {
                            if (!env.GIT_COMMIT || env.GIT_COMMIT == 'null') {
                                error('GIT_COMMIT is empty: the job must check out this repository from SCM (Multibranch Pipeline)')
                            }
                        }
                        sh 'make -C studi-kasus/transfer test'
                    }
                }
                stage('Build Image') {
                    steps {
                        sh 'make -C studi-kasus/transfer image'
                    }
                }
                stage('Push') {
                    steps {
                        withCredentials([usernamePassword(credentialsId: 'registry',
                                usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
                            sh 'make -C studi-kasus/transfer push'
                        }
                    }
                }
                stage('Deploy') {
                    steps {
                        // The secret file exists only inside this block;
                        // KUBECONFIG points kubectl at it.
                        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
                            sh 'make -C studi-kasus/transfer deploy'
                        }
                    }
                }
            }
        }
    }
}
```
]

Buat `account/Jenkinsfile` dan `notification/Jenkinsfile` dengan cara yang sama seperti Langkah 5: ganti `transfer` dengan nama service, dan hapus baris `changeset 'studi-kasus/proto/**'` untuk `notification`.

#perintah[
```bash
sed 's/transfer/account/g' studi-kasus/transfer/Jenkinsfile > studi-kasus/account/Jenkinsfile
sed -e 's/transfer/notification/g' -e '/studi-kasus\/proto/d' \
  studi-kasus/transfer/Jenkinsfile > studi-kasus/notification/Jenkinsfile
```
]

Ketiga `Jenkinsfile` ini sudah dijalankan di Jenkins LTS 2.580.1: _job_ _Multibranch Pipeline_ dengan sumber Git, _environment variable_ global `REGISTRY`, `IMAGE_OWNER`, dan `NAMESPACE`, _credential_ `registry` dan `kubeconfig` (_ServiceAccount_ dengan RBAC satu _namespace_), lalu _deploy_ ke k3d. Hasil yang teramati:

- _commit_ yang mengubah `studi-kasus/transfer/` hanya menjalankan _stage_ di _job_ `transfer`; _job_ `account` dan `notification` ikut berjalan, tetapi semua _stage_-nya dilewati;
- _commit_ yang mengubah `studi-kasus/proto/` menjalankan `account` dan `transfer`, tetapi tidak menjalankan `notification`;
- _commit_ yang hanya mengubah dokumentasi melewati semua _stage_ di ketiga _job_;
- _deploy_ pertama membuat ConfigMap, Service, Deployment, dan Ingress dari _namespace_ kosong, dan _deploy_ berikutnya menambah satu revisi di `kubectl rollout history` dengan anotasi `<service> <SHA>`;
- _build_ kedua untuk service yang sama menunggu di antrean dengan pesan `Build #N is already in progress`;
- tanpa `REGISTRY`, _stage_ `Build Image` berhenti dengan `missing required variables: REGISTRY`.

Di kelas, _file_ ini digunakan sebagai bahan perbandingan; peserta tidak menjalankan Jenkins.

==== _Pipeline_ yang Sama di GitHub Actions

Repository materi ini juga menjalankan _pipeline_ yang sama di GitHub Actions, dan hasil setiap _run_ dapat dibuka publik di #link("https://github.com/artivisi/training-microservices-2026-01/actions")[`github.com/artivisi/training-microservices-2026-01/actions`]. _Workflow_ `.github/workflows/<service>.yaml` menjalankan _target_ `make` yang sama dengan runner git server dan Jenkins, lalu mengirim _image_ ke `ghcr.io`. _Runner_ GitHub tidak memiliki _cluster_, sehingga _step_ Deploy diganti _workflow_ `e2e-k3d.yaml`. _Workflow_ ini membuat k3d di _runner_, menjalankan Lab 9, menguji satu transfer lewat Ingress, lalu menjalankan `make pipeline-k3d SERVICE=transfer` sambil mengirim transfer terus-menerus. _Run_ dinyatakan gagal bila ada satu saja respons yang bukan 2xx selama _rolling update_.

#table(
  columns: (0.8fr, 1fr, 1fr, 1.2fr),
  [Tahap], [Runner git server], [Jenkins], [GitHub Actions],
  [_Checkout_], [`git fetch` dengan _token_ _job_], [_Checkout_ SCM bawaan], [`git fetch` dengan `GITHUB_TOKEN`],
  [_Tools_], [Terpasang di host runner], [Terpasang di _agent_], [_Step_ `Install tools`: `.github/install-tools.sh`, versi dan SHA-256 tetap],
  [Test], [`make ... test`], [`stage('Test')`], [`make ... test`],
  [Build image], [`make ... image`], [`stage('Build Image')`], [`make ... image`],
  [Push], [`make ... push` ke registry git server], [`stage('Push')`], [`make ... push` ke `ghcr.io`],
  [_Credential_ registry], [_Secret_ `REGISTRY_USER`, `REGISTRY_PASSWORD`], [_Credential_ `registry`], [`github.actor` dan `GITHUB_TOKEN` dengan `packages: write`],
  [Deploy], [`make ... deploy`], [`stage('Deploy')`], [_Workflow_ `e2e-k3d.yaml`: `make pipeline-k3d` ke k3d di _runner_],
  [Satu _run_ per service], [`concurrency`], [`disableConcurrentBuilds()`], [`concurrency`],
)

GitHub Actions hanya menambah satu _step_, yaitu `Install tools`. _Runner_ GitHub dimulai dari _image_ generik, sedangkan runner git server dan _agent_ Jenkins sudah dipasangi Go, Docker, dan kubectl.

=== Langkah 7: _Overlay_ server pelatihan

Sama seperti _manifest_ Lab 9, _overlay_ server sudah disediakan sehingga peserta tidak perlu menulisnya dari awal. Ambil dari _tag_ `lab-10`:

#perintah[
```bash
git checkout lab-10 -- studi-kasus/k8s/overlays/server studi-kasus/README.md
ls studi-kasus/k8s/overlays/server
```
]

#perintah[
```
config.yaml  ingress.yaml  kustomization.yaml  secrets.yaml
```
]

Perintah yang sama mengambil `studi-kasus/README.md` versi Lab 10, yang menambahkan bagian ringkasan Lab 10.

_Overlay_ `server` sengaja tidak berisi `namespace:` dan blok `images:`. _Namespace_ dan _tag image_ baru diketahui saat _pipeline_ berjalan (`NAMESPACE` dan `VERSION`), dan keduanya diisi oleh _target_ `apply` pada Langkah 1. Dengan demikian peserta tidak perlu memasang _overlay_ secara manual sebelum _pipeline_ pertama, dan tidak ada _tag_ fiktif di repository.

Perbedaan _overlay_ `server` dengan _overlay_ `k3d`:

#table(
  columns: (1fr, 1.5fr, 1.5fr),
  [Hal], [_Overlay_ `k3d`], [_Overlay_ `server`],
  [_Namespace_], [`bank`, dibuat oleh _overlay_ (`namespace.yaml`)], [Tidak ditulis di _overlay_; diisi `apply` dari `NAMESPACE`. _Namespace_ peserta dibuat instruktur bersama _kubeconfig_ dengan RBAC yang hanya berlaku di _namespace_ itu. Tidak ada objek Namespace karena peserta tidak boleh membuat _namespace_],
  [_Image_], [Di-_import_ ke k3d, tanpa registry. _Tag_ ditulis di `newTag`], [Tidak ditulis di _overlay_; diisi `apply` menjadi `<REGISTRY>/<IMAGE_OWNER>/<service>:<VERSION>`. Di-_pull_ dari _container registry_ git server dengan Secret `registry-credentials` (`imagePullSecrets`, ditambahkan ke setiap Deployment lewat _patch_)],
  [Secret], [Berisi nilai lokal untuk Docker Compose], [Dihapus dari hasil _render_ (`$patch: delete`). Instruktur membuat Secret `account`, `transfer`, `notification` berisi `DATABASE_URL` (dan `OAUTH_CLIENT_SECRET` untuk `transfer`), sehingga _credential_ tidak pernah masuk ke repository],
  [Kafka], [`host.k3d.internal:19093`, _topic_ `transfer-events`], [Kafka bersama, _topic_ dan _consumer group_ diberi awalan nama peserta],
  [OAuth2, OTLP], [Hydra dan otel-lgtm di Docker Compose laptop], [Server OAuth2 dan _collector_ bersama],
  [Ingress], [Semua _host_ di `localhost:28080`], [_Host_ per peserta, karena _ingress controller_ digunakan bersama],
)

Setiap nilai yang ditulis `replace-me` di `config.yaml` dan `ingress.yaml` adalah _placeholder_ untuk alamat atau nama yang dibagikan instruktur ketika server siap. Domain `.invalid` adalah _top-level domain_ yang dicadangkan. Bila ada _placeholder_ yang terlewat, nama tersebut tidak bisa di-_resolve_, sehingga tidak ada koneksi yang sampai ke _host_ sungguhan.

_Target_ `apply` memilih objek dengan `kubectl apply -l app.kubernetes.io/name=<service>`. Deployment, Service, dan Ingress dari Lab 9 sudah membawa label itu, tetapi ConfigMap dan Secret belum. Tambahkan blok `labels` ke `k8s/base/<service>/kustomization.yaml` ketiga service, sehingga _kustomize_ memasang label tersebut di setiap objek service. Untuk `transfer`:

#perintah[
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Every object of this service carries its name, also the ConfigMap and the
# Secret: the pipeline's first deploy (make deploy in Lab 10) applies only the
# objects of one service with kubectl apply -l app.kubernetes.io/name=transfer.
# Metadata labels only: selectors and pod labels are already in the manifests.
labels:
  - pairs:
      app.kubernetes.io/name: transfer
resources:
  - configmap.yaml
  - secret.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```
]

Untuk `account` dan `notification`, nilai labelnya adalah nama service masing-masing. Daftar `resources` kedua _file_ itu tidak berubah. Blok `labels` tanpa `includeSelectors` hanya mengubah `metadata.labels`; _selector_ Deployment dan Service tetap seperti Lab 9. Hasil _render_ `k8s/overlays/k3d` hanya bertambah label pada ConfigMap dan Secret, sehingga `make k8s-apply` tidak memicu _rollout_.

Selama masih ada _placeholder_, `make k8s-apply-server` berhenti tanpa memasang apa pun, bahkan sebelum menghubungi _cluster_:

#perintah[
```bash
cd studi-kasus
make k8s-apply-server SERVICE=transfer VERSION=abc REGISTRY=r IMAGE_OWNER=o NAMESPACE=n
```
]

_Output_-nya menampilkan baris-baris hasil _render_ yang masih berisi `replace-me`, diikuti:

#perintah[
```
../k8s/overlays/server still has replace-me placeholders (lines above)
```
]

_Path_ diawali `../` karena pemeriksaan ini dijalankan oleh _target_ `apply` dari direktori service. Tanpa `SERVICE`, perintah berhenti dengan `SERVICE is required, e.g. make k8s-apply-server SERVICE=transfer VERSION=<sha>`; tanpa variabel lain, berhenti dengan `missing required variables: ...`.

Hasil _render_ _overlay_ bisa diperiksa tanpa _cluster_ dengan `kubectl kustomize k8s/overlays/server`.

Nilai pengganti setiap `replace-me` dibagikan instruktur di server pelatihan (`~/lab10.txt`, Langkah 10). _Namespace_ dan registry tidak termasuk di dalamnya: keduanya sudah diisi sebagai _variable_ repository.

=== Langkah 8: Menjalankan _pipeline_ di laptop hingga _deploy_ ke k3d

Langkah ini menjalankan tahapan _pipeline_ yang sama dengan runner CI, tetapi di laptop: _test_, _image_ dengan _tag_ berupa SHA _commit_, _import_ ke k3d sebagai pengganti `push`, lalu _deploy_ dengan `kubectl set image` dan `rollout status`.

Siapkan infrastruktur, _cluster_, dan _manifest_ dari Lab 9. Perintah kedua menggunakan _cluster_ `bank` yang sudah ada, dan baru membuatnya bila belum ada:

#perintah[
```bash
make infra-up
k3d cluster get bank || make k3d-up
make images VERSION=1.0.0
make k3d-import VERSION=1.0.0
make k8s-apply
```
]

_Cluster_ yang dihentikan dengan `k3d cluster stop bank` dijalankan lagi dengan `k3d cluster start bank`. `make k8s-apply` di sini juga memasang label baru dari Langkah 7 ke ConfigMap dan Secret.

_Commit_ hasil Langkah 1 hingga 7 terlebih dahulu, karena `pipeline-k3d` berhenti dengan pesan error bila `studi-kasus/` masih berisi perubahan yang belum di-_commit_:

#perintah[
```bash
cd ..
git add .forgejo .gitignore studi-kasus
git commit -m "Lab 10: pipeline per service"
cd studi-kasus
```
]

Buat perubahan kecil yang terlihat di log `transfer`. Di `transfer/main.go`, ganti pesan log saat server HTTP mulai berjalan:

#perintah[
```go
		log.Info("transfer service started", "addr", cfg.HTTPAddr, "account_grpc", cfg.AccountGRPCAddr,
```
]

Baris aslinya berbunyi `log.Info("transfer service listening", ...` di dalam _goroutine_ yang memanggil `srv.ListenAndServe()`. _Commit_ perubahan itu, lalu jalankan _pipeline_:

#perintah[
```bash
git commit -am "transfer: change startup log message"
make pipeline-k3d SERVICE=transfer
```
]

Urutan yang terlihat di _output_: `go vet` dan `go test` untuk `transfer`, `docker build` dengan _tag_ `k3d.local/studi-kasus/transfer:<12 karakter SHA>`, `k3d image import`, lalu perintah `kubectl` dari _target_ `deploy`. Deployment `transfer` sudah ada dari `make k8s-apply`, sehingga `deploy` tidak memanggil `apply` dan langsung menjalankan `kubectl set image`, `kubectl annotate`, dan `kubectl rollout status`. Baris terakhirnya:

#perintah[
```
deployment "transfer" successfully rolled out
```
]

`k3d.local` hanya nama registry fiktif untuk _tag_ lokal. _Image_ tidak pernah dikirim ke registry; `k3d image import` menyalinnya langsung ke _containerd_ di dalam _cluster_. Karena Deployment menggunakan `imagePullPolicy: IfNotPresent`, _kubelet_ menjalankan salinan itu tanpa mem-_pull_ _image_ dari registry.

=== Langkah 9: Menelusuri versi yang berjalan dan mengamati _drift_

Lihat riwayat _rollout_:

#perintah[
```bash
kubectl -n bank rollout history deployment/transfer
```
]

#perintah[
```
deployment.apps/transfer
REVISION  CHANGE-CAUSE
1         <none>
2         transfer 3c9d1e0a7b42
```
]

SHA di atas hanya contoh; setiap laptop menghasilkan SHA yang berbeda. Nomor revisi bisa lebih banyak bila latihan _rolling update_ Lab 9 sudah dijalankan. Revisi terakhir mencatat nama service dan SHA _commit_ hasil `pipeline-k3d`. Bandingkan dengan `git log`:

#perintah[
```bash
git rev-parse --short=12 HEAD
kubectl -n bank get deploy transfer -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
]

#perintah[
```
3c9d1e0a7b42
k3d.local/studi-kasus/transfer:3c9d1e0a7b42
```
]

Sekarang jalankan ulang `make k8s-apply`, perintah Lab 9 yang memasang _manifest_ dari repository:

#perintah[
```bash
make k8s-apply
kubectl -n bank get deploy transfer -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
]

#perintah[
```
studi-kasus/transfer:1.0.0
```
]

_Image_ kembali ke _tag_ `1.0.0` yang tertulis di `k8s/overlays/k3d/kustomization.yaml`, dan hasil _pipeline_ hilang. Penyebabnya: _pipeline_ mengubah _cluster_ langsung dengan `kubectl set image`, sedangkan repository tetap menyebut `1.0.0`. Isi _cluster_ dan isi repository berbeda (_drift_), dan siapa pun yang meng-_apply_ ulang repository membatalkan _deploy_ terakhir tanpa sadar.

GitOps menghilangkan selisih tersebut dengan menjadikan repository satu-satunya jalan untuk mengubah _cluster_: _pipeline_ tidak memanggil `kubectl set image`, tetapi meng-_commit_ _tag_ baru ke _manifest_, lalu sebuah _agent_ di _cluster_ menyamakan isi _cluster_ dengan isi repository. Lab ini tidak memasang _agent_ GitOps. Cukup dipahami bahwa _drift_ yang baru saja terlihat itulah masalah yang diselesaikan GitOps.

#note[
  Setelah `make k8s-apply`, kolom `CHANGE-CAUSE` revisi terbaru tetap menampilkan `transfer <sha>` walaupun _image_-nya sudah `1.0.0`:

  #perintah[
  ```
  REVISION  CHANGE-CAUSE
  2         transfer 3c9a2d36c5aa
  3         transfer 3c9a2d36c5aa
  ```
  ]

  Anotasi `change-cause` ditulis oleh `make deploy`, bukan oleh _manifest_, sehingga `kubectl apply` tidak menghapusnya. Revisi 1 hilang dari daftar karena ReplicaSet `1.0.0` digunakan kembali dan menjadi revisi 3. Untuk mengetahui _image_ yang benar-benar berjalan, baca `.spec.template.spec.containers[0].image`, bukan anotasi.
]

Untuk mengulang latihan, ubah kode lagi, _commit_, lalu jalankan `make pipeline-k3d SERVICE=transfer` sekali lagi.

=== Langkah 10: _Pipeline_ di server pelatihan

Instruktur sudah menyiapkan hal berikut untuk setiap peserta:

- repository `<peserta>/training-microservices-2026-01` di git server, berisi semua _branch_ dan _tag_ repository publik, dengan _variable_ `REGISTRY` dan `NAMESPACE` serta _secret_ `REGISTRY_USER`, `REGISTRY_PASSWORD`, dan `KUBE_CONFIG`. _Kubeconfig_ ini hanya berlaku di _namespace_ peserta, dan RBAC-nya mengizinkan pembuatan ConfigMap, Service, Deployment, dan Ingress di sana;
- akun Linux di server pelatihan dengan nama yang sama dengan akun git server, `kubectl` yang sudah terhubung ke _namespace_ peserta, dan _file_ `~/lab10.txt` berisi semua nilai untuk langkah ini;
- _namespace_ peserta berisi Secret `registry-credentials` dan Secret `account`, `transfer`, `notification`;
- _topic_ Kafka `<peserta>.transfer-events` dan dua _client_ OAuth2: `<peserta>-transfer-service` (digunakan `transfer` untuk memanggil `account`) dan `<peserta>-channel-app` (digunakan peserta untuk memanggil REST `transfer`).

Langkah persiapan di git server:

+ Masuk ke git server lewat _browser_ dengan _password_ awal dari instruktur, lalu ganti _password_. Selama _password_ awal belum diganti, git server menolak `git clone` dan `git push` lewat HTTPS dengan pesan `remote: Update your password`.
+ Daftarkan _public key_ SSH di menu _Settings_ → _SSH / GPG Keys_. Kunci yang sama digunakan untuk git lewat SSH dan untuk masuk ke server pelatihan.
+ Masuk ke server pelatihan dan baca nilai milik sendiri:

#perintah[
```bash
ssh <peserta>@app.<domain>
cat ~/lab10.txt
kubectl get pods
```
]

`kubectl get pods` menjawab `No resources found in <peserta> namespace.` sebelum _pipeline_ pertama. _Namespace_ peserta lain tidak bisa dibaca: `kubectl -n <peserta-lain> get pods` berhenti dengan `Forbidden`.

Alur peserta:

+ _Clone_ repository dari git server, di laptop atau di server pelatihan. Repository itu sudah berisi _overlay_ `k8s/overlays/server`:
  #perintah[
  ```bash
  git clone git@<git server>:<peserta>/training-microservices-2026-01.git
  cd training-microservices-2026-01
  ```
  ]
+ Ganti setiap `replace-me` di `studi-kasus/k8s/overlays/server/config.yaml` dan `ingress.yaml` dengan nilai dari `~/lab10.txt`. _File_ tersebut juga memuat satu perintah `sed` (GNU sed, Linux) yang mengganti semuanya sekaligus. Periksa hasilnya dengan `kubectl kustomize studi-kasus/k8s/overlays/server | grep replace-me`, yang tidak boleh mencetak apa pun.
+ Tambahkan satu baris komentar di akhir `studi-kasus/pipeline.mk`, lalu _commit_ dan _push_ `main`. Perubahan yang hanya menyentuh `k8s/overlays/server` tidak memicu _workflow_ mana pun, karena _path_ itu tidak tercantum di `on.push.paths`. Perubahan `pipeline.mk` memicu ketiga _workflow_, sehingga _pipeline_ pertama membuat ketiga service. `transfer` membutuhkan `account` untuk setiap transfer.
  #perintah[
  ```bash
  echo '# first deploy to the training server' >> studi-kasus/pipeline.mk
  git commit -am "Fill server overlay"
  git push origin main
  ```
  ]
+ Buka halaman _Actions_ repository di git server (`https://<git server>/<peserta>/training-microservices-2026-01/actions`). Ketiga _workflow_ berjalan bersamaan; log setiap _step_ bisa dibuka dari halaman tersebut. Pada _pipeline_ pertama, Deployment belum ada, sehingga log _step_ Deploy menampilkan `deployment/transfer not in namespace <peserta>: first deploy, applying the overlay`, lalu `apply` membuat ConfigMap, Service, Deployment, dan Ingress dengan _image_ _commit_ tersebut. _Image_ ketiga service muncul di menu _Packages_ akun peserta.
+ Di server pelatihan, periksa hasilnya:
  #perintah[
  ```bash
  kubectl get deploy,pods,ingress
  kubectl rollout history deployment/transfer
  ```
  ]
+ Buat dua rekening lewat `kubectl port-forward`, ambil _token_ `channel-app`, lalu kirim transfer lewat Ingress. Port lokal untuk `port-forward` dan _client secret_ ada di `~/lab10.txt`. Server pelatihan digunakan bersama, sehingga setiap peserta mendapat nomor port sendiri.
+ Ubah pesan log di `studi-kasus/transfer/main.go` seperti Langkah 8, _commit_, lalu _push_. Hanya _workflow_ `transfer` yang berjalan. `kubectl rollout history deployment/transfer` kini menampilkan dua revisi, masing-masing dengan SHA _commit_-nya.

Pada uji coba server pelatihan, _pipeline_ pertama (ketiga service sekaligus, _cache_ Go dan Docker masih kosong) selesai dalam sekitar 3,5 menit. _Pipeline_ berikutnya untuk satu service selesai dalam sekitar 1 menit, termasuk _rolling update_. Selama _rolling update_ tersebut, 81 transfer yang dikirim terus-menerus lewat Ingress semuanya dijawab `201`. Runner menjalankan paling banyak empat _job_ sekaligus; _push_ berikutnya menunggu di antrean.

Hasil kerja sendiri dari laptop (_branch_ `lab-10-saya`) juga bisa dikirim ke repository ini. _Branch_ tersebut tidak berasal dari `main` repository git server, sehingga _push_ biasa ditolak sebagai _non-fast-forward_. Repository ini milik peserta sendiri, jadi `main` boleh ditimpa:

#perintah[
```bash
git remote add git-server git@<git server>:<peserta>/training-microservices-2026-01.git
git push --force git-server lab-10-saya:main
```
]

Setelah Deployment ada, _pipeline_ tidak lagi menyentuh ConfigMap dan Ingress. Perubahan `config.yaml` atau `ingress.yaml` dikirim ke _cluster_ dengan `make k8s-apply-server`, satu service per perintah, dengan `VERSION` berisi _commit_ yang sedang berjalan agar _image_ tidak berubah:

#perintah[
```bash
kubectl -n <namespace> rollout history deployment/transfer
make k8s-apply-server SERVICE=transfer VERSION=<sha> REGISTRY=<registry> IMAGE_OWNER=<pemilik> NAMESPACE=<namespace>
kubectl -n <namespace> rollout restart deployment/transfer
```
]

_Pod_ membaca ConfigMap hanya saat _startup_, sehingga `rollout restart` diperlukan agar nilai baru terbaca. Selisih antara repository dan _cluster_ ini juga termasuk _drift_ yang dihilangkan GitOps.

Di server pelatihan, sama seperti di k3d, Prometheus tidak mengambil _metric_ dari _pod_. Yang sampai ke _collector_ hanya _trace_ dan log.

=== Langkah 11: _Pipeline_ di server sendiri

Server pelatihan Langkah 10 hanya tersedia selama training. Alur yang sama bisa dijalankan di satu VPS milik sendiri. _Script_ `studi-kasus/server/setup.sh` memasang semua komponen yang di server pelatihan disiapkan instruktur, di satu mesin:

#table(
  columns: (1fr, 1.3fr, 1.3fr),
  [Komponen], [Server pelatihan], [Server sendiri],
  [Git server, registry, _Actions_], [Host terpisah, satu akun per peserta], [Forgejo di Docker, satu akun admin, git hanya lewat HTTPS],
  [TLS], [_Wildcard certificate_ dari instruktur], [Caddy di port 80/443 meminta _certificate_ Let's Encrypt untuk `git.`, `auth.`, dan `app.`],
  [Runner], [Satu runner untuk semua peserta, label `host`], [Satu runner di VPS yang sama, label `host`],
  [_Cluster_], [k3s, satu _namespace_ per peserta, _quota_ dan NetworkPolicy], [k3s, satu _namespace_. Traefik menerima _traffic_ dari Caddy di port 8080],
  [Infrastruktur lab], [_Namespace_ `infra`: PostgreSQL, Kafka, Hydra, otel-lgtm], [Sama, dengan _resource_ yang lebih kecil],
  [_Variable_ dan _secret_ repository], [Diisi instruktur], [Diisi sendiri dari nilai di `/root/lab10.txt`],
)

Alamat `infra` sama dengan server pelatihan, sehingga _workflow_, `pipeline.mk`, dan _overlay_ `k8s/overlays/server` digunakan tanpa perubahan. Yang berbeda hanya nilai pengganti `replace-me`.

Kebutuhan:

- VPS Ubuntu 24.04 x86_64 dengan 4 vCPU, RAM 8 GB, disk minimal 50 GB, IP publik, dan akses `root` lewat SSH. Biayanya dihitung per jam di kebanyakan penyedia _cloud_, jadi hapus VPS setelah latihan selesai.
- Satu domain dengan tiga _record_ A, yaitu `git.<domain>`, `auth.<domain>`, dan `app.<domain>`, yang mengarah ke IP VPS. Tanpa domain sendiri, daftarkan nama gratis di DuckDNS (`<nama>.duckdns.org`). Semua nama turunan seperti `git.<nama>.duckdns.org` otomatis mengarah ke IP yang sama, sehingga `<domain>` cukup diisi `<nama>.duckdns.org`.
- Port 22, 80, dan 443 terbuka dari internet. Let's Encrypt memeriksa kepemilikan nama lewat port 80.

#note[
  Layanan seperti sslip.io dan nip.io (`git.<ip>.sslip.io`) tidak membutuhkan pendaftaran, tetapi Let's Encrypt membatasi jumlah _certificate_ per domain terdaftar setiap minggu. Semua pengguna sslip.io berbagi batas yang sama, sehingga permintaan _certificate_ bisa ditolak. DuckDNS terdaftar di _Public Suffix List_, sehingga setiap nama DuckDNS mendapat batas sendiri.
]

Jalankan _script_ sebagai `root` dari _clone_ repository di VPS. `FORGE_USER` menjadi nama akun git server sekaligus nama _namespace_, awalan database, awalan _topic_ Kafka, dan awalan _client_ OAuth2, sehingga hanya boleh berisi huruf kecil, angka, dan tanda hubung:

#perintah[
```bash
ssh root@<ip-vps>
git clone https://github.com/artivisi/training-microservices-2026-01.git
cd training-microservices-2026-01
DOMAIN=<domain> FORGE_USER=<nama> FORGE_EMAIL=<email> ./studi-kasus/server/setup.sh
```
]

_Script_ berhenti dengan pesan error bila ada _variable_ yang kosong, bila nama DNS belum mengarah ke VPS, atau bila `https://git.<domain>` tidak bisa dibuka setelah Caddy berjalan. _Script_ boleh dijalankan ulang: yang sudah ada dibiarkan, dan _password_ yang sudah dibuat tetap disimpan di `/opt/lab10/secrets`. Pada uji coba di VPS 4 vCPU, _script_ selesai dalam sekitar 3,5 menit, lalu mencetak isi `/root/lab10.txt`.

Langkah persiapan di git server:

+ Masuk ke `https://git.<domain>` dengan _username_ dan _password_ dari `/root/lab10.txt`.
+ Buat repository baru bernama `training-microservices-2026-01` dari menu _New Repository_. Biarkan kosong: jangan centang pilihan yang membuat README atau `.gitignore`.
+ Isi _variable_ `REGISTRY` dan `NAMESPACE` di menu _Settings_ → _Actions_ → _Variables_ repository tersebut, lalu _secret_ `REGISTRY_USER`, `REGISTRY_PASSWORD`, dan `KUBE_CONFIG` di _Settings_ → _Actions_ → _Secrets_. Nilainya ada di `/root/lab10.txt`. Isi `KUBE_CONFIG` adalah seluruh isi _file_ `/opt/lab10/kubeconfig`.

Isi _variable_ dan _secret_ sebelum _push_ pertama, karena _push_ pertama langsung menjalankan _workflow_. _Variable_ yang kosong membuat `make` berhenti dengan `missing required variables`.

Alur selanjutnya sama dengan Langkah 10. Kerjakan langsung di _clone_ yang sudah ada di VPS:

#perintah[
```bash
git config --global user.name "<nama>"
git config --global user.email "<email>"
git remote add vps https://git.<domain>/<nama>/training-microservices-2026-01.git
git push vps main
# perintah sed dari /root/lab10.txt, lalu:
kubectl kustomize studi-kasus/k8s/overlays/server | grep replace-me
echo '# first deploy to my own server' >> studi-kasus/pipeline.mk
git commit -am "Fill server overlay"
git push vps main
```
]

`git push` menanyakan _username_ dan _password_ git server. `grep replace-me` tidak boleh mencetak apa pun.

_Push_ pertama hanya mengisi repository yang masih kosong dan tidak menjalankan _workflow_ apa pun. _Branch_ `main` belum ada sebelumnya, sehingga tidak ada _commit_ pembanding untuk filter `paths`. _Push_ kedua berisi perubahan `pipeline.mk`, sehingga ketiga _workflow_ berjalan, sama seperti _push_ pertama di Langkah 10.

Pantau _pipeline_ di `https://git.<domain>/<nama>/training-microservices-2026-01/actions`, lalu periksa hasilnya di VPS dengan `kubectl get deploy,pods,ingress`. `kubectl` milik `root` di VPS sudah diarahkan ke _namespace_ `<nama>`, dengan hak akses yang sama seperti `KUBE_CONFIG` _pipeline_. Untuk melihat _namespace_ `infra`, gunakan _kubeconfig_ admin: `KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n infra get pods`. Buat dua rekening dan kirim transfer dengan perintah di `/root/lab10.txt`. Transfer dikirim ke `https://app.<domain>/transfers`.

Setelah itu, ubah pesan log di `studi-kasus/transfer/main.go`, _commit_, lalu `git push vps main`. Hanya _workflow_ `transfer` yang berjalan, dan `kubectl rollout history deployment/transfer` menampilkan dua revisi dengan SHA _commit_ masing-masing.

Pada uji coba di VPS 4 vCPU, _pipeline_ pertama selesai dalam sekitar 6,5 menit. Runner menjalankan dua _job_ sekaligus, sehingga `transfer` menunggu `account` dan `notification` selesai, dan _cache_ Go serta Docker masih kosong. _Pipeline_ `transfer` berikutnya selesai dalam sekitar 1,5 menit, termasuk _rolling update_. Seluruh sistem menggunakan sekitar 2,5 GB RAM.

Setelah latihan selesai, hapus VPS dari konsol penyedia _cloud_. Data git server, registry, dan _cluster_ ikut terhapus.

#note[
  Setiap _certificate_ Let's Encrypt tercatat di _Certificate Transparency log_ yang terbuka untuk umum. Beberapa menit setelah _certificate_ terbit, _scanner_ otomatis mulai mencoba alamat seperti `/.env` dan `/.git/config` di ketiga nama tersebut. Jangan menyimpan data asli di server latihan ini, dan jangan membuka port lain selain 22, 80, dan 443 bila penyedia _cloud_ menyediakan _firewall_.
]

== Verifikasi

Jalankan ulang `make pipeline-k3d SERVICE=transfer` setelah Langkah 9, karena `make k8s-apply` di Langkah 9 mengembalikan _image_ ke `1.0.0`.

#table(
  columns: (1.3fr, 1.4fr),
  [Perintah], [Hasil yang Diharapkan],
  [`make -C transfer image`], [Berhenti dengan `missing required variables: REGISTRY IMAGE_OWNER VERSION`],
  [`make -C transfer push REGISTRY=r IMAGE_OWNER=o VERSION=v`], [Berhenti dengan `missing required variables: REGISTRY_USER REGISTRY_PASSWORD`],
  [`make pipeline-k3d`], [Berhenti dengan `SERVICE is required, e.g. make pipeline-k3d SERVICE=transfer`],
  [`make pipeline-k3d SERVICE=transfer` dengan perubahan yang belum di-_commit_], [Berhenti dengan `uncommitted changes in studi-kasus/: commit first, the image tag is the commit`],
  [`make pipeline-k3d SERVICE=transfer` setelah _commit_], [Berakhir dengan `deployment "transfer" successfully rolled out`],
  [`kubectl -n bank rollout history deployment/transfer`], [Revisi terakhir berisi `transfer <12 karakter SHA>`],
  [`kubectl -n bank logs deployment/transfer`], [Ada baris JSON dengan `"msg":"transfer service started"`],
  [`make -C transfer deploy REGISTRY=r IMAGE_OWNER=o VERSION=v`], [Berhenti dengan `missing required variables: NAMESPACE`],
  [`make k8s-apply-server SERVICE=transfer VERSION=abc REGISTRY=r IMAGE_OWNER=o NAMESPACE=n`], [Menampilkan baris `replace-me`, lalu berhenti dengan `../k8s/overlays/server still has replace-me placeholders (lines above)`],
  [`kubectl -n bank get configmap,secret -l app.kubernetes.io/name=transfer -o name`], [`configmap/transfer` dan `secret/transfer`: label dari Langkah 7 sudah terpasang],
)

Periksa juga bahwa ketiga _workflow_ dan ketiga `Jenkinsfile` hanya berbeda pada nama service dan baris `proto`:

#perintah[
```bash
cd ..
git diff --no-index .forgejo/workflows/transfer.yaml .forgejo/workflows/notification.yaml
git diff --no-index studi-kasus/transfer/Jenkinsfile studi-kasus/account/Jenkinsfile
```
]

== Masalah Umum

*`missing separator.  Stop.`* Baris _recipe_ di `pipeline.mk` atau `Makefile` diawali spasi. Ganti spasi di awal baris _recipe_ dengan satu karakter _Tab_.

*`uncommitted changes in studi-kasus/`.* `pipeline-k3d` hanya berjalan bila `studi-kasus/` tidak berisi perubahan yang belum di-_commit_. Jalankan `git status`, lalu _commit_ atau `git stash` perubahan yang tersisa. Direktori `bin/` hasil _build_ lokal sudah tercantum di `.gitignore`.

*`deployment/transfer not in namespace bank: first deploy, applying the overlay`, lalu `../k8s/overlays/server still has replace-me placeholders`, saat `pipeline-k3d`.* Deployment `transfer` belum ada di k3d, sehingga `deploy` mencoba memasang _overlay_ server, yang ditolak karena masih berisi _placeholder_. Di laptop, Deployment dibuat oleh `make k8s-apply` dari _overlay_ `k3d`. Jalankan `make k8s-apply`, lalu ulangi `make pipeline-k3d`.

*`The connection to the server ... was refused` saat `make -n -C <service> deploy`.* Opsi `-n` tetap menjalankan baris _recipe_ yang berisi `$(MAKE)`, termasuk `kubectl get deployment` di awal `deploy` (Langkah 2). Baca urutan perintahnya langsung di `pipeline.mk`.

*`rollout status` berhenti setelah 180 detik.* _Pod_ baru tidak lolos _readiness probe_. Periksa `kubectl -n bank get pods` dan `kubectl -n bank logs <pod baru>`. Penyebab yang sering muncul: infrastruktur Docker Compose belum berjalan (`make infra-up`), atau kode baru gagal saat _startup_. _Pod_ lama tetap melayani; kembalikan dengan `kubectl -n bank rollout undo deployment/transfer` bila perlu. `rollout undo` bisa mencetak peringatan tentang anotasi `last-applied-configuration`; peringatan ini tidak berbahaya dan bukan error.

*`ErrImageNeverPull` atau `ErrImagePull` untuk _tag_ `k3d.local/...`.* _Image_ tidak ada di _node_ k3d, sehingga kubelet mencoba mengambilnya dari jaringan. `k3d-load` sudah memeriksa setiap _image_ setelah _import_ dan mengulang _import_ satu kali, sehingga kondisi ini biasanya berarti _import_ diarahkan ke _cluster_ lain. Pastikan _cluster_ bernama `bank` (`k3d cluster list`), lalu jalankan ulang `make pipeline-k3d`.

*Hasil _pipeline_ hilang.* `make k8s-apply` dijalankan setelah `pipeline-k3d` dan mengembalikan _image_ ke `1.0.0`. Ini perilaku yang diharapkan (Langkah 9).

*_Build_ Jenkins pertama melewati semua _stage_.* _Changeset_ kosong pada _build_ pertama sebuah _branch_ (lihat catatan di Langkah 6). Jalankan _Build Now_ pada _branch_ `main`. Bila semua _build_ melewati semua _stage_, termasuk _Build Now_, periksa tipe _job_: hanya _Multibranch Pipeline_ yang mengisi `BRANCH_NAME` untuk kondisi `branch 'main'`.

*_Build_ Jenkins setelah _build_ yang gagal melewati semua _stage_.* _Changeset_ dibandingkan dengan _build_ sebelumnya, termasuk _build_ yang gagal, sehingga _build_ berikutnya tanpa _commit_ baru di direktori service tidak menjalankan apa pun. Perbaiki penyebabnya, lalu jalankan _Build Now_ atau _push_ _commit_ perbaikan.

*_Build_ Jenkins berhenti dengan `GIT_COMMIT is empty`.* _Checkout_ SCM bawaan _declarative pipeline_ dimatikan, misalnya dengan `options { skipDefaultCheckout() }`, sehingga `VERSION` tidak berisi SHA _commit_. Hapus opsi tersebut.

*`setup.sh` berhenti dengan `https://git.<domain> unreachable`.* Caddy belum mendapat _certificate_ dari Let's Encrypt. Periksa bahwa ketiga nama mengarah ke IP VPS (`getent hosts git.<domain>`) dan port 80/443 terbuka, lalu baca alasannya di `docker compose -f /opt/lab10/forge/compose.yaml logs caddy`. Setelah penyebabnya diperbaiki, jalankan ulang `setup.sh`.

*_Run_ di server sendiri tertahan dengan status _Waiting_.* Tidak ada runner berlabel `host` yang aktif. Periksa `systemctl status forgejo-runner` dan `journalctl -u forgejo-runner` di VPS. Runner menjalankan dua _job_ sekaligus, sehingga _run_ ketiga memang menunggu sampai salah satu _job_ selesai.

*Tidak ada _workflow_ yang berjalan setelah _push_ ke repository server sendiri.* _Push_ yang membuat _branch_ `main` di repository kosong tidak menjalankan _workflow_ (Langkah 11). _Push_ _commit_ berikutnya yang mengubah _file_ di `on.push.paths`.

== Eksplorasi Mandiri

+ Ubah _file_ di `studi-kasus/proto/`, lalu tentukan _workflow_ mana yang akan terpicu dengan membaca `on.push.paths` ketiga _file_. Jalankan `make pipeline-k3d` untuk setiap service yang terpicu.
+ Buat _commit_ yang membuat `transfer` gagal saat _startup_ (misalnya mengganti nama _environment variable_ yang wajib di `config.go`), lalu jalankan `make pipeline-k3d SERVICE=transfer`. Amati bahwa `rollout status` gagal, _pod_ lama tetap melayani transfer di `http://localhost:28080/transfers`, dan `kubectl rollout undo` mengembalikan revisi sebelumnya.
+ Coba alur GitOps secara manual: ubah `newTag` `transfer` di `k8s/overlays/k3d/kustomization.yaml` ke _tag_ hasil `pipeline-k3d`, _commit_, lalu `make k8s-apply`. Bandingkan hasilnya dengan Langkah 9: kali ini `make k8s-apply` tidak membatalkan _deploy_.
+ Tambahkan _stage_ `Approve` berisi _step_ `input` sebelum _stage_ `Deploy` di `Jenkinsfile`, sehingga _deploy_ menunggu persetujuan manual. Rancang padanannya di _workflow_, misalnya dengan memindahkan _step_ Deploy ke _workflow_ terpisah yang dipicu manual.

== Checkpoint


Kondisi kode di akhir lab ini tersimpan di _tag_ `lab-10`. Setelah `git checkout lab-10 -- studi-kasus .forgejo .github .gitignore` di awal bab, kode di _branch_ kerja sudah sama dengan _tag_ tersebut. Peserta yang mengetik ulang kode sendiri membandingkan hasilnya dari folder repositori:

#perintah[```bash
git diff lab-10 -- studi-kasus .forgejo .github .gitignore
```]

Hasil ketikan sendiri wajar berbeda dari _tag_ `lab-10` pada perubahan pesan log di `transfer/main.go` dari Langkah 8, karena perubahan itu tidak termasuk di _tag_. Komentar di `account.yaml` dan `notification.yaml` yang ditulis ulang dengan kata-kata sendiri juga wajar berbeda.
