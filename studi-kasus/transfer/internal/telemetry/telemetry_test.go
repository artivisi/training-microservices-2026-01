package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel/trace"
)

func TestCorrelationMiddleware(t *testing.T) {
	tests := []struct {
		name, incoming string
		keep           bool
	}{
		{"taken from the request", "req-7f9c2b1e", true},
		{"generated when absent", "", false},
		// A value that could forge log fields or flood the log is replaced.
		{"replaced when invalid", `x" level=ERROR msg="forged`, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var seen string
			h := CorrelationMiddleware(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
				seen = CorrelationID(r.Context())
			}))
			req := httptest.NewRequest(http.MethodGet, "/transfers/1", nil)
			if tc.incoming != "" {
				req.Header.Set(CorrelationHeader, tc.incoming)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			echoed := rec.Header().Get(CorrelationHeader)
			if seen == "" || echoed != seen {
				t.Fatalf("context ID %q, echoed %q: want the same non-empty ID", seen, echoed)
			}
			if (seen == tc.incoming) != tc.keep {
				t.Fatalf("ID = %q, incoming %q, keep = %v", seen, tc.incoming, tc.keep)
			}
		})
	}
}

func TestLogCarriesCorrelationAndTraceIDs(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(newContextHandler(slog.NewJSONHandler(&buf, nil)))

	traceID, _ := trace.TraceIDFromHex("4bf92f3577b34da6a3ce929d0e0e4736")
	spanID, _ := trace.SpanIDFromHex("00f067aa0ba902b7")
	ctx := trace.ContextWithSpanContext(context.Background(),
		trace.NewSpanContext(trace.SpanContextConfig{TraceID: traceID, SpanID: spanID, TraceFlags: trace.FlagsSampled}))
	ctx = WithCorrelationID(ctx, "req-1")

	log.InfoContext(ctx, "transfer completed")
	var line map[string]any
	if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
		t.Fatal(err)
	}
	if line["correlation_id"] != "req-1" || line["trace_id"] != traceID.String() || line["span_id"] != spanID.String() {
		t.Fatalf("log line = %v", line)
	}

	// Without a context there is nothing to add.
	buf.Reset()
	log.Info("relay started")
	if bytes.Contains(buf.Bytes(), []byte("trace_id")) || bytes.Contains(buf.Bytes(), []byte("correlation_id")) {
		t.Fatalf("log line = %s", buf.String())
	}
}

func TestMetricsUseRoutePattern(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /transfers/{id}", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	h := HTTPHandler(mux)
	for _, id := range []string{"a", "b", "c"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/transfers/"+id, nil))
	}
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/no/such/path", nil))

	// Three transfer IDs, one series: the pattern, not the path.
	if got := sampleCount(t, map[string]string{"method": "GET", "route": "/transfers/{id}", "status": "404"}); got != 3 {
		t.Fatalf("count for /transfers/{id} = %d, want 3", got)
	}
	if got := sampleCount(t, map[string]string{"method": "GET", "route": "unmatched", "status": "404"}); got != 1 {
		t.Fatalf("count for unmatched = %d, want 1", got)
	}
}

// sampleCount returns the observation count of the requestDuration series
// with exactly these labels.
func sampleCount(t *testing.T, labels map[string]string) uint64 {
	t.Helper()
	reg := prometheus.NewRegistry()
	reg.MustRegister(requestDuration)
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range families {
		for _, m := range f.GetMetric() {
			match := len(m.GetLabel()) == len(labels)
			for _, l := range m.GetLabel() {
				if labels[l.GetName()] != l.GetValue() {
					match = false
				}
			}
			if match {
				return m.GetHistogram().GetSampleCount()
			}
		}
	}
	return 0
}
