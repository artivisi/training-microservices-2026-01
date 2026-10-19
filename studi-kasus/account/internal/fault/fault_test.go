package fault

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestInjector(t *testing.T) {
	i := NewInjector(slog.New(slog.NewTextHandler(io.Discard, nil)))
	mux := http.NewServeMux()
	i.Register(mux)
	mux.Handle("/", i.Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})))

	call := func(method, path, body string) int {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
		return rec.Code
	}

	if got := call("GET", "/accounts", ""); got != 200 {
		t.Fatalf("no fault: status %d, want 200", got)
	}
	if got := call("PUT", "/admin/fault", `{"error_rate":1}`); got != 200 {
		t.Fatalf("set fault: status %d", got)
	}
	if got := call("GET", "/accounts", ""); got != 503 {
		t.Fatalf("error_rate 1: status %d, want 503", got)
	}
	call("PUT", "/admin/fault", `{"delay_ms":200}`)
	start := time.Now()
	call("GET", "/accounts", "")
	if d := time.Since(start); d < 200*time.Millisecond {
		t.Fatalf("delay_ms 200: took %s", d)
	}
	if got := call("PUT", "/admin/fault", `{"error_rate":2}`); got != 400 {
		t.Fatalf("invalid rate: status %d, want 400", got)
	}
	call("DELETE", "/admin/fault", "")
	if got := call("GET", "/accounts", ""); got != 200 {
		t.Fatalf("cleared: status %d, want 200", got)
	}
}
