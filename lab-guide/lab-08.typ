#import "../_template/panduan.typ": note, perintah

= Lab 8: _Observability_ Tiga Service

== Tujuan

Hingga Lab 7, gangguan pada sistem transfer hanya terlihat dari log teks di tiga terminal yang terpisah. Untuk mengetahui mengapa sebuah transfer gagal, peserta harus mencocokkan waktu di log `transfer`, `account`, dan `notification` secara manual. Lab ini menambahkan tiga sinyal _observability_ ke setiap service sehingga satu transfer dapat diikuti dari _request_ pertama hingga notifikasi terkirim.

Setelah menyelesaikan lab ini, peserta mampu:

- menulis log JSON dengan `slog` yang selalu membawa `correlation_id`, `trace_id`, dan `span_id`, lalu mengirimkannya ke Loki;
- membuat _correlation ID_ di _middleware_ HTTP dan meneruskannya lewat _metadata_ gRPC serta _header_ Kafka;
- menyediakan _metric_ Prometheus di `GET /metrics`: durasi _request_ per _route_, jumlah transfer per status, status _circuit breaker_, antrean _outbox_, dan notifikasi per hasil;
- mengirim _trace_ OpenTelemetry dari ketiga service, termasuk melewati Kafka, sehingga satu transfer menjadi satu _trace_;
- menemukan service yang lambat dari _dashboard_ Grafana, _trace_ di Tempo, dan log di Loki.

== Gambaran

Ketiga sinyal tersebut saling melengkapi. _Metric_ menunjukkan adanya masalah beserta besar dampaknya. _Trace_ menunjukkan service yang menghabiskan waktu paling lama, dan log menjelaskan kejadian di dalam service tersebut.

#table(
  columns: (auto, 1fr, 1fr),
  [Sinyal], [Cara Keluar dari Service], [Penyimpanan di `otel-lgtm`],
  [Log], [JSON ke _stdout_ sekaligus OTLP gRPC ke `localhost:4317`], [Loki],
  [_Trace_], [OTLP gRPC ke `localhost:4317`, dikirim per _batch_ di latar belakang], [Tempo],
  [_Metric_], [`GET /metrics` di port HTTP masing-masing service, diambil Prometheus setiap 5 detik], [Prometheus],
)

Seluruh _backend_ tersebut berjalan di satu _container_ `grafana/otel-lgtm:0.37.0`. _Container_ ini berisi OpenTelemetry Collector, Prometheus, Tempo, Loki, dan Grafana, dan khusus ditujukan untuk pengembangan serta lab. Di _production_, setiap komponen berjalan terpisah dengan _storage_ masing-masing.

```
account      :8081 -+
transfer     :8082 -+- OTLP :4317 (trace, log) -> otel-lgtm
notification :8083 -+                              |- Collector -> Tempo (trace)
     ^                                             |            -> Loki (log)
     |                                             |- Prometheus (metric)
     +--- GET /metrics setiap 5 detik -------------+
          (host.docker.internal:808x)              |- Grafana :3000
```

Arah _metric_ berlawanan dengan dua sinyal lainnya. Log dan _trace_ didorong (_push_) oleh service ke _collector_, sedangkan _metric_ diambil (_pull_, _scrape_) oleh Prometheus dari service. Karena service berjalan di laptop dan Prometheus di dalam _container_, Prometheus menghubungi laptop lewat nama `host.docker.internal`.

Tantangan utama lab ini terletak pada upaya menjaga satu _trace_ tetap utuh melintasi tiga service. Untuk HTTP dan gRPC, OpenTelemetry sudah menyediakan instrumentasi (`otelhttp`, `otelgrpc`) yang menulis dan membaca _header_ `traceparent` (standar W3C _Trace Context_). Jalur Kafka lebih rumit: _relay outbox_ mengirim _event_ dari _goroutine_ terpisah, setelah _request_ asal selesai. Pada saat itu _context_ milik _request_ sudah tidak ada. Karena itu _correlation ID_ dan _trace context_ disimpan di baris tabel `outbox` dalam transaksi yang sama dengan _event_, lalu _relay_ menyalinnya ke _header_ Kafka. Hasilnya satu _trace_ seperti berikut:

```
transfer      POST /transfers
transfer        HTTP POST                          (token Hydra, bila belum ada)
transfer        account.v1.AccountService/Debit    (client, 1 span/percobaan)
account           account.v1.AccountService/Debit  (server)
transfer        account.v1.AccountService/Credit
account           account.v1.AccountService/Credit
transfer        publish transfer-events            (relay outbox)
notification      process transfer-events
```

_Correlation ID_ dan _trace ID_ memiliki peran berbeda. _Correlation ID_ merupakan ID di sisi bisnis yang diketahui pemanggil, sehingga pemanggil, misalnya aplikasi _channel_, dapat melaporkan "transfer dengan _correlation ID_ X gagal". _Trace ID_ adalah ID teknis buatan OpenTelemetry. Keduanya ditulis di setiap baris log.

#table(
  columns: (auto, 1fr, 1fr),
  [Jalur], [_Correlation ID_], [_Trace Context_ (W3C)],
  [REST], [_Header_ `X-Correlation-ID`; dibuat (UUID) bila tidak ada atau formatnya tidak valid; dikembalikan di respons], [_Header_ `traceparent`, ditangani `otelhttp`],
  [gRPC `transfer` ke `account`], [_Metadata_ `x-correlation-id`], [_Metadata_ `traceparent`, ditangani `otelgrpc`],
  [Kafka `transfer` ke `notification`], [_Header_ `correlation_id`], [_Header_ `traceparent`, ditulis dan dibaca sendiri],
)

== Titik Awal

Lab ini melanjutkan kode dari akhir Lab 7. Peserta yang belum menyelesaikan Lab 7 dapat memulai dari _checkpoint_:

#perintah[```bash
cd training-microservices-2026-01
git switch -c lab-08-kerja lab-07
cd studi-kasus
make infra-up
```]

Semua perintah di bab ini dijalankan dari folder `studi-kasus`, kecuali disebutkan lain.

Pastikan service lama sudah berhenti. Hentikan `account`, `transfer`, dan `notification` dengan Ctrl+C di terminal masing-masing. Ketiganya dijalankan ulang dengan variabel `OTEL_*` yang baru di langkah berikutnya.

Database dari Lab 7 tidak perlu di-_reset_. Kolom baru di tabel `outbox` dibuat otomatis oleh _schema_ `transfer` saat service dijalankan.

Rekening `1111111111` dan `2222222222` dari lab sebelumnya digunakan di seluruh contoh. Bila nomor rekening di database berbeda, sesuaikan nomor di perintah `curl`.

== Langkah

=== Menambahkan `otel-lgtm` ke Docker Compose

Konfigurasi Prometheus dan _dashboard_ Grafana sudah disediakan, sama seperti konfigurasi Hydra di Lab 7. Fokus lab ini ada di kode service, sehingga _file_ konfigurasi tersebut cukup disalin dari _checkpoint_:

#perintah[```bash
git checkout lab-08 -- observability Makefile
ls observability observability/dashboards
```]

`Makefile` di folder `studi-kasus` mendapat _target_ `metrics`, yang membaca `/metrics` dari ketiga service lalu menyaring _metric_ domain. Folder `observability` berisi tiga _file_:

#table(
  columns: (auto, 1fr),
  [_File_], [Isi],
  [`prometheus.yaml`], [Tiga _scrape job_ (`account`, `transfer`, `notification`) ke `host.docker.internal:8081`–`8083` setiap 5 detik, ditambah konfigurasi bawaan _image_ yang tetap dibutuhkan penerima OTLP],
  [`grafana-dashboards.yaml`], [_Provider_ yang memuat semua JSON di folder `dashboards` ke folder Grafana _Studi Kasus_],
  [`dashboards/studi-kasus.json`], [_Dashboard_ _Studi Kasus: Transfer_ dengan sembilan panel],
)

`otel-lgtm` versi 0.37.0 tidak menyediakan opsi untuk menambah target _scrape_. Prometheus di dalam _image_ selalu membaca `/otel-lgtm/prometheus.yaml`, sehingga _file_ tersebut ditimpa lewat _volume_. Tambahkan service berikut di `studi-kasus/compose.yaml`, sebelum bagian `volumes:` di akhir _file_:

```yaml
  # Observability backend in one container (Lab 8), for development and labs
  # only. 3000 Grafana (no login), 4317 OTLP gRPC, 4318 OTLP HTTP.
  otel-lgtm:
    image: grafana/otel-lgtm:0.37.0
    ports:
      - "3000:3000"
      - "4317:4317"
      - "4318:4318"
    # host.docker.internal = the laptop. Docker Desktop has it built in; on a
    # Linux Docker Engine this line creates it.
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./observability/prometheus.yaml:/otel-lgtm/prometheus.yaml:ro
      # Long form only to fit the page; same as the short form in the repo.
      - type: bind
        source: ./observability/grafana-dashboards.yaml
        target: /otel-lgtm/grafana/conf/provisioning/dashboards/studi-kasus.yaml
        read_only: true
      - ./observability/dashboards:/otel-lgtm/dashboards/studi-kasus:ro
    # The image checks every 30 s; up --wait would sit idle that long.
    healthcheck:
      test: ["CMD", "/otel-lgtm/docker/healthcheck.sh"]
      interval: 5s
      timeout: 5s
      retries: 60
