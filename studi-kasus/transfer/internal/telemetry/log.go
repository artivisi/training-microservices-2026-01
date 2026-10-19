package telemetry

import (
	"context"
	"log/slog"

	"go.opentelemetry.io/otel/trace"
)

// contextHandler adds correlation_id, trace_id and span_id from the context
// to every record. A log line then leads to its trace in Tempo, and a trace to
// all of its log lines, across services.
//
// Only records logged WITH a context get them: inside request handling, use
// log.InfoContext(ctx, ...), not log.Info(...).
type contextHandler struct {
	slog.Handler
}

func newContextHandler(h slog.Handler) slog.Handler { return contextHandler{h} }

func (h contextHandler) Handle(ctx context.Context, r slog.Record) error {
	if id := CorrelationID(ctx); id != "" {
		r.AddAttrs(slog.String("correlation_id", id))
	}
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()), slog.String("span_id", sc.SpanID().String()))
	}
	return h.Handler.Handle(ctx, r)
}

func (h contextHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return contextHandler{h.Handler.WithAttrs(attrs)}
}

func (h contextHandler) WithGroup(name string) slog.Handler {
	return contextHandler{h.Handler.WithGroup(name)}
}
