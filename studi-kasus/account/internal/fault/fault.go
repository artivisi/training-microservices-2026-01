// Package fault simulates a slow or failing service for the resiliency labs.
// It is a training tool: the admin endpoints let anyone degrade the service.
package fault

import (
	"context"
	"encoding/json"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Config struct {
	// DelayMS is added before every request is processed.
	DelayMS int `json:"delay_ms"`
	// ErrorRate is the fraction of requests (0.0–1.0) answered with 503 (HTTP) or
	// Unavailable (gRPC) without being processed.
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
		if i.inject(r.Context()) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"injected fault"}` + "\n"))
			return
		}
		if r.Context().Err() != nil { // caller gave up during the delay; do not process
			return
		}
		next.ServeHTTP(w, r)
	})
}

// UnaryServerInterceptor is the gRPC counterpart of Wrap, driven by the same
// configuration: one PUT /admin/fault degrades REST and gRPC together. The
// injected error is Unavailable, the gRPC equivalent of HTTP 503 ("refused
// before processing"), which the transfer client is allowed to retry.
// skip names full methods that must stay fast, e.g. the health service.
func (i *Injector) UnaryServerInterceptor(skip func(fullMethod string) bool) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if skip(info.FullMethod) {
			return handler(ctx, req)
		}
		if i.inject(ctx) {
			return nil, status.Error(codes.Unavailable, "injected fault")
		}
		if err := ctx.Err(); err != nil { // caller gave up during the delay; do not process
			return nil, status.FromContextError(err).Err()
		}
		return handler(ctx, req)
	}
}

// inject sleeps for the configured delay (or until ctx ends) and reports whether
// this request must be answered with an injected error.
func (i *Injector) inject(ctx context.Context) bool {
	cfg := i.cfg.Load()
	// Lab 8: the span events tell a simulated fault from a real one in the
	// trace. A real slow dependency shows up as a long span without them.
	span := trace.SpanFromContext(ctx)
	if cfg.DelayMS > 0 {
		// Recorded before the wait: the caller usually gives up during it.
		span.AddEvent("fault injected: delay", trace.WithAttributes(attribute.Int("fault.delay_ms", cfg.DelayMS)))
		select {
		case <-time.After(time.Duration(cfg.DelayMS) * time.Millisecond):
		case <-ctx.Done():
			return false
		}
	}
	failed := cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate
	if failed {
		span.AddEvent("fault injected: error", trace.WithAttributes(attribute.Float64("fault.error_rate", cfg.ErrorRate)))
	}
	return failed
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