```

_Container_ ini tidak memiliki _volume_ data: semua log, _trace_, dan _metric_ hilang ketika _container_ dibuat ulang. Untuk lab, kondisi tersebut justru memudahkan, karena setiap sesi dimulai dari data kosong.

#perintah[```bash
make infra-up
docker compose ps otel-lgtm
```]

Buka http://localhost:3000. Grafana di _container_ ini berjalan dengan akses anonim sebagai admin, tanpa halaman _login_. Folder _Dashboards_ → _Studi Kasus_ sudah berisi _Studi Kasus: Transfer_, tetapi semua panel masih kosong karena service belum menyediakan `/metrics`.

// TODO(endy): host.docker.internal + host-gateway was only tested on socktainer; run once on Docker Desktop and on a Linux Docker Engine before delivery.

=== Menambahkan _Dependency_

Setiap service mendapat _library_ Prometheus dan OpenTelemetry. Versi ditulis eksplisit agar hasilnya sama dengan _checkpoint_. Jalankan dari folder `studi-kasus`:

#perintah[```bash
OTEL="github.com/prometheus/client_golang@v1.25.0 \
  go.opentelemetry.io/otel@v1.47.0 \
  go.opentelemetry.io/otel/trace@v1.47.0 \
  go.opentelemetry.io/otel/sdk@v1.47.0 \
  go.opentelemetry.io/otel/sdk/log@v1.47.0 \
  go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc@v1.47.0 \
  go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc@v0.23.0 \
  go.opentelemetry.io/contrib/bridges/otelslog@v0.21.0 \
  go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@v0.72.0"
CONTRIB=go.opentelemetry.io/contrib/instrumentation
GRPC_OTEL=$CONTRIB/google.golang.org/grpc/otelgrpc@v0.72.0

(cd account      && go get $OTEL $GRPC_OTEL github.com/google/uuid@v1.6.0)
(cd transfer     && go get $OTEL $GRPC_OTEL)
(cd notification && go get $OTEL)
go work sync
```]

`otelgrpc` menaikkan versi `google.golang.org/grpc` ke v1.83.2. Perintah `go work sync` menyalin versi tersebut ke `go.mod` modul lain di _workspace_, termasuk `proto`, sehingga semua modul menggunakan versi gRPC yang sama. Jalankan `go mod tidy` di setiap modul setelah kode di langkah berikutnya selesai ditulis.

=== Konfigurasi OpenTelemetry yang Wajib

Ketiga service membutuhkan dua variabel baru. Nama variabel mengikuti standar OpenTelemetry, sehingga nilai yang sama berlaku untuk SDK OpenTelemetry bahasa apa pun.

#table(
  columns: (auto, auto, 1fr),
  [Variabel], [Nilai di Laptop], [Keterangan],
  [`OTEL_EXPORTER_OTLP_ENDPOINT`], [`http://localhost:4317`], [Alamat OTLP gRPC _collector_, wajib berbentuk URL `http://host:port` atau `https://host:port` dengan port tertulis],
  [`OTEL_SERVICE_NAME`], [`account`, `transfer`, `notification`], [Nama service di Tempo dan Loki],
)

Pemeriksaan format URL diperlukan karena _exporter_ OTLP mengabaikan nilai yang formatnya salah lalu mengirim ke alamat bawaan tanpa peringatan apa pun. Akibatnya service tampak normal, tetapi _trace_ tidak pernah sampai. Port juga wajib ditulis. Untuk URL tanpa port, misalnya `http://localhost`, gRPC menghubungi port 443, sehingga service tetap berjalan tetapi setiap _export_ gagal setelah _startup_. Tambahkan di `Config` pada `transfer/config.go`:

```go
	// Lab 8: the OpenTelemetry collector's OTLP gRPC endpoint as a URL
	// (http://localhost:4317) and the name the traces and logs carry.
	OTelEndpoint    string
	OTelServiceName string
```

Lalu di `LoadConfig`, isi kedua _field_ dengan fungsi `get` yang sudah ada dan periksa formatnya setelah pemeriksaan variabel yang hilang:

```go
		OTelEndpoint:      get("OTEL_EXPORTER_OTLP_ENDPOINT"),
		OTelServiceName:   get("OTEL_SERVICE_NAME"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	if err := checkEndpointURL("OTEL_EXPORTER_OTLP_ENDPOINT", cfg.OTelEndpoint); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// checkEndpointURL rejects anything but scheme://host:port. The OTLP exporter
// would otherwise ignore a malformed value and silently send to its built-in
// default address. The port is required too: without it gRPC dials port 443,
// and http://localhost (no port) would fail on every export, not at startup.
func checkEndpointURL(name, v string) error {
	u, err := url.Parse(v)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
		return fmt.Errorf("%s must be a URL like http://localhost:4317, got %q", name, v)
	}
	if u.Port() == "" {
		return fmt.Errorf("%s must name the port explicitly, like http://localhost:4317, got %q", name, v)
	}
	return nil
}
```

Tambahkan `"net/url"` di `import`. Lakukan perubahan yang sama di `account/config.go` dan `notification/config.go`. Terakhir, tambahkan kedua variabel di target `run` pada `Makefile` setiap service, tepat sebelum baris `go run .`, dengan `OTEL_SERVICE_NAME` sesuai nama service:

```make
	OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
	OTEL_SERVICE_NAME=transfer \
	go run .
```

=== Paket `telemetry` di `transfer`

Seluruh kode _observability_ dikumpulkan di paket `internal/telemetry`. Paket ini disalin ke setiap service, sengaja tidak dijadikan _library_ bersama: service berbagi konvensi (nama _header_, nama _metric_), tetapi tidak berbagi kode. _Library_ bersama akan mengikat jadwal rilis ketiga service menjadi satu. Paket ditulis lebih dahulu di `transfer`, karena `transfer` menggunakan ketiga jalur (HTTP, gRPC, dan Kafka).

==== `telemetry.go`: _exporter_ dan _logger_

Fungsi `Setup` menyiapkan _tracer provider_, _propagator_, dan _logger_. Tidak ada koneksi yang dibuka di sini: _collector_ yang mati tidak menghentikan service. Kegagalan kirim dicatat di _stdout_ sebagai `telemetry export failed`, dan _span_ serta log yang gagal dikirim dibuang. Keputusan ini disengaja: _observability_ tidak boleh menjadi alasan transfer gagal.

Buat `transfer/internal/telemetry/telemetry.go`:

```go
// Package telemetry wires the three observability signals of the service
// (Lab 8): logs (stdout + OTLP), traces (OTLP) and metrics (Prometheus),
// plus the correlation ID that ties the log lines of one request together.
//
// Every service has its own copy of this package on purpose: services share
// conventions (header names, metric names), not code.
package telemetry

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

type Telemetry struct {
	// Logger writes JSON to stdout and OTLP logs to the collector. Log with a
	// context (InfoContext etc.) inside request handling, so the record gets
	// the correlation ID and trace ID.
	Logger *slog.Logger
	tp     *sdktrace.TracerProvider
	lp     *sdklog.LoggerProvider
}

// Setup installs the global tracer provider and propagator and builds the
// logger. Nothing connects here: a collector that is down does not stop the
// service, export failures are logged on stdout instead.
func Setup(ctx context.Context, serviceName, otlpEndpoint string) (*Telemetry, error) {
	// service.name is how Tempo, Loki and Grafana tell the services apart.
	res, err := resource.New(ctx,
		resource.WithAttributes(attribute.String("service.name", serviceName)),
		resource.WithHost(),
		resource.WithTelemetrySDK())
	if err != nil {
		return nil, fmt.Errorf("telemetry resource: %w", err)
	}

	stdout := slog.NewJSONHandler(os.Stdout, nil)
	// Export failures go to stdout only: sending them through the OTLP log
	// exporter would feed the failure back into the exporter that is failing.
	exportLog := slog.New(stdout)
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		exportLog.Warn("telemetry export failed", "error", err)
	}))

	traceExp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpointURL(otlpEndpoint))
	if err != nil {
		return nil, fmt.Errorf("OTLP trace exporter: %w", err)
	}
	tp := sdktrace.NewTracerProvider(
		// Spans are sent in batches in the background, never inside the request.
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
		// Every trace is kept: right for a lab. Production keeps a fraction
		// (TraceIDRatioBased) or decides at the collector (tail sampling).
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	)
	otel.SetTracerProvider(tp)
	// W3C Trace Context: the traceparent header (HTTP), metadata (gRPC) and
	// Kafka header that carry the trace from one service to the next.
	//
	// Baggage is left out on purpose: it would accept arbitrary key-value pairs
	// from any caller of the channel-facing REST API and forward them to every
	// service downstream. A public edge (API gateway, the first service behind
	// it) often also ignores an incoming traceparent and starts a new trace, so
	// an outside caller cannot pick trace IDs or force sampling.
	otel.SetTextMapPropagator(propagation.TraceContext{})

	logExp, err := otlploggrpc.New(ctx, otlploggrpc.WithEndpointURL(otlpEndpoint))
	if err != nil {
		return nil, fmt.Errorf("OTLP log exporter: %w", err)
	}
	lp := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)), sdklog.WithResource(res))

	// Every record goes to both: stdout for `docker logs` / `kubectl logs`,
	// OTLP for Loki, where a log line links to its trace.
	handler := newContextHandler(slog.NewMultiHandler(
		stdout, otelslog.NewHandler(serviceName, otelslog.WithLoggerProvider(lp))))
	return &Telemetry{Logger: slog.New(handler), tp: tp, lp: lp}, nil
}

// Shutdown flushes the spans and logs still buffered. Call it last, after
// everything that logs has stopped.
func (t *Telemetry) Shutdown(ctx context.Context) error {
	return errors.Join(t.tp.Shutdown(ctx), t.lp.Shutdown(ctx))
}
```

