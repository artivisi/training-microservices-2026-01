#import "../_template/panduan.typ": note, perintah

= Lab 3: _Timeout_, _Retry_, dan _Circuit Breaker_ dengan failsafe-go

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

- mensimulasikan `account` _service_ yang lambat atau sering gagal dengan _fault injector_;
- memasang _timeout_ per percobaan, _retry_ dengan _backoff_ (jeda antarpercobaan yang makin panjang), dan _circuit breaker_ pada HTTP _client_ menggunakan failsafe-go;
- menentukan jenis kegagalan yang aman untuk di-_retry_ dan jenis kegagalan yang harus dihitung oleh _circuit breaker_;
- membaca perubahan status _circuit breaker_ (_closed_, _open_, _half-open_) dari _log_ dan dari _endpoint_ `GET /debug/circuit-breaker`;
- menguji ketiga _policy_ tersebut dengan `net/http/httptest` tanpa menjalankan `account` _service_.

== Gambaran

Pada akhir Lab 2, `transfer` _service_ memanggil `account` _service_ dengan `http.Client` tanpa _timeout_. Kode tersebut mengandung dua masalah yang baru terlihat ketika `account` bermasalah:

- Bila `account` lambat, setiap transfer ikut menunggu tanpa batas hingga `account` menjawab. _Goroutine_ dan koneksi di `transfer` menumpuk, sehingga `transfer` ikut lambat walaupun database milik `transfer` sehat.
- Bila `account` mati atau kewalahan, setiap transfer tetap mengirim _request_ ke `account`. Setiap _request_ tersebut gagal, dan beban tambahan tersebut membuat `account` makin lama kembali aktif.

Lab ini membungkus HTTP _client_ di paket `transfer/internal/accountclient` dengan tiga _policy_ dari _library_ failsafe-go.

#table(
  columns: (auto, 1fr, 1.3fr),
  [_Policy_], [Pengaturan], [Alasan],
  [_Timeout_], [2 detik untuk setiap percobaan], [Membatasi lama transfer menunggu `account`. Batas ini berlaku per percobaan, sehingga setiap _retry_ mendapat jatah waktu sendiri.],
  [_Retry_], [Maksimal 3 kali, _backoff_ 100 ms hingga 1 detik dengan _jitter_], [Hanya untuk kegagalan yang pasti belum diproses `account`: koneksi gagal dibuka dan HTTP 503. _Timeout_ tidak pernah di-_retry_.],
  [_Circuit breaker_], [Beralih ke _open_ setelah 5 gagal dari 10 panggilan terakhir, menunggu 10 detik, lalu memerlukan 3 panggilan uji yang berhasil], [Menghentikan panggilan ke `account` yang sedang bermasalah. Selama _open_, transfer langsung ditolak (_fail fast_) tanpa _request_ ke `account`.],
)

Ketiga _policy_ dipasang sebagai `http.RoundTripper`, yaitu komponen di dalam `http.Client` yang benar-benar mengirim _request_. Kode pemanggil (`Debit` dan `Credit`) tidak berubah: kode tersebut tetap memanggil `c.http.Do(req)`, dan _round tripper_ menjalankan ketiga _policy_ di setiap panggilan.

```
POST /transfers
      |
      v
transfer service
  accountclient.Client.Debit / Credit
    http.Client
      failsafehttp RoundTripper
        retry               (paling luar: mengulang seluruh percobaan)
          circuit breaker   (mencatat hasil setiap percobaan)
            timeout 2 dtk   (membatasi setiap percobaan)
              http.DefaultTransport ---------> account service :28081
                                                 fault injector (lab ini)
                                                   /accounts...
```

Urutan ketiga _policy_ menentukan perilaku _round tripper_. _Retry_ berada paling luar sehingga setiap percobaan ulang melewati _circuit breaker_ dan _timeout_ lagi. _Timeout_ berada paling dalam sehingga batas 2 detik berlaku untuk setiap percobaan, dan _circuit breaker_ ikut mencatat _timeout_ sebagai kegagalan.

Setelah lab ini, `POST /transfers` menjawab dengan kode HTTP berikut.

#table(
  columns: (auto, 1fr, 1fr),
  [Kode], [Status Transfer], [Penyebab],
  [`201`], [`COMPLETED`], [_Debit_ dan _credit_ berhasil.],
  [`422`], [`FAILED`], [_Debit_ ditolak `account`: rekening sumber tidak ditemukan atau saldo tidak cukup. Belum ada saldo yang berubah.],
  [`503`], [`FAILED`], [_Circuit breaker_ berstatus _open_ saat _debit_ akan dikirim. Transfer ditolak tanpa panggilan ke `account`, belum ada saldo yang berubah, dan _request_ aman diulang.],
  [`502`], [`FAILED`], [Panggilan _debit_ sudah dilakukan dan gagal: _timeout_, _retry_ habis, atau HTTP 500.],
  [`502`], [`FAILED`], [_Debit_ berhasil, lalu _credit_ gagal karena sebab apa pun: rekening tujuan tidak ditemukan, _circuit breaker_ yang baru beralih ke _open_, atau kegagalan lain. Saldo sumber sudah berkurang dan perlu dikembalikan manual, sehingga _request_ tidak boleh diulang.],
)

Pembagian kode 503 dan 502 di atas menjadi pegangan bagi aplikasi pemanggil. Kode 503 hanya digunakan bila belum ada saldo yang berubah, sehingga pemanggil boleh mengirim ulang _request_ yang sama nanti. Setelah _debit_ berhasil, setiap kegagalan _credit_ dijawab 502, walaupun penyebabnya _circuit breaker_ atau rekening tujuan yang tidak ada. Bila kegagalan tersebut dijawab 503 atau 422, pemanggil dapat mengira transfer aman diulang, dan pengulangan tersebut memotong saldo sumber untuk kedua kalinya.

#note[
  *Pengaturan _policy_ ditulis di kode.* Angka _timeout_, _retry_, dan _circuit breaker_ tidak dibaca dari _environment variable_. Angka tersebut merupakan bagian dari desain, sehingga setiap perubahannya perlu melewati _review_ dan _unit test_ seperti perubahan kode lainnya. _Unit test_ menggunakan angka yang lebih kecil agar selesai dalam hitungan milidetik.
]

== Titik Awal

Lab ini dimulai dari _checkpoint_ `lab-02`. Ambil kode Lab 3 dari _tag_ `lab-03`, lalu tampilkan perubahannya terhadap Lab 2 (lihat bagian Cara Mengerjakan Lab di Lab 1). Jalankan dari folder repositori:

#perintah[```bash
git checkout -b lab-03-saya lab-02
git checkout lab-03 -- studi-kasus
git diff --staged lab-02 -- studi-kasus
cd studi-kasus
```]

Lab ini dimulai dari database kosong, agar rekening uji dibuat dengan saldo yang diharapkan di bagian Verifikasi. Rekening dari Lab 2 sudah berkurang saldonya, dan `account` menjawab `409` bila rekening yang sama dibuat lagi. Hapus data lab, jalankan infrastruktur, lalu jalankan _unit test_:

#perintah[```bash
make infra-reset
make infra-up
make test
```]

Seluruh perintah di lab ini dijalankan dari folder `studi-kasus`, kecuali disebutkan lain.

== Langkah

=== Langkah 1: _Fault Injector_ pada `account`

Perilaku _timeout_, _retry_, dan _circuit breaker_ hanya terlihat ketika `account` lambat atau gagal. Untuk itu `account` diberi _fault injector_, yaitu _middleware_ yang menambahkan jeda atau menjawab HTTP 503 sesuai konfigurasi. Selama `account` berjalan, konfigurasi tersebut dapat diubah melalui _endpoint_ `/admin/fault` tanpa _restart_.

_Fault injector_ hanya sarana latihan, sehingga kodenya tidak perlu diketik. Peserta yang mengerjakan Lab 2 sendiri mengambil paket `fault` (beserta _unit test_) dan `account/main.go` yang memasang paket tersebut dari _checkpoint_ `lab-02`:

#perintah[
```bash
git checkout lab-02 -- account/internal/fault account/main.go
```
]

Penjelasan isi kode tersebut ada di bawah ini.

Dua keputusan pada _fault injector_ berpengaruh pada hasil pengamatan di bagian Verifikasi:

- Jawaban 503 dikirim *sebelum* _request_ diproses. Saldo tidak berubah, sehingga 503 aman di-_retry_.
- Bila pemanggil membatalkan _request_ selama jeda berlangsung (misalnya karena _timeout_ di sisi `transfer`), _fault injector_ berhenti dan tidak meneruskan _request_ ke _handler_. Akibatnya _debit_ yang terkena _timeout_ tidak mengubah saldo. Langkah 6 membahas mengapa perilaku ini tidak boleh dijadikan dasar untuk me-_retry_ _timeout_.

Isi file `account/internal/fault/fault.go`:

```go
// Package fault simulates a slow or failing service for the resiliency labs.
// It is a training tool: the admin endpoints let anyone degrade the service.
package fault

import (
	"encoding/json"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"sync/atomic"
	"time"
)

type Config struct {
	// DelayMS is added before every request is processed.
	DelayMS int `json:"delay_ms"`
	// ErrorRate is the fraction of requests (0.0–1.0) answered with 503 without
	// being processed.
	ErrorRate float64 `json:"error_rate"`
}

type Injector struct {
	cfg atomic.Pointer[Config]
	log *slog.Logger
}

func NewInjector(log *slog.Logger) *Injector {
	i := &Injector{log: log}
	i.cfg.Store(&Config{})
	return i
}

// Wrap applies the current fault configuration to every request of next.
func (i *Injector) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cfg := i.cfg.Load()
		if cfg.DelayMS > 0 {
			select {
			case <-time.After(time.Duration(cfg.DelayMS) * time.Millisecond):
			case <-r.Context().Done(): // caller gave up; do not process the request
				return
			}
		}
		if cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"injected fault"}` + "\n"))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Register adds GET/PUT/DELETE /admin/fault to mux.
func (i *Injector) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /admin/fault", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, i.cfg.Load())
	})
	mux.HandleFunc("PUT /admin/fault", func(w http.ResponseWriter, r *http.Request) {
		var cfg Config
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		if err := dec.Decode(&cfg); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body: " + err.Error()})
			return
		}
		if cfg.DelayMS < 0 || cfg.ErrorRate < 0 || cfg.ErrorRate > 1 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "delay_ms must be >= 0, error_rate between 0 and 1"})
			return
		}
		i.cfg.Store(&cfg)
		i.log.Warn("fault injection changed", "delay_ms", cfg.DelayMS, "error_rate", cfg.ErrorRate)
		writeJSON(w, http.StatusOK, cfg)
	})
	mux.HandleFunc("DELETE /admin/fault", func(w http.ResponseWriter, _ *http.Request) {
		i.cfg.Store(&Config{})
		i.log.Warn("fault injection cleared")
		writeJSON(w, http.StatusOK, Config{})
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
```

Konfigurasi disimpan dalam `atomic.Pointer` karena _handler_ `PUT /admin/fault` dan _request_ ke `/accounts` berjalan di _goroutine_ berbeda secara bersamaan. Setiap _request_ membaca konfigurasi utuh sekali di awal, sehingga perubahan konfigurasi tidak pernah terbaca setengah jadi.

_Fault injector_ hanya dipasang pada `/accounts` dan seluruh _path_ di bawahnya. _Health check_ (`/healthz`, `/readyz`) dan `/admin/fault` tetap cepat, sehingga _fault_ dapat dimatikan lagi kapan pun. Pemasangannya ada di fungsi `run()` pada `account/main.go`, setelah `defer store.Close()`:

```go
	// Faults apply to the account API only; probes and the admin endpoints stay fast.
	faults := fault.NewInjector(log)
	api := account.NewHandler(store, log).Routes()
	mux := http.NewServeMux()
	mux.Handle("/accounts", faults.Wrap(api))
	mux.Handle("/accounts/", faults.Wrap(api))
	mux.Handle("/", api)
	faults.Register(mux)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
```

Pola `/accounts/` (diakhiri garis miring) pada `ServeMux` mencakup seluruh _path_ di bawahnya, termasuk `/accounts/{number}/debit` dan `/accounts/{number}/credit`. Pola `/` menangkap _path_ lain, yaitu _health check_, dan meneruskannya ke _handler_ asli tanpa _fault_.

=== Langkah 2: Target `make` untuk Mengatur _Fault_

Perintah `curl` lengkap rawan salah ketik bila harus diketik setiap kali _fault_ diubah. Karena itu `Makefile` di `studi-kasus` diberi beberapa target pembantu. Tambahkan dua variabel berikut di bawah baris `SERVICES := account transfer`, lalu perbarui baris `.PHONY`.

```make
# Fault injection on the account service (Lab 3). Faults apply to /accounts*
# only; probes and /admin stay fast.
ACCOUNT_URL := http://localhost:28081
TRANSFER_URL := http://localhost:28082

.PHONY: infra-up infra-down infra-reset test fault-slow fault-error fault-clear fault-status breaker
```

Tambahkan target berikut di akhir file. Baris perintah di dalam target `make` wajib diawali karakter _tab_.

```make
# 3000 ms is above the transfer client's 2 s per-attempt timeout: every call
# times out and counts as a breaker failure.
fault-slow:
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":3000,"error_rate":0}'

# Usage: make fault-error RATE=0.5 (fraction of requests answered 503).
fault-error:
	@test -n "$(RATE)" || { echo "RATE is required, e.g. make fault-error RATE=0.5" >&2; exit 1; }
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":0,"error_rate":$(RATE)}'

fault-clear:
	curl -sS -X DELETE $(ACCOUNT_URL)/admin/fault

fault-status:
	curl -sS $(ACCOUNT_URL)/admin/fault

breaker:
	curl -sS $(TRANSFER_URL)/debug/circuit-breaker
```

Target `fault-error` sengaja tidak memiliki nilai _default_ untuk `RATE`. Bila `RATE` tidak diisi, target tersebut berhenti dengan pesan error, sesuai prinsip konfigurasi di studi kasus ini: nilai yang wajib harus disebutkan secara eksplisit.

=== Langkah 3: Menambahkan Dependensi failsafe-go

failsafe-go menyediakan _policy_ _timeout_, _retry_, _circuit breaker_, dan beberapa _policy_ lain dengan API yang seragam. Paket `failsafehttp` di dalamnya membungkus _policy_ tersebut menjadi `http.RoundTripper`.

#perintah[
```bash
cd transfer
go get github.com/failsafe-go/failsafe-go@v0.9.8
go mod tidy
cd ..
```
]

Setelah perintah tersebut, `transfer/go.mod` memuat baris `github.com/failsafe-go/failsafe-go v0.9.8` di blok `require`.

=== Langkah 4: Error untuk _Circuit Breaker_ yang _Open_ dan _Credit_ yang Gagal

Paket `transfer` (domain) tidak boleh bergantung pada failsafe-go. Paket tersebut cukup mengenal dua kondisi baru:

- `account` sedang tidak tersedia, dan panggilan ditolak tanpa dikirim;
- _debit_ sudah diproses, tetapi _credit_ gagal, sehingga transfer tidak lagi aman diulang.

Tambahkan dua variabel berikut di blok `var` pada `transfer/internal/transfer/transfer.go`, tepat setelah `ErrInsufficientFunds`.

```go
	// The circuit breaker to the account service is open: the call was rejected
	// without being sent.
	ErrAccountUnavailable = errors.New("account service unavailable")
	// The debit was applied but the credit was not: the source account needs a
	// manual reversal. Whatever made the credit fail, the transfer is no longer
	// safe to retry.
	ErrCreditFailed = errors.New("credit failed after debit")
```

Paket `accountclient` menerjemahkan error milik failsafe-go menjadi `ErrAccountUnavailable` (Langkah 8). Dengan cara ini, _handler_ HTTP dapat memilih kode 503 tanpa mengetahui _library_ apa yang digunakan di bawahnya. `Service.Execute` (Langkah 9) membungkus setiap kegagalan _credit_ dengan `ErrCreditFailed`, apa pun penyebabnya.

=== Langkah 5: Pengaturan _Policy_

Seluruh angka _policy_ dikumpulkan dalam satu _struct_ agar _unit test_ dapat memberikan angka yang lebih kecil. Di `transfer/internal/accountclient/client.go`, ganti komentar paket dan blok _import_, lalu tambahkan `Settings` dan `ProductionSettings` sebelum `type Client`.

```go
// Package accountclient calls the account service REST API through failsafe-go
// policies: per-attempt timeout, retry with backoff, and a circuit breaker.
package accountclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/failsafe-go/failsafe-go"
	"github.com/failsafe-go/failsafe-go/circuitbreaker"
	"github.com/failsafe-go/failsafe-go/failsafehttp"
	"github.com/failsafe-go/failsafe-go/retrypolicy"
	"github.com/failsafe-go/failsafe-go/timeout"
	"github.com/shopspring/decimal"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

// Settings are the resiliency parameters. They live in code, not in environment
// variables: changing them is a design decision that goes through review and
// tests like any other code change. Tests pass shorter durations.
type Settings struct {
	// AttemptTimeout bounds one HTTP attempt, not the whole call with its retries.
	AttemptTimeout time.Duration
	MaxRetries     int
	BackoffMin     time.Duration
	BackoffMax     time.Duration
	// The breaker opens when BreakerFailures of the last BreakerWindow calls failed,
	// stays open for BreakerDelay, then lets BreakerSuccesses trial calls through
	// (half-open). All of them must succeed to close it; one failure reopens it.
	BreakerFailures  uint
	BreakerWindow    uint
	BreakerDelay     time.Duration
	BreakerSuccesses uint
}

// ProductionSettings is what the transfer service runs with.
var ProductionSettings = Settings{
	AttemptTimeout:   2 * time.Second,
	MaxRetries:       3,
	BackoffMin:       100 * time.Millisecond,
	BackoffMax:       time.Second,
	BreakerFailures:  5,
	BreakerWindow:    10,
	BreakerDelay:     10 * time.Second,
	BreakerSuccesses: 3,
}
```

Arti setiap angka:

- `AttemptTimeout` 2 detik: _debit_ atau _credit_ yang sehat selesai dalam hitungan milidetik. Percobaan yang melewati 2 detik dianggap gagal.
- `MaxRetries` 3: total paling banyak 4 percobaan (1 percobaan awal ditambah 3 _retry_).
- `BackoffMin` dan `BackoffMax`: jeda sebelum _retry_ dimulai dari 100 ms dan berlipat hingga paling lama 1 detik. Jeda yang makin panjang memberi waktu bagi `account` untuk kembali aktif.
- `BreakerFailures` dan `BreakerWindow`: _circuit breaker_ beralih ke _open_ bila 5 dari 10 panggilan terakhir gagal.
- `BreakerDelay` 10 detik: lama _circuit breaker_ bertahan di _open_ sebelum mengizinkan panggilan uji.
- `BreakerSuccesses` 3: jumlah panggilan uji yang harus berhasil di status _half-open_ sebelum kembali ke _closed_. Satu kegagalan di _half-open_ mengembalikan _circuit breaker_ ke _open_.

=== Langkah 6: Menentukan Kegagalan yang Di-_retry_ dan Dihitung

Langkah ini memuat inti keputusan desain di lab ini. Ada dua pertanyaan yang jawabannya berbeda.

*Pertanyaan pertama: kegagalan mana yang aman untuk di-_retry_?* _Debit_ belum _idempotent_. Bila _debit_ yang sama dikirim dua kali dan keduanya diproses, saldo terpotong dua kali. Karena itu _retry_ hanya boleh dilakukan bila _request_ dipastikan *belum diproses* oleh `account`:

- Koneksi gagal dibuka (_connection refused_, _host_ tidak dikenal). _Request_ belum terkirim sama sekali.
- HTTP 503. Di studi kasus ini, 503 berarti `account` menolak _request_ sebelum memprosesnya.

_Timeout_ tidak termasuk. Saat _timeout_ terjadi, `transfer` tidak tahu apakah `account` sudah memproses _debit_ dan hanya jawabannya yang terlambat. Di lab ini saldo memang tidak berubah ketika _timeout_ terjadi, tetapi hal tersebut hanya karena _fault injector_ berhenti saat pemanggil membatalkan _request_ (Langkah 1). Database yang lambat di sistem sungguhan dapat saja sudah melakukan _commit_ atas _debit_ tersebut. HTTP 500 juga tidak di-_retry_ dengan alasan yang sama: _request_ bisa saja sudah setengah diproses.

*Pertanyaan kedua: kegagalan mana yang dihitung oleh _circuit breaker_?* _Circuit breaker_ mengukur kesehatan `account` _service_. Error _transport_, _timeout_, dan HTTP 5xx menandakan `account` bermasalah. HTTP 4xx (rekening tidak ditemukan, saldo tidak cukup) justru menandakan `account` sehat dan menjawab secara normal, sehingga tidak boleh membuat _circuit breaker_ beralih ke _open_. Tanpa pembedaan tersebut, sepuluh nasabah dengan saldo kurang dapat menghentikan transfer seluruh nasabah lain.

Tambahkan dua fungsi berikut di `client.go`. Letak fungsi di dalam file tidak berpengaruh. Di _checkpoint_, kedua fungsi tersebut berada setelah fungsi `New` dari Langkah 7.

```go
// notProcessed reports whether the request provably never reached the account
// logic, the only case where a retry is safe today.
//
// A timeout is NOT retried: the account service may have applied the debit and
// only the answer was late. Debit is not idempotent yet, so a retry would debit
// twice. Lab 5 makes mutations idempotent by reference; only then are timeouts
// retried.
func notProcessed(resp *http.Response, err error) bool {
	if err != nil {
		// Dial failure (connection refused, unknown host): nothing was sent.
		var opErr *net.OpError
		return errors.As(err, &opErr) && opErr.Op == "dial"
	}
	// 503 means the service refused the request before processing it (the fault
	// injector answers 503 without touching the account).
	return resp.StatusCode == http.StatusServiceUnavailable
}

// countsAsFailure decides what the breaker counts against the account service:
// transport errors, timeouts and 5xx. A 4xx is a healthy service saying no
// (unknown account, insufficient funds) and must not open the breaker.
func countsAsFailure(resp *http.Response, err error) bool {
	return err != nil || resp.StatusCode >= 500
}
```

