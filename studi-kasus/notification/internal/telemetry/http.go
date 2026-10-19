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
// (status), duration. route is the ServeMux pattern ("/notifications"), never
// the raw path: a client can send any path, and one series per path would grow
// without bound and take Prometheus down.
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
// Probes and /metrics are not traced: the kubelet and Prometheus call them
// every few seconds, and those traces would bury the real ones.
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

// route must wrap the mux directly. ServeMux writes the matched pattern into
// the *Request it routes (r.Pattern); that is this same r only as long as no
// middleware in between replaced it with r.WithContext.
func route(mux http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		mux.ServeHTTP(rec, r)

		// "GET /notifications" -> "/notifications"; the method is its own label.
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
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch, http.MethodHead, http.MethodOptions:
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