Empat hal perlu diperhatikan. _Propagator_ hanya berisi `propagation.TraceContext{}`, sehingga yang berpindah antar-service hanya `traceparent` (dan `tracestate` bila ada): di _header_ HTTP, _metadata_ gRPC, _header_ Kafka, dan kolom `trace_context` di tabel `outbox`. _Baggage_ (W3C _Baggage_, pasangan _key-value_ bebas yang ikut berpindah bersama _trace_) sengaja tidak dipasang. REST API `transfer` dipanggil aplikasi _channel_ dari luar, sehingga _baggage_ dari pemanggil luar akan diteruskan ke setiap service di belakangnya. Di _production_, _public edge_ (API _gateway_ atau service pertama di belakangnya) sering juga mengabaikan `traceparent` dari luar dan memulai _trace_ baru, agar pemanggil luar tidak dapat menentukan _trace ID_ atau memaksa _sampling_. Lab ini tetap menerima `traceparent` dari pemanggil agar peserta dapat mengikuti satu _trace_.

`slog.NewMultiHandler` (tersedia sejak Go 1.26) meneruskan setiap _record_ ke dua _handler_ sekaligus: _stdout_ untuk `docker logs` atau `kubectl logs`, dan `otelslog` untuk Loki. _Sampler_ `AlwaysSample` menyimpan semua _trace_, cocok untuk lab dengan beberapa _request_ per detik; di _production_ biaya penyimpanan _trace_ bisa melebihi biaya service itu sendiri bila semua disimpan. Terakhir, `Shutdown` harus dipanggil paling akhir agar _span_ dan log dari proses _shutdown_ ikut terkirim.

==== `log.go`: ID di setiap baris log

`slog.Handler` dapat dibungkus untuk menambah atribut dari _context_. Dengan pembungkus ini, kode bisnis cukup memanggil `log.InfoContext(ctx, ...)`, dan `correlation_id`, `trace_id`, serta `span_id` ditambahkan otomatis. Buat `transfer/internal/telemetry/log.go`:

```go
package telemetry

import (
	"context"
	"log/slog"

	"go.opentelemetry.io/otel/trace"
)

// contextHandler adds correlation_id, trace_id and span_id from the context
// to every record. Only records logged WITH a context get them: inside
// request handling, use log.InfoContext(ctx, ...), not log.Info(...).
type contextHandler struct {
	slog.Handler
}

func newContextHandler(h slog.Handler) slog.Handler { return contextHandler{h} }

func (h contextHandler) Handle(ctx context.Context, r slog.Record) error {
	if id := CorrelationID(ctx); id != "" {
		r.AddAttrs(slog.String("correlation_id", id))
	}
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()))
	}
	return h.Handler.Handle(ctx, r)
}

func (h contextHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return contextHandler{h.Handler.WithAttrs(attrs)}
}

func (h contextHandler) WithGroup(name string) slog.Handler {
	return contextHandler{h.Handler.WithGroup(name)}
}
```

`WithAttrs` dan `WithGroup` wajib dibungkus ulang. Tanpa keduanya, _logger_ hasil `log.With(...)` kembali ke _handler_ asli dan kehilangan ID.

==== `correlation.go`: _correlation ID_ di HTTP dan gRPC

_Correlation ID_ dari luar adalah _input_ pemanggil yang akan muncul di setiap baris log. Karena itu panjangnya dibatasi dan karakternya dibatasi ke `A-Z a-z 0-9 . _ : -`. Nilai yang tidak memenuhi pola diganti UUID baru. Buat `transfer/internal/telemetry/correlation.go`:

```go
package telemetry

import (
	"context"
	"net/http"
	"regexp"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// The correlation ID is a business-level ID the caller can quote; the trace
// ID is the technical one. Both end up in every log line.
const (
	CorrelationHeader = "X-Correlation-ID"
	// gRPC metadata keys are lower case.
	CorrelationMetadataKey = "x-correlation-id"
	// Kafka header, next to event_type and event_id.
	CorrelationKafkaHeader = "correlation_id"
)

type correlationKey struct{}

func WithCorrelationID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, correlationKey{}, id)
}

// CorrelationID is "" when ctx has none.
func CorrelationID(ctx context.Context) string {
	id, _ := ctx.Value(correlationKey{}).(string)
	return id
}

// An incoming ID is caller input that ends up in every log line: bounded in
// length and restricted to characters that cannot fake log fields.
var correlationPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,100}$`)

// AcceptCorrelationID returns id when it is acceptable, otherwise a new one.
func AcceptCorrelationID(id string) string {
	if correlationPattern.MatchString(id) {
		return id
	}
	return uuid.NewString()
}

// CorrelationMiddleware takes X-Correlation-ID from the request or generates
// one, stores it in the context, echoes it in the response, and tags the
// server span with it, so Tempo finds the trace by correlation ID.
func CorrelationMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := AcceptCorrelationID(r.Header.Get(CorrelationHeader))
		w.Header().Set(CorrelationHeader, id)
		trace.SpanFromContext(r.Context()).SetAttributes(attribute.String("correlation.id", id))
		next.ServeHTTP(w, r.WithContext(WithCorrelationID(r.Context(), id)))
	})
}

// UnaryClientCorrelation sends the context's correlation ID to the called
// service as gRPC metadata. The trace context needs no code here: the otelgrpc
// stats handler sends it (traceparent).
func UnaryClientCorrelation() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn,
		invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		if id := CorrelationID(ctx); id != "" {
			ctx = metadata.AppendToOutgoingContext(ctx, CorrelationMetadataKey, id)
		}
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}
```

Atribut _span_ `correlation.id` membuat _trace_ dapat dicari di Tempo dengan _correlation ID_ yang dilaporkan pemanggil.

==== `http.go`: _metric_ dan _span_ per _route_

_Metric_ durasi _request_ diberi _label_ `method`, `route`, dan `status`. Isi `route` adalah _pattern_ ServeMux (`/transfers/{id}`), tidak boleh _path_ lengkap (`/transfers/8f3c...`). Setiap kombinasi nilai _label_ menjadi satu _time series_ di Prometheus. Bila _path_ lengkap dijadikan _label_, setiap ID transfer menambah satu _series_ baru, jumlahnya tumbuh tanpa batas, dan akhirnya Prometheus kehabisan memori. Masalah ini dikenal sebagai _high cardinality_.

ServeMux menulis _pattern_ yang cocok ke `r.Pattern` pada `*http.Request` yang diterimanya. Nilai tersebut hanya terbaca bila pembungkus `route` menerima objek `*http.Request` yang sama dengan yang diproses ServeMux, sehingga `route` harus membungkus _mux_ secara langsung, tanpa _middleware_ lain yang memanggil `r.WithContext` di antaranya. Buat `transfer/internal/telemetry/http.go`:

```go
package telemetry

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// requestDuration is the RED metric of the HTTP API: rate (count), errors
// (status), duration. route is the ServeMux pattern, never the raw path.
var requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
	Name:    "http_server_request_duration_seconds",
	Help:    "Duration of HTTP requests handled by this service.",
	Buckets: prometheus.DefBuckets, // 5 ms .. 10 s
}, []string{"method", "route", "status"})

// HTTPHandler wraps the service's mux, outermost first:
//
//  1. otelhttp: server span, continues the caller's trace from traceparent
//  2. correlation ID
//  3. route: metrics and span name by the matched route pattern
//
// Probes and /metrics are not traced: they are called every few seconds,
// and those traces would bury the real ones.
func HTTPHandler(mux http.Handler) http.Handler {
	return otelhttp.NewHandler(CorrelationMiddleware(route(mux)), "http",
		otelhttp.WithFilter(func(r *http.Request) bool {
			switch r.URL.Path {
			case "/healthz", "/readyz", "/metrics":
				return false
			}
			return true
		}))
}

// route must wrap the mux directly: ServeMux writes the matched pattern into
// the *Request it routes (r.Pattern).
func route(mux http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		mux.ServeHTTP(rec, r)

		// "GET /transfers/{id}" -> "/transfers/{id}"; the method is its own label.
		pattern := r.Pattern
		if _, path, ok := strings.Cut(pattern, " "); ok {
			pattern = path
		}
		if pattern == "" {
			pattern = "unmatched" // 404 from the mux: one series, whatever the path
		}
		requestDuration.WithLabelValues(method(r.Method), pattern, strconv.Itoa(rec.status)).
			Observe(time.Since(start).Seconds())

		span := trace.SpanFromContext(r.Context())
		span.SetName(r.Method + " " + pattern)
		span.SetAttributes(attribute.String("http.route", pattern))
	})
}

// method bounds the label: any token is a valid HTTP method on the wire.
func method(m string) string {
	switch m {
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete,
		http.MethodPatch, http.MethodHead, http.MethodOptions:
		return m
	}
	return "OTHER"
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController reach the real writer.
func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }
```

Fungsi `method` juga membatasi nilai _label_: metode HTTP di jaringan dapat berupa token apa pun, sehingga metode di luar daftar digabung menjadi `OTHER`. Nama _span_ diubah dari `http` menjadi `POST /transfers` agar mudah dibaca di Tempo.

==== `kafka.go`: _trace context_ di _header_ Kafka

`kafka-go` tidak memiliki instrumentasi OpenTelemetry. _Propagator_ OpenTelemetry menulis dan membaca _trace context_ lewat antarmuka `TextMapCarrier` (`Get`, `Set`, `Keys`), sehingga cukup dibuat adaptor dari `[]kafka.Header` ke antarmuka tersebut. Buat `transfer/internal/telemetry/kafka.go`:

```go
package telemetry

import (
	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel/propagation"
)

