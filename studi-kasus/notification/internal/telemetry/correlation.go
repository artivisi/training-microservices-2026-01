package telemetry

import (
	"context"
	"net/http"
	"regexp"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// The correlation ID travels with a request through every service under these
// names. It is a business-level ID the caller can quote ("my transfer with
// correlation ID X failed"); the trace ID is the technical one. Both end up in
// every log line.
const (
	CorrelationHeader = "X-Correlation-ID"
	// Kafka header set by the transfer service's outbox relay, next to
	// event_type and event_id.
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
