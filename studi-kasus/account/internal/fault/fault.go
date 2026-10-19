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