// KafkaHeaders lets the OpenTelemetry propagator write the trace context
// (traceparent, tracestate) into Kafka message headers, the way otelhttp and
// otelgrpc write it into HTTP headers and gRPC metadata.
type KafkaHeaders struct {
	Headers *[]kafka.Header
}

var _ propagation.TextMapCarrier = KafkaHeaders{}

func (c KafkaHeaders) Get(key string) string {
	for _, h := range *c.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}

func (c KafkaHeaders) Set(key, value string) {
	for i, h := range *c.Headers {
		if h.Key == key {
			(*c.Headers)[i].Value = []byte(value)
			return
		}
	}
	*c.Headers = append(*c.Headers, kafka.Header{Key: key, Value: []byte(value)})
}

func (c KafkaHeaders) Keys() []string {
	keys := make([]string, len(*c.Headers))
	for i, h := range *c.Headers {
		keys[i] = h.Key
	}
	return keys
}
```

=== Memasang Telemetri di `transfer/main.go`

Sebelum konfigurasi terbaca, alamat _collector_ belum diketahui. Karena itu `main` membuat _logger_ JSON sederhana ke _stdout_ untuk log kesalahan _startup_. Ganti baris pertama `main`:

```go
	// Until the configuration is read there is no collector address: startup
	// errors go to stdout only, as JSON like every later log line.
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
```

Di `run`, tepat setelah `signal.NotifyContext` dan sebelum `transfer.NewPostgresStore`, siapkan telemetri lalu ganti `log` dengan _logger_ baru:

```go
	// Lab 8: from here on, log lines also go to the collector (OTLP) and carry
	// correlation_id / trace_id when logged with a request context.
	tel, err := telemetry.Setup(ctx, cfg.OTelServiceName, cfg.OTelEndpoint)
	if err != nil {
		return err
	}
	// Deferred first, so it runs last: spans and logs of the shutdown itself
	// are flushed too.
	defer func(boot *slog.Logger) {
		flushCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tel.Shutdown(flushCtx); err != nil {
			boot.Warn("flushing telemetry failed", "error", err)
		}
	}(log)
	log = tel.Logger
```

Pengambilan _token_ OAuth2 ke Hydra juga dijadikan _span_. Transfer pertama setelah service dijalankan ulang lebih lambat karena harus mengambil _token_, dan _span_ ini menunjukkan penyebabnya. Ganti pemanggilan `accountclient.New`:

```go
	// Its HTTP call to the authorization server becomes a span of the transfer's
	// trace: a slow first transfer after a restart shows why.
	tokenHTTP := &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}
	fetchToken := func(ctx context.Context) (*oauth2.Token, error) {
		return tokenCfg.Token(context.WithValue(ctx, oauth2.HTTPClient, tokenHTTP))
	}
	accounts, err := accountclient.New(cfg.AccountGRPCAddr, accountclient.ProductionSettings, fetchToken, log)
```

Daftarkan `/metrics` setelah `/debug/circuit-breaker`, lalu bungkus _mux_ dengan `telemetry.HTTPHandler`:

```go
	// Lab 8: Prometheus pulls the metrics from here. Open like the probes;
	// production restricts it to the monitoring network.
	mux.Handle("GET /metrics", promhttp.Handler())
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           telemetry.HTTPHandler(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}
```

_Relay outbox_ kini menerima nama _topic_ untuk menamai _span_-nya (perubahan `NewRelay` ada di langkah _outbox_):

```go
		outbox.NewRelay(store.Pool(), writer, cfg.KafkaTopic, log).Run(relayCtx)
```

Log `transfer service listening` mendapat atribut `"otlp_endpoint", cfg.OTelEndpoint` agar alamat _collector_ terlihat saat _startup_.

Tambahkan _import_ `promhttp`, `otelhttp`, `golang.org/x/oauth2`, dan paket `telemetry`:

```go
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"golang.org/x/oauth2"
	...
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/telemetry"
```

=== Telemetri pada Client gRPC dan _Circuit Breaker_

Di `transfer/internal/accountclient/client.go`, client gRPC mendapat tiga tambahan. _Interceptor_ `UnaryClientCorrelation` ditaruh paling depan di rantai _interceptor_ agar _correlation ID_ ditambahkan satu kali, sebelum _token_ dan kebijakan _resiliency_. `otelgrpc.NewClientHandler` dipasang sebagai _stats handler_, sehingga setiap percobaan, termasuk setiap _retry_, menjadi satu _span_ tersendiri. Kedua opsi ini ditambahkan di fungsi `dial`, sehingga berlaku untuk koneksi utama (`Debit`, `Credit`) maupun koneksi _reversal_ dari Lab 5. Ganti bagian opsi di `dial`:

```go
		grpc.WithPerRPCCredentials(tokens),
		// First interceptor = outermost: a call repeated with a new token goes
		// through the resiliency policies again. The correlation ID is added once,
		// before all of them.
		grpc.WithChainUnaryInterceptor(telemetry.UnaryClientCorrelation(),
			tokens.refreshOnUnauthenticated, resilience),
		// Lab 8: one client span per attempt, so retries and timeouts are visible
		// in the trace, and the trace context sent along in the metadata.
		grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
```

Status _circuit breaker_ dicatat dalam dua _metric_. _Gauge_ `circuit_breaker_state` menyimpan status sebagai angka agar dapat digambar sebagai grafik dan dijadikan dasar _alert_. _Counter_ `circuit_breaker_transitions_total` menghitung perpindahan status. _Counter_ ini dibutuhkan karena _circuit breaker_ yang berpindah `open` lalu `closed` di antara dua _scrape_ tidak pernah terlihat di _gauge_. Tambahkan di atas `type Settings`:

```go
// Breaker metrics (Lab 8). The state as a number so Grafana can graph it and
// alert on it; transitions as a counter, because a breaker that flaps between
// open and closed within one scrape interval never shows up in the gauge.
var (
	breakerState = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "circuit_breaker_state",
		Help: "Circuit breaker state per target: 0 closed, 1 half-open, 2 open.",
	}, []string{"target"})
	breakerTransitions = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "circuit_breaker_transitions_total",
		Help: "Circuit breaker state changes per target.",
	}, []string{"target", "from", "to"})
)

// stateValue maps the breaker state to the circuit_breaker_state value.
func stateValue(s circuitbreaker.State) float64 {
	switch s {
	case circuitbreaker.HalfOpenState:
		return 1
	case circuitbreaker.OpenState:
		return 2
	}
	return 0
}
```

Perbarui kedua _metric_ di `OnStateChanged` dan isi nilai awal _gauge_ setelah `Build()`:

```go
		OnStateChanged(func(e circuitbreaker.StateChangedEvent) {
			// No request context: the change belongs to the breaker, not to the
			// call that happened to trigger it.
			log.Warn("circuit breaker state changed", "target", "account",
				"from", e.OldState.String(), "to", e.NewState.String())
			breakerState.WithLabelValues("account").Set(stateValue(e.NewState))
			breakerTransitions.WithLabelValues("account", e.OldState.String(), e.NewState.String()).Inc()
		}).
		Build()
	breakerState.WithLabelValues("account").Set(stateValue(breaker.State()))
```

Log _retry_ di kedua kebijakan diubah menjadi `WarnContext` dengan _context_ percobaan, agar baris log tersebut muncul di bawah _trace_ transfer yang sama. Di kebijakan `retry`:

```go
		OnRetry(func(e failsafe.ExecutionEvent[any]) {
			log.WarnContext(e.Context(), "retrying account call",
				"next_attempt", e.Attempts(), "cause", e.LastError())
		}).
```

Di kebijakan `reversalRetry`:

```go
		OnRetry(func(e failsafe.ExecutionEvent[any]) {
			log.WarnContext(e.Context(), "retrying reversal", "next_attempt",
				e.Attempts(), "elapsed", e.ElapsedTime(), "cause", e.LastError())
		}).
```

_Import_ yang ditambahkan: `prometheus`, `promauto`, `otelgrpc`, dan paket `telemetry` milik `transfer`.

=== _Metric_ Bisnis dan Atribut _Span_ Transfer

_Metric_ HTTP menunjukkan kesehatan pemrosesan _request_, sedangkan `transfers_total` menunjukkan hasil transfer dana. Kenaikan jumlah `COMPENSATED` atau `FAILED` adalah insiden bisnis, walaupun setiap _request_ dijawab dengan cepat. Buat `transfer/internal/transfer/metrics.go`:

```go
package transfer

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// transfersTotal counts saga outcomes by end state (Lab 8).
var transfersTotal = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "transfers_total",
	Help: "Transfers that reached an end state, by status.",
}, []string{"status"})

// Every status starts at 0. A series that first appears with the value 5 shows
// no increase to rate(): the first transfers after a start would be missing
// from the dashboard.
func init() {
	for _, s := range []Status{Completed, Failed, Compensated, CompensationFailed} {
		transfersTotal.WithLabelValues(string(s))
	}
}
```

Fungsi `init` menyiapkan setiap status dengan nilai 0. Fungsi `rate()` di Prometheus menghitung kenaikan antara dua sampel. _Series_ yang baru muncul dengan nilai 5 tidak memiliki sampel sebelumnya, sehingga lima transfer pertama tidak pernah terlihat di grafik.

Di `transfer/internal/transfer/service.go`, `finish` menaikkan _counter_ dan menandai _span_ _request_ dengan status akhir, tepat setelah pemeriksaan `err` dari `s.store.Transition`:

```go
	transfersTotal.WithLabelValues(string(to)).Inc()
	trace.SpanFromContext(ctx).SetAttributes(attribute.String("transfer.status", string(to)))
