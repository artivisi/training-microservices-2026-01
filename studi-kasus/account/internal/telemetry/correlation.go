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

// The correlation ID travels with a request through every service under these
// names. It is a business-level ID the caller can quote ("my transfer with
// correlation ID X failed"); the trace ID is the technical one. Both end up in
// every log line.
const (
	CorrelationHeader = "X-Correlation-ID"
	// gRPC metadata keys are lower case.
	CorrelationMetadataKey = "x-correlation-id"
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

// UnaryServerCorrelation is the gRPC counterpart of CorrelationMiddleware: the
// ID comes from the x-correlation-id metadata the transfer service sends. It
// runs first in the chain, so every later interceptor logs with the ID. The
// trace context needs no code here: the otelgrpc stats handler has already
// read it (traceparent) and started the server span.
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