Kedua fungsi menerima pasangan `(resp, err)` yang sama dengan hasil `RoundTrip`. Bila `err` tidak `nil`, `resp` bernilai `nil`, sehingga `resp` hanya dibaca setelah `err` diperiksa. Go menyebut langkah membuka koneksi TCP ke alamat tujuan sebagai _dial_ (`net.Dial`), istilah yang berasal dari memutar nomor telepon. Error `*net.OpError` dengan operasi `dial` berarti koneksi belum terbentuk, sehingga _request_ belum terkirim ke `account`. Pada `notProcessed`, error _timeout_ dari failsafe-go bukan `*net.OpError` dengan operasi `dial`, sehingga fungsi tersebut mengembalikan `false` dan _timeout_ tidak di-_retry_.

=== Langkah 7: Menyusun _Policy_ di Fungsi `New`

Ganti `type Client` dan fungsi `New` milik Lab 2 dengan versi berikut. Fungsi `New` kini menerima `Settings` dan `*slog.Logger`.

```go
type Client struct {
	baseURL string
	http    *http.Client
	breaker circuitbreaker.CircuitBreaker[*http.Response]
}

func New(baseURL string, s Settings, log *slog.Logger) *Client {
	// One breaker for the whole account service: debit and credit share the same
	// failure domain, so a dead account service stops both.
	breaker := circuitbreaker.NewBuilder[*http.Response]().
		HandleIf(countsAsFailure).
		WithFailureThresholdRatio(s.BreakerFailures, s.BreakerWindow).
		WithDelay(s.BreakerDelay).
		WithSuccessThreshold(s.BreakerSuccesses).
		OnStateChanged(func(e circuitbreaker.StateChangedEvent) {
			log.Warn("circuit breaker state changed", "target", "account",
				"from", e.OldState.String(), "to", e.NewState.String())
		}).
		Build()

	retry := retrypolicy.NewBuilder[*http.Response]().
		HandleIf(notProcessed).
		// Explicit even though notProcessed already ignores ErrOpen: retrying against
		// an open breaker only burns backoff time and fails anyway.
		AbortOnErrors(circuitbreaker.ErrOpen).
		WithMaxRetries(s.MaxRetries).
		WithBackoff(s.BackoffMin, s.BackoffMax).
		// Jitter spreads the retries of many concurrent transfers so they do not all
		// hit a recovering account service in the same millisecond.
		WithJitterFactor(0.25).
		// Hand the last 503 back as a response instead of wrapping it in an
		// ExceededError, so the status mapping in mutate sees it.
		ReturnLastFailure().
		OnRetry(func(e failsafe.ExecutionEvent[*http.Response]) {
			// The response that triggered this retry is discarded; close it so its
			// connection goes back to the pool.
			cause := fmt.Sprint(e.LastError())
			if resp := e.LastResult(); resp != nil {
				cause = resp.Status
				_, _ = io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}
			log.Warn("retrying account call", "next_attempt", e.Attempts(), "cause", cause)
		}).
		Build()

	// Order matters: retry wraps the breaker, which wraps the timeout. Every attempt
	// gets its own time budget, and every attempt, timeouts included, is counted by
	// the breaker.
	rt := failsafehttp.NewRoundTripper(nil, retry, breaker, timeout.New[*http.Response](s.AttemptTimeout))
	return &Client{baseURL: baseURL, http: &http.Client{Transport: rt}, breaker: breaker}
}
```

Beberapa hal yang perlu diperhatikan dari kode di atas:

- *Satu _circuit breaker_ untuk `account`.* _Debit_ dan _credit_ menuju _service_ yang sama. Bila `account` mati, keduanya sama-sama gagal, sehingga keduanya berbagi satu _circuit breaker_.
- *Urutan argumen `NewRoundTripper`.* _Policy_ disusun dari luar ke dalam sesuai urutan argumen, yaitu `retry`, lalu `breaker`, lalu _timeout_. Argumen pertama `nil` berarti _round tripper_ di bagian terdalam adalah `http.DefaultTransport`.
- *`AbortOnErrors(circuitbreaker.ErrOpen)`.* Bila _circuit breaker_ beralih ke _open_ di tengah rangkaian _retry_, _retry_ berikutnya langsung dihentikan. Tidak ada gunanya menunggu _backoff_ bila percobaan berikutnya pasti ditolak _circuit breaker_.
- *_Jitter_.* Faktor 0,25 mengacak jeda _backoff_ hingga 25%. Bila seratus transfer gagal bersamaan, _retry_ dari seratus transfer tersebut tidak tiba di `account` pada milidetik yang sama.
- *`ReturnLastFailure()`.* Bila _retry_ habis, failsafe-go mengembalikan _response_ 503 terakhir apa adanya. Dengan begitu fungsi `mutate` tetap membaca kode status seperti biasa.
- *`OnRetry` menutup _body_.* Kode lain tidak membaca lagi _response_ 503 yang memicu _retry_. _Body_ tersebut harus dibaca habis dan ditutup agar koneksinya kembali ke _connection pool_.
- *_Log_ di setiap perubahan status.* `OnStateChanged` menulis _log_ `circuit breaker state changed` dengan atribut `from` dan `to`. _Log_ inilah yang diamati di bagian Verifikasi.

=== Langkah 8: Memetakan Error dan Menampilkan Status _Circuit Breaker_

Ketika _circuit breaker_ berstatus _open_, `c.http.Do(req)` mengembalikan error yang membungkus `circuitbreaker.ErrOpen`. Di fungsi `mutate`, sisipkan pemeriksaan berikut tepat setelah baris `resp, err := c.http.Do(req)` dan sebelum pemeriksaan `if err != nil` yang sudah ada.

```go
	resp, err := c.http.Do(req)
	if errors.Is(err, circuitbreaker.ErrOpen) {
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountUnavailable)
	}
	if err != nil {
		return fmt.Errorf("%s %s: %w", kind, number, err)
	}
```

Di fungsi yang sama, tambahkan komentar di atas `http.NewRequestWithContext`. _Body_ dibuat dengan `bytes.NewReader` agar failsafe-go dapat mengirim ulang _body_ yang sama di setiap _retry_.

```go
	// bytes.Reader: failsafehttp replays the body on every retry attempt.
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
```

Tambahkan dua _method_ berikut setelah `countsAsFailure`. `BreakerState` digunakan oleh _unit test_, sedangkan `ServeCircuitBreaker` menjadi _handler_ `GET /debug/circuit-breaker`.

```go
// BreakerState is "closed", "open" or "half-open".
func (c *Client) BreakerState() string { return c.breaker.State().String() }

// ServeCircuitBreaker answers GET /debug/circuit-breaker on the transfer service.
func (c *Client) ServeCircuitBreaker(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"account": c.BreakerState()})
}
```

=== Langkah 9: Kode HTTP 503 dan 502, serta Pendaftaran _Endpoint_

Perubahan pertama ada di `Service.Execute` pada `transfer/internal/transfer/service.go`. Kegagalan _credit_ kini dibungkus `ErrCreditFailed` agar _handler_ dapat membedakannya dari kegagalan _debit_. Ubah fungsi `fail` sehingga menerima satu error yang sudah memuat nama langkahnya, lalu sesuaikan kedua pemanggilnya di `Execute`.

```go
	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
		return s.fail(ctx, t, fmt.Errorf("debit failed: %w", err))
	}
	if err := s.accounts.Credit(ctx, t.ToAccount, t.Amount, t.ID); err != nil {
		s.log.Error("credit failed after debit, source account needs manual reversal",
			"transfer_id", t.ID, "from_account", t.FromAccount, "amount", t.Amount, "error", err)
		return s.fail(ctx, t, fmt.Errorf("%w: %w", ErrCreditFailed, err))
	}
```