```

Di `Execute`, setelah transfer tercatat dan sebelum pemeriksaan `!created`, tandai _span_ dengan ID transfer:

```go
	// Tags the request's span: Tempo finds the trace of a transfer by its ID,
	// e.g. TraceQL {span.transfer.id="<id>"}.
	trace.SpanFromContext(ctx).SetAttributes(attribute.String("transfer.id", t.ID))
```

Tambahkan _import_ `go.opentelemetry.io/otel/attribute` dan `go.opentelemetry.io/otel/trace`. Kedua atribut ini memungkinkan pencarian di Tempo dengan `{ span.transfer.status = "FAILED" }` atau `{ span.transfer.id = "<id>" }`.

=== Log dengan _Context_

`contextHandler` hanya dapat menambahkan ID bila _context_ ikut dikirim. Ubah setiap pemanggilan log di dalam penanganan _request_ menjadi varian `...Context`:

```go
// sebelum
s.log.Info("transfer completed", "transfer_id", t.ID, "amount", t.Amount)
// sesudah
s.log.InfoContext(ctx, "transfer completed", "transfer_id", t.ID, "amount", t.Amount)
```

Lokasi yang perlu diubah di `transfer`: semua log di `internal/transfer/service.go` (`Execute`, `run`, `compensate`, `finish`), `internalError` dan `readyz` di `internal/transfer/http.go` (dengan `r.Context()`), serta ketiga log `request rejected` di `internal/auth/http.go`. Log yang terjadi di luar _request_, misalnya `transfer service listening` atau perubahan status _circuit breaker_, tetap menggunakan `log.Info` atau `log.Warn`.

=== _Outbox_: Meneruskan _Trace_ Melewati Kafka

Langkah ini menyambung _trace_ dari `transfer` ke `notification`. Tambahkan dua kolom di akhir `transfer/internal/transfer/schema.sql`:

```sql
-- Observability (Lab 8): the correlation ID and the trace context
-- (traceparent, tracestate) of the request that wrote the event. The relay
-- runs later, outside that request; it reads both from here.
alter table outbox add column if not exists correlation_id varchar(100);
alter table outbox add column if not exists trace_context jsonb;
```

Di `transfer/internal/outbox/outbox.go`, `Message` mendapat dua _field_ untuk kedua kolom tersebut, di akhir `struct` setelah `Payload`:

```go
	// CorrelationID and TraceContext belong to the request that wrote the row
	// (Lab 8). Insert takes them from its ctx.
	CorrelationID string
	TraceContext  map[string]string
```

`Insert` mengambil _trace context_ dari `ctx` dengan _propagator_ ke sebuah `MapCarrier` (isinya `traceparent` dan, bila ada, `tracestate`), lalu menyimpannya bersama _correlation ID_. pgx menyimpan `map[string]string` ke kolom `jsonb` secara langsung.

```go
func Insert(ctx context.Context, tx pgx.Tx, m Message) error {
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	_, err := tx.Exec(ctx, `
		insert into outbox (id, aggregate_id, event_type, payload, correlation_id, trace_context)
		values (@id, @aggregate_id, @event_type, @payload, nullif(@correlation_id, ''), @trace_context)`,
		pgx.NamedArgs{"id": m.ID, "aggregate_id": m.AggregateID, "event_type": m.EventType,
			"payload": m.Payload, "correlation_id": telemetry.CorrelationID(ctx),
			"trace_context": map[string]string(carrier)})
	if err != nil {
		return fmt.Errorf("insert outbox message: %w", err)
	}
	return nil
}
```

`Relay` mendapat _field_ `topic` dan `tracer`:

```go
type Relay struct {
	pool   *pgxpool.Pool
	pub    Publisher
	topic  string
	tracer trace.Tracer
	log    *slog.Logger
}

// NewRelay takes topic only to name the spans; pub decides where messages go.
func NewRelay(pool *pgxpool.Pool, pub Publisher, topic string, log *slog.Logger) *Relay {
	return &Relay{pool: pool, pub: pub, topic: topic, tracer: otel.Tracer("transfer/outbox"), log: log}
}
```

_Query_ di `publishBatch` membaca kedua kolom baru. `coalesce` menangani baris lama dari Lab 5 hingga Lab 7 yang belum memiliki kolom tersebut:

```go
	rows, err := tx.Query(ctx, `
		select id::text, aggregate_id::text, event_type, payload,
		       coalesce(correlation_id, ''), coalesce(trace_context, '{}'::jsonb)
		from outbox
		...
```

Baris hasil _query_ diubah menjadi `Message` dengan `pgx.RowToStructByPos`, yang mencocokkan kolom dengan _field_ berdasarkan urutan. Karena itu `CorrelationID` dan `TraceContext` harus berada di akhir `struct` `Message`, sesuai urutan kolom di `select`.

Fungsi baru `message` membuat _span_ `publish transfer-events` dengan _parent_ dari _trace context_ yang tersimpan, lalu menulis _context_ milik _span_ tersebut ke _header_ Kafka. Dengan begitu _span_ di `notification` menjadi _child_ dari _span_ `publish`:

```go
// message builds the Kafka message for m and starts its "publish" span as a
// child of the request that wrote m. The caller ends the span once Kafka has
// acknowledged the message.
func (r *Relay) message(ctx context.Context, m Message) (kafka.Message, trace.Span) {
	parent := otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(m.TraceContext))
	spanCtx, span := r.tracer.Start(parent, "publish "+r.topic,
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.operation.type", "send"),
			attribute.String("messaging.destination.name", r.topic),
			attribute.String("messaging.message.id", m.ID),
			attribute.String("messaging.kafka.message.key", m.AggregateID),
			attribute.String("event.type", m.EventType),
		))

	headers := []kafka.Header{
		{Key: "event_type", Value: []byte(m.EventType)},
		{Key: "event_id", Value: []byte(m.ID)},
	}
	if m.CorrelationID != "" {
		headers = append(headers, kafka.Header{Key: telemetry.CorrelationKafkaHeader, Value: []byte(m.CorrelationID)})
	}
	otel.GetTextMapPropagator().Inject(spanCtx, telemetry.KafkaHeaders{Headers: &headers})
	return kafka.Message{Key: []byte(m.AggregateID), Value: m.Payload, Headers: headers}, span
}
```

Di `publishBatch`, ganti pembuatan `kafka.Message` di dalam _loop_ dengan `message`, lalu akhiri _span_ setelah Kafka menerima _batch_. _Span_ dari _batch_ yang gagal sengaja tidak diakhiri, sehingga tidak pernah dikirim. Selama Kafka mati, _batch_ yang sama gagal setiap 500 ms; bila _span_ tersebut diakhiri, setiap _trace_ transfer yang menunggu akan mendapat satu _span_ gagal tambahan per percobaan.

```go
	spans := make([]trace.Span, len(pending))
	for i, m := range pending {
		msgs[i], spans[i] = r.message(ctx, m)
		ids[i] = m.ID
	}
	pubCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := r.pub.WriteMessages(pubCtx, msgs...); err != nil {
		// The spans of a failed batch are not ended, so they are never exported.
		return 0, fmt.Errorf("publish %d events: %w", len(msgs), err)
	}
	for _, span := range spans {
		span.End()
	}
```

Bagian akhir `publishBatch`, setelah `update outbox set published_at`, kini memeriksa `Commit` lalu menulis satu log per _event_ di dalam _trace_ _event_ tersebut:

```go
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	// One line per event, in the event's own trace: Loki shows it under the
	// transfer's trace next to the log lines of the other services.
	for i, m := range pending {
		evCtx := telemetry.WithCorrelationID(trace.ContextWithSpan(ctx, spans[i]), m.CorrelationID)
		r.log.InfoContext(evCtx, "event published", "event_id", m.ID,
			"event_type", m.EventType, "transfer_id", m.AggregateID)
	}
	return len(pending), nil
```

Terakhir, _gauge_ `outbox_pending` mencatat jumlah baris yang belum terkirim. Nilainya normal 0 atau mendekati 0. Nilai yang terus naik berarti Kafka tidak dapat dihubungi atau _relay_ macet, dan semua notifikasi tertunda. Tambahkan di atas `type Message`:

```go
// pendingGauge is the backlog of the relay.
var pendingGauge = promauto.NewGauge(prometheus.GaugeOpts{
	Name: "outbox_pending",
	Help: "Outbox events not yet published to Kafka.",
})
```

Ubah _loop_ di `Run` agar menghitung antrean setelah setiap _batch_, termasuk setelah _batch_ yang gagal:

```go
		n, err := r.publishBatch(ctx)
		switch {
		case err != nil && ctx.Err() == nil:
			r.log.Warn("outbox publish failed, will retry", "error", err)
		case n > 0:
			r.log.Info("outbox events published", "count", n)
		}
		// After a failure too: a growing backlog while Kafka is down is exactly
		// what the gauge is for.
		r.updatePending(ctx)
	}
}

func (r *Relay) updatePending(ctx context.Context) {
	var n int64
	// Cheap: the partial index outbox_unpublished holds only unpublished rows.
	if err := r.pool.QueryRow(ctx, `select count(*) from outbox where published_at is null`).Scan(&n); err != nil {
		if ctx.Err() == nil {
			r.log.Warn("counting pending outbox events failed", "error", err)
		}
		return
	}
	pendingGauge.Set(float64(n))
}
```

_Import_ yang ditambahkan: `prometheus`, `promauto`, `go.opentelemetry.io/otel`, `.../otel/attribute`, `.../otel/propagation`, `.../otel/trace`, dan paket `telemetry`. Ambil _unit test_ `transfer` dari _checkpoint_, lalu jalankan pengujian untuk memastikan semua bagian tersambung. `go mod tidy` dijalankan setelah _test_ diambil agar _dependency_ yang hanya digunakan oleh _test_ ikut tercatat di `go.sum`:

#perintah[```bash
git checkout lab-08 -- \
  transfer/config_test.go \
  transfer/internal/telemetry/telemetry_test.go \
  transfer/internal/outbox/outbox_test.go \
  transfer/internal/accountclient/client_test.go \
  transfer/internal/transfer/service_test.go
cd transfer && go mod tidy && make test && cd ..
```]

=== Telemetri di `account`

Salin paket dari `transfer`, kecuali `kafka.go` karena `account` tidak menggunakan Kafka:

#perintah[```bash
mkdir -p account/internal/telemetry
cp transfer/internal/telemetry/{telemetry.go,log.go,correlation.go,http.go} account/internal/telemetry/
```]

Di `account/internal/telemetry/correlation.go`, hapus konstanta `CorrelationKafkaHeader` dan ganti `UnaryClientCorrelation` dengan versi server. _Trace context_ tidak membutuhkan kode di sini, karena _stats handler_ `otelgrpc` sudah membacanya dan memulai _span_ server sebelum _interceptor_ berjalan.

```go
// UnaryServerCorrelation is the gRPC counterpart of CorrelationMiddleware: the
// ID comes from the x-correlation-id metadata the transfer service sends. It
// runs first in the chain, so every later interceptor logs with the ID.
func UnaryServerCorrelation() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		var incoming string
		if md, ok := metadata.FromIncomingContext(ctx); ok {
			if v := md.Get(CorrelationMetadataKey); len(v) > 0 {
				incoming = v[0]
			}
		}
		id := AcceptCorrelationID(incoming)
		trace.SpanFromContext(ctx).SetAttributes(attribute.String("correlation.id", id))
		return handler(WithCorrelationID(ctx, id), req)
	}
}
```

Pekerjaan utama `account` berjalan lewat gRPC. Tanpa _metric_ gRPC, `Debit` yang lambat tidak muncul di _metric_ latensi mana pun milik `account`. Buat `account/internal/interceptor/metrics.go`:

```go
package interceptor

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
)

