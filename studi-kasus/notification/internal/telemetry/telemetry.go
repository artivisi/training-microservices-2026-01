// Package telemetry wires the three observability signals of the service
// (Lab 8):
//
//   - logs: slog as JSON on stdout, and the same records as OTLP logs to the
//     collector (Loki in Grafana)
//   - traces: OpenTelemetry spans, exported over OTLP gRPC (Tempo)
//   - metrics: Prometheus, pulled from GET /metrics by the Prometheus server
//
// plus the correlation ID that ties the log lines of one request together.
//
// Every service has its own copy of this package on purpose: services share
// conventions (header names, metric names), not code. A shared library would
// tie their release cycles together.
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
// logger. otlpEndpoint is the collector's OTLP gRPC address as a URL
// (http://localhost:4317). Nothing connects here: a collector that is down does
// not stop the service, export failures are logged on stdout instead.
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
		// Every trace is kept: right for a lab with a handful of requests.
		// Production keeps a fraction (TraceIDRatioBased) or decides per trace at
		// the collector (tail sampling: keep errors and slow ones), otherwise the
		// trace backend costs more than the service.
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
	lp := sdklog.NewLoggerProvider(sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)), sdklog.WithResource(res))

	// Every record goes to both: stdout for `docker logs` / `kubectl logs`,
	// OTLP for Loki, where a log line links to its trace.
	handler := newContextHandler(slog.NewMultiHandler(stdout, otelslog.NewHandler(serviceName, otelslog.WithLoggerProvider(lp))))
	return &Telemetry{Logger: slog.New(handler), tp: tp, lp: lp}, nil
}

// Shutdown flushes the spans and logs still buffered. Call it last, after
// everything that logs has stopped.
func (t *Telemetry) Shutdown(ctx context.Context) error {
	return errors.Join(t.tp.Shutdown(ctx), t.lp.Shutdown(ctx))
}