```go
func (s *Service) fail(ctx context.Context, t Transfer, cause error) (Transfer, error) {
	reason := cause.Error()
```

Format `"%w: %w"` membungkus dua error sekaligus. `errors.Is(err, ErrCreditFailed)` bernilai `true`, dan `errors.Is` terhadap penyebab aslinya, misalnya `ErrAccountNotFound`, juga tetap `true`. Teks `failure_reason` yang disimpan tidak berubah dari Lab 2, misalnya `debit failed: ...` atau `credit failed after debit: ...`.

Di `transfer/internal/transfer/http.go`, fungsi `create`, tambahkan dua _case_ baru. _Case_ `ErrCreditFailed` diletakkan *sebelum* _case_ penolakan bisnis, sedangkan _case_ `ErrAccountUnavailable` diletakkan di antara penolakan bisnis dan `default`.

```go
	case errors.Is(err, ErrCreditFailed):
		// Checked first: the debit was applied, so this must not look retryable
		// (503) or like a plain business rejection (422). A retried POST would
		// debit again. The service already logged it for manual reversal.
		writeJSON(w, http.StatusBadGateway, t)
	case errors.Is(err, ErrAccountNotFound), errors.Is(err, ErrInsufficientFunds):
		writeJSON(w, http.StatusUnprocessableEntity, t)
	case errors.Is(err, ErrAccountUnavailable):
		// The open breaker refused the debit, so nothing was applied: 503 tells the
		// caller it is safe to come back later.
		writeJSON(w, http.StatusServiceUnavailable, t)
	default:
```

Urutan _case_ menentukan hasilnya. Rekening tujuan yang tidak ditemukan menghasilkan error yang membungkus `ErrCreditFailed` sekaligus `ErrAccountNotFound`. Bila _case_ 422 diperiksa terlebih dahulu, transfer tersebut dijawab 422 walaupun saldo sumber sudah terpotong. Hal yang sama berlaku untuk _circuit breaker_ yang beralih ke _open_ di antara _debit_ dan _credit_: tanpa _case_ `ErrCreditFailed` di urutan pertama, transfer tersebut dijawab 503 dan pemanggil mengira transfer aman diulang.

Di `transfer/main.go`, fungsi `run()`, ganti baris pembuatan `svc` dan `srv` menjadi seperti berikut.

```go
	accounts := accountclient.New(cfg.AccountServiceURL, accountclient.ProductionSettings, log)
	svc := transfer.NewService(store, accounts, log)
	mux := transfer.NewHandler(svc, log).Routes()
	mux.HandleFunc("GET /debug/circuit-breaker", accounts.ServeCircuitBreaker)
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
```

`Routes()` mengembalikan `*http.ServeMux`, sehingga _endpoint_ tambahan dapat didaftarkan langsung di `main.go`. Paket `transfer` tetap tidak mengenal _circuit breaker_.

Terakhir, perbarui komentar di atas `Execute` pada `transfer/internal/transfer/service.go`. Celah dari Lab 2 masih ada, dan _circuit breaker_ justru menambah peluang celah tersebut terjadi: _circuit breaker_ dapat beralih ke _open_ setelah _debit_ berhasil dan sebelum _credit_ dikirim.

```go
// Execute records the transfer, debits the source, then credits the destination.
// The returned error is the reason the transfer FAILED; the transfer itself is
// returned whenever it was recorded. A credit failure is always wrapped in
// ErrCreditFailed, whatever its cause, so callers can tell it apart from a debit
// failure (nothing applied).
//
// Known gap: debit and credit are two calls to another service, with no shared
// database transaction. When the credit fails after a successful debit, the money
// has left the source account and arrived nowhere. The transfer is marked FAILED
// and logged for manual reversal. The circuit breaker (Lab 3) makes this more
// likely, not less: it can open between the debit and the credit. Lab 5 replaces
// this with a saga that compensates the debit.
```

=== Langkah 10: _Unit Test_ untuk _Policy_

Ketiga _policy_ diuji dengan `httptest.Server` yang perilakunya diatur oleh _test_. `account` _service_ dan database tidak perlu berjalan. Angka _policy_ diperkecil agar setiap _test_ selesai dalam milidetik, sedangkan bentuk _policy_-nya tetap sama dengan `ProductionSettings`.

Di `transfer/internal/accountclient/client_test.go`, tambahkan _import_ `bytes`, `io`, `log/slog`, `strings`, `sync/atomic`, dan `time`. _Import_ `bytes` dan `strings` digunakan oleh _test_ keempat. Lalu tambahkan fungsi pembantu berikut setelah blok _import_.

```go
// testSettings keeps the production policy shape with short durations so the
// tests run in milliseconds.
var testSettings = Settings{
	AttemptTimeout:   100 * time.Millisecond,
	MaxRetries:       3,
	BackoffMin:       time.Millisecond,
	BackoffMax:       5 * time.Millisecond,
	BreakerFailures:  5,
	BreakerWindow:    10,
	BreakerDelay:     time.Hour, // stays open for the whole test
	BreakerSuccesses: 3,
}

func newTestClient(url string) *Client {
	return New(url, testSettings, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func debit(c *Client) error {
	return c.Debit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
}

// countingServer answers each request with status(n), n = 1 for the first request.
func countingServer(t *testing.T, status func(n int64) int) (*httptest.Server, *atomic.Int64) {
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status(calls.Add(1)))
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}
```

`countingServer` menghitung jumlah _request_ yang benar-benar diterima. Angka tersebut membuktikan berapa kali _retry_ terjadi dan apakah _circuit breaker_ yang _open_ benar-benar tidak mengirim _request_.

Karena _signature_ `New` berubah, _test_ milik Lab 2 perlu disesuaikan. Di `TestStatusMapping`, ganti pemanggilan `New(srv.URL).Debit(...)` dengan `debit(newTestClient(srv.URL))`. Ganti juga isi `TestServerError` agar sekaligus memastikan HTTP 500 tidak di-_retry_.

```go
func TestServerError(t *testing.T) {
	srv, calls := countingServer(t, func(int64) int { return http.StatusInternalServerError })
	err := newTestClient(srv.URL).Credit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
	if err == nil || errors.Is(err, transfer.ErrAccountNotFound) || errors.Is(err, transfer.ErrInsufficientFunds) {
		t.Fatalf("err = %v, want a non-business error", err)
	}
	// A 500 may come from a request that was half processed: no retry.
	if got := calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1", got)
	}
}
```

Tambahkan empat _test_ utama berikut. _Test_ pertama memastikan 503 di-_retry_ hingga berhasil.

```go
func TestRetryOn503Succeeds(t *testing.T) {
	srv, calls := countingServer(t, func(n int64) int {
		if n <= 2 {
			return http.StatusServiceUnavailable
		}
		return http.StatusOK
	})
	if err := debit(newTestClient(srv.URL)); err != nil {
		t.Fatalf("err = %v, want success after retries", err)
	}
	if got := calls.Load(); got != 3 {
		t.Fatalf("calls = %d, want 3 (two 503, then 200)", got)
	}
}
```

_Test_ kedua memastikan _timeout_ tidak di-_retry_. _Server_ menunggu 300 ms, lebih lama dari _timeout_ 100 ms di `testSettings`. _Server_ juga berhenti menunggu ketika _request_ dibatalkan, sehingga `t.Cleanup(srv.Close)` tidak tertahan.