// requestDuration is the gRPC counterpart of http_server_request_duration_seconds
// (Lab 8). method is the full method name: a fixed set, defined by the proto
// contract.
var requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
	Name:    "grpc_server_request_duration_seconds",
	Help:    "Duration of unary gRPC calls handled by this service.",
	Buckets: prometheus.DefBuckets, // 5 ms .. 10 s
}, []string{"method", "code"})

// Metrics observes every unary call with its status code. It runs before auth
// and the fault injector, so rejected calls and injected delays are measured
// like the caller experiences them.
func Metrics() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		requestDuration.WithLabelValues(info.FullMethod, status.Code(err).String()).
			Observe(time.Since(start).Seconds())
		return resp, err
	}
}
```

_Fault injection_ di `account/internal/fault/fault.go` menambah _span event_ agar gangguan simulasi dapat dibedakan dari gangguan sebenarnya di Tempo. Service yang benar-benar lambat muncul sebagai _span_ panjang tanpa _event_ tersebut. Ganti fungsi `inject`:

```go
func (i *Injector) inject(ctx context.Context) bool {
	cfg := i.cfg.Load()
	// Lab 8: the span events tell a simulated fault from a real one in the trace.
	span := trace.SpanFromContext(ctx)
	if cfg.DelayMS > 0 {
		// Recorded before the wait: the caller usually gives up during it.
		span.AddEvent("fault injected: delay",
			trace.WithAttributes(attribute.Int("fault.delay_ms", cfg.DelayMS)))
		select {
		case <-time.After(time.Duration(cfg.DelayMS) * time.Millisecond):
		case <-ctx.Done():
			return false
		}
	}
	failed := cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate
	if failed {
		span.AddEvent("fault injected: error",
			trace.WithAttributes(attribute.Float64("fault.error_rate", cfg.ErrorRate)))
	}
	return failed
}
```

Di `account/main.go`, lakukan perubahan yang sama dengan `transfer`: _logger_ JSON di `main`, `telemetry.Setup` beserta `defer` `Shutdown`, `GET /metrics` setelah `faults.Register(mux)`, dan `Handler: telemetry.HTTPHandler(mux)`. Server gRPC mendapat _stats handler_ dan dua _interceptor_ baru di depan rantai:

```go
	grpcSrv := grpc.NewServer(
		// Lab 8: continues the caller's trace (traceparent in the metadata) with
		// one server span per call. A stats handler, not an interceptor: it sees
		// the call before the interceptors run, and the span covers them all,
		// fault delays included.
		grpc.StatsHandler(otelgrpc.NewServerHandler()),
		grpc.ChainUnaryInterceptor(
			telemetry.UnaryServerCorrelation(),
			interceptor.Metrics(),
			interceptor.Logging(log),
			auth.UnaryServerInterceptor(verifier, account.GRPCScopes, notAccountService, log),
			faults.UnaryServerInterceptor(notAccountService),
		))
```

Urutan rantai ini menentukan hasil pengukuran. `UnaryServerCorrelation` berada paling depan agar semua _interceptor_ berikutnya menulis log dengan _correlation ID_. `Metrics` berada sebelum `auth` dan _fault injector_, sehingga durasi yang tercatat mencakup penolakan dan _delay_ simulasi, sama seperti yang dialami pemanggil.

Ubah juga log di dalam penanganan _request_ menjadi varian `...Context`: `mutate` dan `toStatus` di `internal/account/grpc.go`, termasuk log `caller gave up before the request finished` dari Lab 4. `toStatus` kini menerima `ctx` sebagai parameter pertama, sehingga semua pemanggilnya ikut diubah, termasuk jalur kesalahan `parseAmount` di awal `mutate` (`s.toStatus(ctx, err)`). Lakukan hal yang sama pada ketiga log `grpc call rejected` dan log `no scope configured` di `internal/auth/grpc.go`, serta log di `internalError` dan `readyz` pada `internal/account/http.go`. `interceptor.Logging` sudah memanggil `log.Log(ctx, ...)`, sehingga tidak perlu diubah.

Ambil _unit test_ `account` dari _checkpoint_, lalu jalankan pengujian:

#perintah[```bash
git checkout lab-08 -- \
  account/config_test.go \
  account/internal/telemetry/correlation_test.go \
  account/internal/interceptor/metrics_test.go
cd account && go mod tidy && make test && cd ..
```]

=== Telemetri di `notification`

`notification` tidak menggunakan gRPC. Salin paket dari `transfer`, termasuk `kafka.go`:

#perintah[```bash
mkdir -p notification/internal/telemetry
cp transfer/internal/telemetry/{telemetry.go,log.go,correlation.go,http.go,kafka.go} notification/internal/telemetry/
```]

Di `notification/internal/telemetry/correlation.go`, hapus `CorrelationMetadataKey` dan `UnaryClientCorrelation` beserta _import_ `grpc` dan `metadata`. Di `notification/main.go`, lakukan perubahan yang sama dengan `transfer`. Karena `Routes()` mengembalikan `*http.ServeMux`, `/metrics` dapat didaftarkan langsung:

```go
	mux := notification.NewHandler(store, log).Routes()
	// Lab 8: Prometheus pulls the metrics from here. Open like the probes;
	// production restricts it to the monitoring network.
	mux.Handle("GET /metrics", promhttp.Handler())
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           telemetry.HTTPHandler(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}
```

_Consumer_ membaca _trace context_ dan _correlation ID_ dari _header_ Kafka, lalu memproses _event_ di dalam _span_ `process transfer-events`. Di `notification/internal/notification/consumer.go`, tambahkan _field_ `tracer trace.Tracer` di `Consumer`, isi di `NewConsumer` dengan `otel.Tracer("notification/consumer")`, dan ganti `c.handle(ctx, m)` di `Run` menjadi `c.process(ctx, m)`. Fungsi `process`:

```go
// process handles m inside a "process" span that continues the trace of the
// transfer: the outbox relay put the trace context (traceparent) and the
// correlation ID into the Kafka headers.
func (c *Consumer) process(ctx context.Context, m kafka.Message) error {
	headers := m.Headers
	ctx = otel.GetTextMapPropagator().Extract(ctx, telemetry.KafkaHeaders{Headers: &headers})
	ctx = telemetry.WithCorrelationID(ctx,
		telemetry.AcceptCorrelationID(header(m, telemetry.CorrelationKafkaHeader)))
	ctx, span := c.tracer.Start(ctx, "process "+m.Topic,
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.operation.type", "process"),
			attribute.String("messaging.destination.name", m.Topic),
			attribute.Int("messaging.destination.partition.id", m.Partition),
			attribute.Int64("messaging.kafka.offset", m.Offset),
			attribute.String("messaging.message.id", header(m, "event_id")),
			attribute.String("correlation.id", telemetry.CorrelationID(ctx)),
		))
	defer span.End()
	err := c.handle(ctx, m)
	if err != nil {
		span.SetStatus(codes.Error, "stopped before the event was handled")
	}
	return err
}
```

`codes` di sini adalah `go.opentelemetry.io/otel/codes`. Hasil pemrosesan dihitung dengan `notifications_processed_total`. Tambahkan di atas `type Reader`:

```go
// processed counts every event the consumer finished with (Lab 8):
//
//	sent       notification stored and sent
//	duplicate  event seen before, skipped (Lab 6); a burst after a replay or
//	           a rebalance is expected
//	skipped    unreadable, invalid, rejected by the database, or without a
//	           notification; should stay at 0
var processed = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "notifications_processed_total",
	Help: "Events handled by the notification consumer, by result.",
}, []string{"result"})

func init() {
	for _, r := range []string{"sent", "duplicate", "skipped"} {
		processed.WithLabelValues(r)
	}
}
```

Di `handle`, ambil _span_ dengan `span := trace.SpanFromContext(ctx)` di awal fungsi, lalu di setiap cabang hasil naikkan _counter_ yang sesuai dan ubah log menjadi varian `...Context`:

#table(
  columns: (1fr, 1fr),
  [Cabang di `handle`], [Tambahan],
  [_Payload_ tidak terbaca (`skipping unreadable event`)], [`processed.WithLabelValues("skipped").Inc()` dan `span.SetStatus(codes.Error, "unreadable event")`],
  [`event_id` atau `transfer_id` bukan UUID (`skipping event with invalid event_id or transfer_id`, Lab 5)], [`processed.WithLabelValues("skipped").Inc()` dan `span.SetStatus(codes.Error, "invalid event_id or transfer_id")`],
  [Setelah kedua ID lolos pemeriksaan], [`span.SetAttributes(attribute.String("transfer.id", e.TransferID))`],
  [Jenis _event_ tanpa notifikasi], [`processed.WithLabelValues("skipped").Inc()`],
  [Duplikat (`duplicate event skipped`)], [`processed.WithLabelValues("duplicate").Inc()` dan `span.SetAttributes(attribute.Bool("event.duplicate", true))`],
  [Berhasil (`notification sent`)], [`processed.WithLabelValues("sent").Inc()`],
  [Ditolak database, `permanentDBError` (`skipping event the database rejects`, Lab 5)], [`processed.WithLabelValues("skipped").Inc()` dan `span.SetStatus(codes.Error, "event rejected by the database")`],
)

Keempat cabang `skipped` mencatat _event_ yang dilewati tanpa notifikasi. Nilai normalnya 0. Kenaikan nilai ini berarti ada _event_ rusak yang perlu diperiksa dari log `ERROR`. Di _production_, _event_ seperti ini biasanya dikirim ke _dead-letter topic_ untuk diperiksa petugas.

Log di dalam _loop_ penyimpanan juga diubah: `skipping event the database rejects` menjadi `log.ErrorContext(ctx, ...)` dan `storing notification failed, retrying` menjadi `log.WarnContext(ctx, ...)`.

Ubah juga log `request failed` di `list` dan log di `readyz` pada `internal/notification/http.go` menjadi varian `...Context` (dengan `r.Context()`). Setelah itu ambil _unit test_ `notification` dari _checkpoint_ dan jalankan seluruh pengujian:

#perintah[```bash
git checkout lab-08 -- \
  notification/config_test.go \
  notification/internal/notification/tracing_test.go
cd notification && go mod tidy && make test && cd ..
make test
```]

=== Menelusuri Satu Transfer di Tempo

Jalankan ketiga service di tiga terminal, masing-masing dari folder `studi-kasus`:

#perintah[```bash
make -C account run
make -C transfer run
make -C notification run
```]

Kirim satu transfer dengan _correlation ID_ buatan sendiri:

#perintah[```bash
TOKEN=$(make -s token)
curl -s -i -X POST localhost:8082/transfers \
  -H "Authorization: Bearer $TOKEN" -H "X-Correlation-ID: lab8-1" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"1000"}'
```]

Respons membawa _correlation ID_ yang sama. Go menulis nama _header_ dalam _canonical form_ (huruf besar di awal setiap kata), sehingga yang tampil adalah `X-Correlation-Id`:

```
HTTP/1.1 201 Created
Content-Type: application/json
X-Correlation-Id: lab8-1
...

{"id":"...","from_account":"1111111111","to_account":"2222222222",
 "amount":"1000","status":"COMPLETED",...}
```

Log ketiga service kini berbentuk JSON, dan baris yang ditulis dengan _context_ milik _request_ atau _event_ membawa ID yang sama. Contoh berikut dipotong dan dipecah agar muat di halaman; di terminal setiap _record_ berupa satu baris:

```
account
{"level":"INFO","msg":"account mutated","number":"1111111111","type":"DEBIT",...,
 "correlation_id":"lab8-1","trace_id":"122d873a...","span_id":"c65886ff..."}
transfer
{"level":"INFO","msg":"transfer completed","transfer_id":"...","amount":"1000",
 "correlation_id":"lab8-1","trace_id":"122d873a...","span_id":"..."}
notification
{"level":"INFO","msg":"notification sent",...,
 "correlation_id":"lab8-1","trace_id":"122d873a...","span_id":"..."}
```

Di Grafana, buka _Explore_, pilih sumber data Tempo, lalu jalankan _query_ TraceQL berikut:

```
{ span.correlation.id = "lab8-1" }
```

_Trace_ yang muncul berisi _span_ dari ketiga service, dengan susunan seperti diagram di bagian Gambaran. Pencarian Tempo dapat tertinggal beberapa detik dari _request_. Membuka _trace_ langsung dengan `trace_id` dari baris log selalu berhasil seketika.

=== Latihan: Menemukan Service yang Lambat

Latihan ini mensimulasikan insiden: `account` menjadi lambat, dan tugas peserta adalah menemukan penyebabnya hanya dari _dashboard_, _trace_, dan log. Buka _dashboard_ _Studi Kasus: Transfer_ (Grafana → _Dashboards_ → _Studi Kasus_). _Dashboard_ diperbarui setiap 5 detik dan menampilkan 15 menit terakhir.

#table(
  columns: (auto, 1fr),
  [Panel], [_Query_ Utama],
  [Transfer per status], [`sum by (status) (rate(transfers_total[1m]))`],
  [Latensi p95 REST per service], [`histogram_quantile(0.95, ...)` atas `http_server_request_duration_seconds_bucket` per `job`],
  [Circuit breaker transfer → account], [`circuit_breaker_state{target="account"}`, ditampilkan sebagai `CLOSED`, `HALF-OPEN`, `OPEN`],
  [Perubahan status circuit breaker], [`increase(circuit_breaker_transitions_total[1m])` per `from` dan `to`],
  [Outbox pending], [`outbox_pending`],
  [Notifikasi per hasil], [`sum by (result) (rate(notifications_processed_total[1m]))`],
  [Latensi p95 gRPC account per method], [`histogram_quantile(0.95, ...)` atas `grpc_server_request_duration_seconds_bucket` per `method`],
  [Latensi p95 REST per route], [Seperti latensi REST, per `route`],
  [Target scrape], [`up`: `UP` bila Prometheus berhasil mengambil `/metrics` service],
)

// TODO(endy): dashboard layout and the stat value mappings were checked only through the Grafana API; look at it in a browser once before delivery.

Di terminal keempat, jalankan beban transfer terus-menerus:

#perintah[```bash
TOKEN=$(make -s token)
while true; do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8082/transfers \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"from_account":"1111111111","to_account":"2222222222","amount":"1000"}'
  sleep 0.5
done
```]

Setelah satu atau dua menit, ketika panel _Transfer per status_ menunjukkan aliran `COMPLETED` yang stabil, jalankan gangguan di terminal lain:

#perintah[```bash
make fault-slow     # account menahan setiap panggilan 3 detik
make breaker        # setelah beberapa transfer: {"account":"open"}
make metrics
```]

Amati hasilnya secara berurutan. _Query_ untuk Tempo dan Loki ada di bawah tabel.

#table(
  columns: (auto, 1fr, 2fr),
  [No.], [Tempat], [Yang Terlihat],
  [1], [Terminal beban], [Respons berubah dari `201` menjadi `502` (transfer `FAILED` setelah semua percobaan habis), lalu `503` (ditolak _circuit breaker_ yang berstatus `open`)],
  [2], [_Dashboard_], [Latensi p95 gRPC `Debit` naik ke kisaran 2 detik, _circuit breaker_ menjadi `OPEN`, dan laju `FAILED` naik],
  [3], [_Explore_ → Tempo], [_Trace_ dari sebelum _circuit breaker_ berstatus `open` berisi empat _span_ `Debit` sekitar 2 detik: satu percobaan ditambah tiga _retry_. _Span_ server di `account` sama panjangnya dan membawa _event_ `fault injected: delay`],
  [4], [_Explore_ → Loki], [Log `retrying account call` dan `transfer not completed` dari _trace_ yang sama],
)

_Query_ TraceQL di Tempo untuk transfer yang gagal:

```
{ span.transfer.status = "FAILED" }
```

_Query_ Loki untuk semua log satu _trace_, dengan `trace_id` disalin dari Tempo atau dari log:

```
{service_name=~"account|transfer|notification"} | trace_id="<trace_id>"
```

Beberapa hasil perlu dibaca dengan cermat:

- Latensi `Debit` tercatat sekitar 2 detik, padahal _delay_ simulasi 3 detik. `transfer` memutus setiap percobaan setelah 2 detik (_timeout_ per percobaan dari Lab 3). _Context_ di `account` ikut dibatalkan, sehingga _span_ server juga berhenti di sekitar 2 detik. Nilai p95 di panel adalah perkiraan dari _bucket histogram_ (batas 1 detik dan 2,5 detik), sehingga angkanya berada di antara kedua batas tersebut.
- Latensi p95 REST `transfer` dapat terlihat rendah ketika _circuit breaker_ berstatus `open`. Transfer yang ditolak _circuit breaker_ selesai dalam hitungan milidetik, karena panggilan ke `account` tidak pernah dikirim. Latensi yang rendah tidak berarti sistem sehat; panel _Transfer per status_ menunjukkan bahwa hampir semua transfer `FAILED`. Inilah alasan _metric_ bisnis dibutuhkan di samping _metric_ teknis.
- _Trace_ transfer yang ditolak _circuit breaker_ hanya berisi _span_ `POST /transfers` tanpa _span_ `Debit`.
- Selama gangguan masih aktif, panel _Perubahan status circuit breaker_ menunjukkan siklus `open` → `half-open` → `open`. Setelah 10 detik, panggilan berikutnya menjadi percobaan _half-open_, gagal lagi, dan _circuit breaker_ kembali ke `open`.

Akhiri gangguan:

#perintah[```bash
make fault-clear
```]

Panel _circuit breaker_ kembali ke `CLOSED`, dan transfer kembali `COMPLETED`. Status `HALF-OPEN` hanya berlangsung sekitar satu detik, sehingga biasanya tidak tertangkap _scrape_; perpindahan `open` → `half-open` → `closed` terlihat di panel _Perubahan status circuit breaker_. Perpindahan dari `open` ke `half-open` hanya terjadi pada panggilan pertama setelah 10 detik. Tanpa beban transfer, _circuit breaker_ dari latihan sebelumnya tetap berstatus `open` walaupun `account` sudah normal. Hentikan _loop_ beban dengan Ctrl+C.

// TODO(endy): the Tempo "logs for this span" link to Loki was not exercised; the explicit Loki query above was verified.

== Verifikasi

Semua pengujian lulus:

#perintah[```bash
make test
```]

Pengujian baru yang diambil dari _checkpoint_:

#table(
  columns: (1fr, 1fr),
  [Pengujian], [Lokasi],
  [`TestCheckEndpointURL`], [`account`, `transfer`, `notification` (paket `main`)],
  [`TestCorrelationMiddleware`, `TestLogCarriesCorrelationAndTraceIDs`, `TestMetricsUseRoutePattern`], [`transfer/internal/telemetry`],
  [`TestMessageContinuesTheRequestTrace`], [`transfer/internal/outbox`],
  [`TestSendsCorrelationID`, `TestBreakerMetrics`], [`transfer/internal/accountclient`],
  [`TestUnaryServerCorrelation`], [`account/internal/telemetry`],
  [`TestMetricsRecordsMethodAndCode`], [`account/internal/interceptor`],
  [`TestConsumerContinuesTraceAndCounts`], [`notification/internal/notification`],
)

Konfigurasi yang salah menghentikan service saat _startup_. Bila nilai `OTEL_EXPORTER_OTLP_ENDPOINT` di `transfer/Makefile` sementara diganti menjadi `localhost:4317`, `make -C transfer run` berhenti dengan:

```
{"time":"...","level":"ERROR","msg":"transfer service stopped","error":"OTEL_EXPORTER_OTLP_ENDPOINT must be a URL like http://localhost:4317, got \"localhost:4317\""}
```

Nilai `http://localhost`, tanpa port, juga ditolak:

```
{"time":"...","level":"ERROR","msg":"transfer service stopped","error":"OTEL_EXPORTER_OTLP_ENDPOINT must name the port explicitly, like http://localhost:4317, got \"http://localhost\""}
```

_Metric_ domain dapat dibaca langsung dari `/metrics`, tanpa Grafana. Setelah beberapa transfer berhasil, `make metrics` menampilkan kira-kira:

```
# http://localhost:8081/metrics
# http://localhost:8082/metrics
circuit_breaker_state{target="account"} 0
outbox_pending 0
transfers_total{status="COMPENSATED"} 0
transfers_total{status="COMPENSATION_FAILED"} 0
transfers_total{status="COMPLETED"} 3
transfers_total{status="FAILED"} 0
# http://localhost:8083/metrics
notifications_processed_total{result="duplicate"} 0
notifications_processed_total{result="sent"} 3
notifications_processed_total{result="skipped"} 0
```

Bagian `8081` kosong karena `account` tidak memiliki _metric_ domain. _Counter_ perpindahan status _circuit breaker_ baru muncul setelah perpindahan pertama.

Daftar periksa akhir:

- Panel _Target scrape_ menunjukkan `UP` untuk `account`, `transfer`, dan `notification`.
- Respons `POST /transfers` mengembalikan _header_ `X-Correlation-Id`; tanpa _header_ dari pemanggil, nilainya berupa UUID baru.
- Satu _trace_ di Tempo berisi _span_ dari `transfer`, `account`, dan `notification`.
- Log di Loki dapat difilter dengan `trace_id` dan menampilkan baris dari ketiga service.
- Latihan menunjukkan _circuit breaker_ `OPEN` saat `make fault-slow` dan kembali `CLOSED` setelah `make fault-clear`.

== Masalah Umum

*Panel _Target scrape_ menunjukkan `DOWN`.* Prometheus di dalam _container_ tidak dapat mengambil `/metrics`. Pastikan service berjalan dan `curl localhost:8082/metrics` berhasil dari laptop. Di Docker Engine Linux, pastikan `extra_hosts: host-gateway` ada di `compose.yaml`, dan _firewall_ laptop mengizinkan koneksi dari jaringan Docker ke port 8081–8083. _Query_ `up` di _Explore_ menunjukkan status setiap target.

*Log `telemetry export failed` di _stdout_.* _Collector_ belum siap atau `otel-lgtm` tidak berjalan. Periksa `docker compose ps otel-lgtm`. Service tetap melayani _request_, tetapi _span_ dan log selama periode tersebut hilang. Pada pengembangan kode lab ini, beberapa kali terjadi jeda 20–30 detik setelah _binary_ hasil _build_ baru pertama kali dijalankan: _export_ OTLP gagal dengan `DeadlineExceeded`, dan sekali panggilan gRPC serta pengambilan _token_ dari `transfer` ikut _timeout_. Gejala tersebut tidak muncul lagi dengan _binary_ yang sama. Bila terjadi, tunggu hingga jeda tersebut selesai, lalu ulangi langkah yang sedang dikerjakan.

*Baris log tidak memiliki `trace_id` atau `correlation_id`.* Log ditulis tanpa _context_ (`log.Info` alih-alih `log.InfoContext(ctx, ...)`), atau _logger_ yang digunakan masih _logger_ awal dari `main`, sebelum `log = tel.Logger`.

*_Trace_ berhenti di `transfer`; tidak ada _span_ `process transfer-events`.* Periksa bahwa `Insert` mengisi `trace_context` (perintah di bawah), bahwa _relay_ memanggil `span.End()` setelah `WriteMessages` berhasil, dan bahwa `notification` memanggil `Extract` sebelum `tracer.Start`. _Event_ yang ditulis sebelum Lab 8 memang tidak memiliki _trace context_.

#perintah[```bash
docker compose exec db-transfer psql -U transfer -d transfer -c \
  "select id, correlation_id, trace_context from outbox order by created_at desc limit 5"
```]

*Panel latensi per _route_ menampilkan `unmatched` untuk semua _request_.* Pembungkus `route` tidak membungkus _mux_ secara langsung, sehingga `r.Pattern` tidak terbaca. Urutan di `HTTPHandler` harus `otelhttp` → `CorrelationMiddleware` → `route` → _mux_.

*Perubahan JSON _dashboard_ tidak terlihat.* Grafana membaca _file_ _dashboard_ saat _startup_. Jalankan `docker compose restart otel-lgtm`. Perubahan lewat UI Grafana tidak tersimpan ke _file_ dan hilang ketika _container_ dibuat ulang.

*Port 3000 sudah digunakan.* Aplikasi lain di laptop, misalnya _development server_ JavaScript, sering menggunakan port 3000. Hentikan aplikasi tersebut sebelum `make infra-up`.

*_Circuit breaker_ tetap `open` padahal `account` sudah normal.* Perpindahan ke `half-open` hanya terjadi saat ada panggilan. Kirim beberapa transfer, lalu periksa lagi dengan `make breaker`.

*Pencarian di Tempo tidak menemukan _trace_ yang baru dibuat.* Indeks pencarian Tempo tertinggal beberapa detik. Tunggu sebentar, atau buka _trace_ langsung dengan `trace_id` dari log.

== Eksplorasi Mandiri

+ Hentikan Kafka dengan `docker compose stop kafka`, kirim beberapa transfer, lalu amati panel _Outbox pending_ dan log `outbox publish failed`. Jalankan kembali dengan `docker compose start kafka`. Periksa di Tempo apakah _trace_ transfer yang tertunda tetap tersambung ke `notification`, dan berapa lama jarak antara _span_ `POST /transfers` dan _span_ `publish transfer-events`.
+ Jalankan `make fault-error RATE=0.5` alih-alih `make fault-slow`. Bandingkan _trace_ yang dihasilkan: berapa percobaan `Debit` yang muncul, berapa lama setiap percobaan, dan _event_ apa yang tercatat di _span_ server `account`.
+ Tambahkan _counter_ `account_mutations_total` dengan _label_ `type` (`DEBIT`, `CREDIT`) dan `applied` (`true`, `false`) di `account`, lalu tambahkan panel baru di `observability/dashboards/studi-kasus.json`. Amati panel tersebut selama beban transfer dari latihan berjalan.
+ Ganti _sampler_ di `telemetry.go` menjadi `sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.1))` di `transfer` saja. Amati berapa _trace_ yang tersimpan dan apakah _span_ `account` serta `notification` ikut mengikuti keputusan _sampling_ dari `transfer`.

== Checkpoint

Kondisi kode di akhir lab ini tersimpan di tag `lab-08`. Untuk membandingkan hasil kerja dengan _checkpoint_:

#perintah[```bash
git diff lab-08 -- .
```]

Peserta yang ingin melanjutkan ke Lab 9 dari kondisi _checkpoint_:

#perintah[```bash
git switch -c lab-09-kerja lab-08
```]