```go
func TestNoRetryOnTimeout(t *testing.T) {
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		select {
		case <-time.After(300 * time.Millisecond):
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(srv.Close)

	start := time.Now()
	err := debit(newTestClient(srv.URL))
	if err == nil {
		t.Fatal("err = nil, want timeout")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1: a timed-out debit may have been applied", got)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("took %s, want about the attempt timeout", elapsed)
	}
}
```

_Test_ ketiga memastikan _circuit breaker_ beralih ke _open_ setelah 5 kegagalan, lalu menolak panggilan berikutnya dengan cepat tanpa mengirim _request_ ke _server_.

```go
func TestBreakerOpensAndRejectsFast(t *testing.T) {
	srv, calls := countingServer(t, func(int64) int { return http.StatusInternalServerError })
	c := newTestClient(srv.URL)

	for range 5 {
		_ = debit(c)
	}
	if got := c.BreakerState(); got != "open" {
		t.Fatalf("breaker = %s, want open after 5 failures", got)
	}

	start := time.Now()
	err := debit(c)
	if !errors.Is(err, transfer.ErrAccountUnavailable) {
		t.Fatalf("err = %v, want ErrAccountUnavailable", err)
	}
	if got := calls.Load(); got != 5 {
		t.Fatalf("calls = %d, want 5: an open breaker must not reach the server", got)
	}
	if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
		t.Fatalf("rejected in %s, want immediately", elapsed)
	}

	rec := httptest.NewRecorder()
	c.ServeCircuitBreaker(rec, httptest.NewRequest(http.MethodGet, "/debug/circuit-breaker", nil))
	if body := rec.Body.String(); body != `{"account":"open"}`+"\n" {
		t.Fatalf("debug body = %q", body)
	}
}
```

_Test_ keempat memastikan kegagalan koneksi di-_retry_. _Server_ langsung ditutup, sehingga setiap percobaan menghasilkan _connection refused_. _Log_ ditampung di `bytes.Buffer` agar jumlah baris `retrying account call` dapat dihitung. Empat kegagalan masih di bawah ambang 5, sehingga _circuit breaker_ tetap _closed_.

```go
func TestRetryOnConnectionRefused(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close() // nothing listens on this port any more

	var logs bytes.Buffer
	c := New(url, testSettings, slog.New(slog.NewTextHandler(&logs, nil)))
	if err := debit(c); err == nil || errors.Is(err, transfer.ErrAccountUnavailable) {
		t.Fatalf("err = %v, want a connection error", err)
	}
	if got := strings.Count(logs.String(), "retrying account call"); got != 3 {
		t.Fatalf("retries = %d, want 3; logs:\n%s", got, logs.String())
	}
	// 4 refused attempts count as 4 breaker failures, still under 5.
	if got := c.BreakerState(); got != "closed" {
		t.Fatalf("breaker = %s, want closed", got)
	}
}
```

_Checkpoint_ `lab-03` memuat tiga _test_ tambahan dengan pola yang sama. Peserta disarankan menulisnya sendiri sebagai latihan sebelum membandingkan dengan _checkpoint_:

- `TestRetryGivesUpAfterMaxRetries`: _server_ selalu menjawab 503, dan _server_ harus menerima tepat 4 _request_ (1 percobaan awal ditambah 3 _retry_).
- `TestBusinessRejectionsDoNotOpenBreaker`: sepuluh jawaban 422 berturut-turut tidak mengubah _circuit breaker_ dari _closed_.
- `TestBreakerHalfOpenCloses`: dengan `BreakerDelay` 50 ms, _circuit breaker_ beralih dari _open_ ke _half-open_ setelah panggilan uji pertama berhasil, lalu ke _closed_ setelah panggilan uji ketiga.

Di `transfer/internal/transfer/service_test.go`, tabel `TestExecute` perlu tiga perubahan. Kasus `credit fails after debit` milik Lab 2 kini mengharapkan `ErrCreditFailed`. Dua kasus baru memastikan _credit_ tidak dipanggil ketika _debit_ ditolak _circuit breaker_, dan memastikan _circuit breaker_ yang beralih ke _open_ setelah _debit_ tetap menghasilkan `ErrCreditFailed`.

```go
		{"credit fails after debit", &fakeAccounts{creditErr: unavailable}, Failed, ErrCreditFailed, 2},
		{"open circuit breaker fails the transfer", &fakeAccounts{debitErr: ErrAccountUnavailable}, Failed, ErrAccountUnavailable, 1},
		{"breaker opens between debit and credit", &fakeAccounts{creditErr: ErrAccountUnavailable}, Failed, ErrCreditFailed, 2},
```

Pemetaan error ke kode HTTP juga diuji. Buat file baru `transfer/internal/transfer/http_test.go`. _Test_ ini menggunakan `fakeStore` dan `fakeAccounts` yang sudah ada di `service_test.go`, lalu mengirim `POST /transfers` ke `httptest.Server` untuk setiap kemungkinan hasil.

```go
package transfer

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestCreateStatus checks the HTTP status for each outcome. 503 is reserved for
// "nothing applied, safe to retry"; once the debit went through, every credit
// failure is a 502, even when the cause is the open breaker.
func TestCreateStatus(t *testing.T) {
	tests := []struct {
		name     string
		accounts *fakeAccounts
		want     int
	}{
		{"success", &fakeAccounts{}, http.StatusCreated},
		{"insufficient funds", &fakeAccounts{debitErr: ErrInsufficientFunds}, http.StatusUnprocessableEntity},
		{"breaker open before debit", &fakeAccounts{debitErr: ErrAccountUnavailable}, http.StatusServiceUnavailable},
		{"breaker opens between debit and credit", &fakeAccounts{creditErr: ErrAccountUnavailable}, http.StatusBadGateway},
		{"destination not found after debit", &fakeAccounts{creditErr: ErrAccountNotFound}, http.StatusBadGateway},
		{"credit fails after debit", &fakeAccounts{creditErr: errors.New("connection refused")}, http.StatusBadGateway},
		{"debit fails on transport error", &fakeAccounts{debitErr: errors.New("connection refused")}, http.StatusBadGateway},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			log := slog.New(slog.NewTextHandler(io.Discard, nil))
			svc := NewService(&fakeStore{transfers: map[string]Transfer{}}, tc.accounts, log)
			srv := httptest.NewServer(NewHandler(svc, log).Routes())
			defer srv.Close()

			body := `{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}`
			resp, err := http.Post(srv.URL+"/transfers", "application/json", strings.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.want)
			}
		})
	}
}
```

Kasus `destination not found after debit` gagal bila _case_ `ErrCreditFailed` diletakkan setelah _case_ 422, dan kasus `breaker opens between debit and credit` gagal bila _case_ tersebut diletakkan setelah _case_ 503.

Jalankan seluruh _test_.

#perintah[
```bash
make test
```
]

Seluruh _test_ harus lulus. `go vet` di target `test` juga memeriksa kode sebelum _test_ dijalankan.

== Verifikasi

Verifikasi berikut menjalankan `account` dan `transfer`, lalu mengamati perilaku _policy_ dari sisi pemanggil dan dari _log_. Gunakan tiga terminal, semuanya di folder `studi-kasus`.

#perintah[
```bash
# terminal 1
make -C account run

# terminal 2
make -C transfer run

# terminal 3: perintah verifikasi di bawah
```
]

=== Kondisi Normal

Siapkan dua rekening:

#perintah[
```bash
curl -sS -X POST localhost:28081/accounts -H 'Content-Type: application/json' \
  -d '{"number":"1111111111","owner_name":"Nasabah Satu","initial_balance":"1000000"}'
curl -sS -X POST localhost:28081/accounts -H 'Content-Type: application/json' \
  -d '{"number":"2222222222","owner_name":"Nasabah Dua","initial_balance":"0"}'

curl -sS -w '\nHTTP %{http_code}\n' -X POST localhost:28082/transfers \
  -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"10000"}'
make breaker
```
]

Transfer dijawab `HTTP 201` dengan `"status":"COMPLETED"`, dan `make breaker` menampilkan hasil berikut. Baris pertama _output_ setiap target `make` adalah perintah yang dijalankan, misalnya `curl -sS http://localhost:28082/debug/circuit-breaker`; contoh di panduan ini hanya menampilkan hasilnya:

```
{"account":"closed"}
```

=== _Timeout_ dan _Circuit Breaker_ Saat `account` Lambat

Aktifkan jeda 3 detik, lebih lama dari _timeout_ 2 detik. Catat saldo rekening sumber, lalu kirim enam transfer berturut-turut sambil mencetak kode HTTP dan lama setiap _request_.

#perintah[
```bash
make fault-slow
curl -sS localhost:28081/accounts/1111111111

for i in 1 2 3 4 5 6; do
  curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' -X POST localhost:28082/transfers \
    -H 'Content-Type: application/json' \
    -d '{"from_account":"1111111111","to_account":"2222222222","amount":"10000"}'
done
make breaker
```
]

Hasil yang diharapkan (angka waktu di laptop masing-masing sedikit berbeda):

```
502 2.012841s
502 2.004377s
502 2.003915s
502 2.005102s
502 2.004260s
503 0.002118s
{"account":"open"}
```

Penjelasannya:

- Setiap transfer pertama hingga kelima menunggu sekitar 2 detik walaupun jeda di `account` 3 detik. _Timeout_ menghentikan panggilan setelah 2 detik, dan karena _timeout_ tidak di-_retry_, setiap transfer hanya melakukan satu percobaan _debit_.
- Setiap _timeout_ dihitung satu kegagalan oleh _circuit breaker_. Setelah kegagalan kelima, _circuit breaker_ beralih ke _open_.
- Transfer keenam dijawab `503` seketika. `transfer` tidak mengirim _request_ apa pun ke `account`.

Di terminal 2, _log_ `transfer` menampilkan baris seperti berikut (atribut `time` tidak ditampilkan agar ringkas).

```
level=WARN msg="transfer failed" transfer_id=... reason="debit failed: debit 1111111111: Post \"http://localhost:28081/accounts/1111111111/debit\": timeout exceeded"
level=WARN msg="circuit breaker state changed" target=account from=closed to=open
level=WARN msg="transfer failed" transfer_id=... reason="debit failed: debit 1111111111: account service unavailable"
```

Periksa lagi saldo rekening sumber dengan `curl -sS localhost:28081/accounts/1111111111`. Saldo tidak berubah dibandingkan sebelum `make fault-slow`. Ingat penjelasan di Langkah 6: saldo tetap utuh hanya karena _fault injector_ berhenti saat `transfer` membatalkan _request_. Database yang lambat di sistem sungguhan dapat saja sudah melakukan _commit_ atas _debit_ tersebut, dan itulah alasan _timeout_ tidak di-_retry_.

=== Perpindahan _Half-Open_ ke _Closed_

Matikan _fault_, tunggu lebih dari 10 detik, lalu periksa status _circuit breaker_.

#perintah[
```bash
make fault-clear
sleep 11
make breaker
```
]

Hasilnya masih `{"account":"open"}`. Status _circuit breaker_ di failsafe-go diperbarui hanya ketika ada panggilan masuk. Selama tidak ada transfer, `/debug/circuit-breaker` tetap menampilkan `open` walaupun 10 detik sudah lewat.

Kirim dua transfer dan periksa status setelah masing-masing transfer.

#perintah[
```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST localhost:28082/transfers \
  -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"10000"}'
make breaker

curl -sS -o /dev/null -w '%{http_code}\n' -X POST localhost:28082/transfers \
  -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"10000"}'
make breaker
```
]

Hasil yang diharapkan:

```
201
{"account":"half-open"}
201
{"account":"closed"}
```

_Debit_ dan _credit_ berbagi satu _circuit breaker_, sehingga tiga panggilan uji di status _half-open_ terdiri dari _debit_ dan _credit_ transfer pertama, lalu _debit_ transfer kedua. Setelah transfer pertama, baru dua panggilan uji yang berhasil, sehingga statusnya masih _half-open_. _Debit_ transfer kedua melengkapi panggilan uji ketiga dan mengembalikan status ke _closed_. _Log_ `transfer` mencatat kedua perpindahan tersebut:

```
level=WARN msg="circuit breaker state changed" target=account from=open to=half-open
level=WARN msg="circuit breaker state changed" target=account from=half-open to=closed
```

=== _Retry_ Saat `account` Sering Gagal

Aktifkan jawaban 503 untuk 20% _request_, lalu kirim sepuluh transfer.

#perintah[
```bash
make fault-error RATE=0.2
for i in $(seq 1 10); do
  curl -sS -o /dev/null -w '%{http_code}\n' -X POST localhost:28082/transfers \
    -H 'Content-Type: application/json' \
    -d '{"from_account":"1111111111","to_account":"2222222222","amount":"10000"}'
done
make breaker
make fault-clear
```
]

Sebagian besar transfer dijawab `201` walaupun sebagian _request_ ke `account` gagal. _Log_ `transfer` menampilkan baris `retrying account call` untuk setiap 503 yang di-_retry_:

```
level=WARN msg="retrying account call" next_attempt=... cause="503 Service Unavailable"
```

Karena hasilnya acak, jumlah _retry_ dan status akhir _circuit breaker_ berbeda di setiap percobaan. Ulangi skenario tersebut dengan `RATE=0.5`. _Circuit breaker_ biasanya beralih ke _open_ setelah dua atau tiga transfer saja. Hal ini terjadi karena _circuit breaker_ berada di dalam _retry_, sehingga setiap percobaan ulang ikut dihitung. Satu transfer yang menghabiskan seluruh _retry_ menyumbang empat kegagalan sekaligus. Untuk peragaan bertahap, gunakan `RATE=0.2` atau `make fault-slow`.

Dengan `RATE` yang tinggi, sesekali muncul transfer yang dijawab `502` dengan `failure_reason` berawalan `credit failed after debit`. Pada transfer tersebut, _debit_ berhasil, lalu _credit_ gagal karena keempat percobaannya dijawab 503, atau karena _circuit breaker_ beralih ke _open_ di tengah _retry_ untuk _credit_. Karena hasilnya acak, bagian berikut memperagakan kegagalan _credit_ dengan skenario yang dapat diulang dengan hasil yang selalu sama.

=== _Credit_ Gagal Setelah _Debit_

Kirim transfer ke rekening tujuan yang tidak ada. _Debit_ berhasil, lalu _credit_ ditolak karena rekening tujuan tidak ditemukan.

Pastikan _fault_ sudah dimatikan (`make fault-clear`) dan sudah lewat lebih dari 10 detik sejak _circuit breaker_ terakhir beralih ke _open_. Sebelum jeda tersebut lewat, _debit_ langsung ditolak dengan `HTTP 503`. Setelah jeda lewat, `make breaker` masih menampilkan `open` hingga transfer berikutnya masuk, sehingga tidak perlu menunggu _output_ tersebut berubah.

#perintah[
```bash
curl -sS localhost:28081/accounts/1111111111
curl -sS -w '\nHTTP %{http_code}\n' -X POST localhost:28082/transfers \
  -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"9999999999","amount":"10000"}'
curl -sS localhost:28081/accounts/1111111111
```
]

Transfer dijawab `HTTP 502` dengan `"status":"FAILED"` dan `"failure_reason":"credit failed after debit: credit 9999999999: account not found"`. Saldo rekening sumber berkurang 10000. Kode `422` tidak digunakan di sini walaupun penyebabnya rekening yang tidak ditemukan, karena saldo sudah berubah dan transfer tidak boleh diulang. _Log_ `transfer` mencatat kasus tersebut untuk pengembalian manual:

```
level=ERROR msg="credit failed after debit, source account needs manual reversal" transfer_id=... from_account=1111111111 amount=10000 error="credit 9999999999: account not found"
level=WARN msg="transfer failed" transfer_id=... reason="credit failed after debit: credit 9999999999: account not found"
```

Bandingkan dengan rekening sumber yang tidak ada, misalnya `"from_account":"8888888888"`. Transfer tersebut dijawab `HTTP 422` dengan `failure_reason` `debit failed: debit 8888888888: account not found`, karena _debit_ ditolak dan belum ada saldo yang berubah.

#note[
  *Ringkasan _log_ yang perlu diamati.* `retrying account call` (atribut `next_attempt` dan `cause`) muncul di setiap _retry_. `circuit breaker state changed` (atribut `target`, `from`, `to`) muncul di setiap perubahan status. `transfer failed` (atribut `reason`) menjelaskan penyebab transfer berstatus `FAILED`. `credit failed after debit, source account needs manual reversal` (level `ERROR`) menandai transfer yang saldo sumbernya perlu dikembalikan manual. Di sisi `account`, `fault injection changed` dan `fault injection cleared` mencatat perubahan _fault_.
]

== Masalah Umum

- *`make -C transfer run` gagal dengan `not enough arguments in call to accountclient.New`.* _Signature_ `New` kini menerima `Settings` dan _logger_. Perbarui `transfer/main.go` sesuai Langkah 9 dan pemanggilan di `client_test.go` sesuai Langkah 10.
- *`missing go.sum entry` atau `no required module provides package github.com/failsafe-go/...`.* Dependensi belum ditambahkan ke modul `transfer`. Ulangi Langkah 3 dari folder `transfer`, bukan dari `studi-kasus`.
- *`make fault-error` berhenti dengan `RATE is required`.* Target tersebut wajib diberi nilai, misalnya `make fault-error RATE=0.2`.
- *`curl` ke `/admin/fault` menjawab `404`.* _Fault injector_ berada di `account` (port 28081), bukan di `transfer` (port 28082). Pastikan juga paket `fault` sudah ada (Langkah 1) dan `account` sudah dijalankan ulang setelahnya.
- *Transfer tetap lambat 3 detik setelah `make fault-slow`.* _Timeout_ belum terpasang. Periksa apakah `http.Client` di `New` menggunakan `Transport: rt`, dan apakah `main.go` memanggil `accountclient.New` dengan `ProductionSettings`.
- *`make breaker` menampilkan `open` lebih dari 10 detik setelah `make fault-clear`.* Perilaku ini normal. Status _circuit breaker_ baru berpindah ke _half-open_ ketika transfer berikutnya masuk.
- *_Circuit breaker_ beralih ke _open_ jauh lebih cepat dari perkiraan.* Setiap _retry_ dihitung sebagai panggilan terpisah oleh _circuit breaker_. Satu transfer dengan _retry_ habis menyumbang empat kegagalan.
- *`TestNoRetryOnTimeout` gagal dengan `calls = 2` atau lebih.* `notProcessed` mengembalikan `true` untuk _timeout_. Pastikan fungsi tersebut hanya menerima error `*net.OpError` dengan `Op == "dial"` dan HTTP 503.

== Eksplorasi Mandiri

+ *_Connection refused_.* Hentikan `account` dengan Ctrl+C di terminal 1, lalu kirim beberapa transfer. Amati jumlah baris `retrying account call` untuk setiap transfer, nilai atribut `cause`, dan transfer ke berapa yang membuat _circuit breaker_ beralih ke _open_. Jalankan lagi `account`, lalu amati perpindahan ke _half-open_ dan _closed_.
+ *Mengubah angka _policy_.* Ubah `BreakerDelay` di `ProductionSettings` menjadi 30 detik dan `AttemptTimeout` menjadi 500 ms, lalu ulangi skenario `make fault-slow`. Catat perubahan lama setiap transfer dan lama _circuit breaker_ bertahan di _open_. Pertimbangkan dampaknya bagi nasabah yang menunggu jawaban transfer.
+ *_Circuit breaker_ terpisah untuk _debit_ dan _credit_.* Ubah `Client` agar _debit_ dan _credit_ masing-masing memiliki _circuit breaker_ sendiri. Bandingkan hasil skenario _half-open_ dengan hasil di bagian Verifikasi, lalu diskusikan: dalam kondisi apa pemisahan tersebut berguna, dan dalam kondisi apa pemisahan tersebut justru menyesatkan?
+ *_Bulkhead_.* failsafe-go juga menyediakan _bulkhead_, yang membatasi jumlah panggilan bersamaan ke satu service. Di `transfer/internal/accountclient/client.go`, impor `github.com/failsafe-go/failsafe-go/bulkhead`, lalu pasang _bulkhead_ sebagai _policy_ paling luar:

  #perintah[```go
bh := bulkhead.New[*http.Response](5)
rt := failsafehttp.NewRoundTripper(nil, bh, retry, breaker, timeout.New[*http.Response](s.AttemptTimeout))
```]

  Jalankan ulang `transfer`, aktifkan `make fault-slow`, lalu kirim 20 transfer sekaligus dan catat _status code_ serta lama setiap _request_:

  #perintah[```bash
seq 20 | xargs -P 20 -I{} curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' \
  -X POST localhost:28082/transfers -H 'Content-Type: application/json' \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"1000"}'
```]

  Lima _request_ menunggu hingga _timeout_, sekitar 2 detik. Sisanya langsung ditolak dalam hitungan milidetik, dengan `failure_reason` yang memuat `bulkhead full`. Diskusikan: bila `transfer` juga memanggil service lain selain `account`, apa yang terjadi pada panggilan tersebut tanpa _bulkhead_ ketika `account` sedang lambat? Setelah selesai, jalankan `make fault-clear` dan kembalikan `client.go` dengan `git checkout -- transfer/internal/accountclient/client.go`.
+ *Celah _credit_ setelah _debit_.* Baca kasus `breaker opens between debit and credit` di `service_test.go`. Kasus tersebut menunjukkan bahwa _circuit breaker_ yang beralih ke _open_ setelah _debit_ berhasil membuat uang keluar dari rekening sumber tanpa masuk ke rekening tujuan. Rancang urutan langkah yang diperlukan untuk mengembalikan dana tersebut secara otomatis. Lab 5 menyelesaikan celah ini dengan pola _saga_ dan kompensasi.

== _Checkpoint_


Kondisi kode di akhir lab ini tersimpan di _tag_ `lab-03`. Setelah `git checkout lab-03 -- studi-kasus` di awal bab, kode di _branch_ kerja sudah sama dengan _tag_ tersebut. Peserta yang mengetik ulang kode sendiri membandingkan hasilnya dari folder repositori:

#perintah[```bash
git diff lab-03 -- studi-kasus
```]

Perbedaan pada `README.md` dan `go.work.sum` memang wajar. `README.md` di _checkpoint_ memuat bagian baru tentang rekening contoh dan _resiliency_, sedangkan isi `go.work.sum` bergantung pada dependensi yang sudah di-_download_ di laptop masing-masing.

Lab 4 dimulai dari _tag_ ini (bagian Titik Awal Lab 4).
