package fault

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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

func TestUnaryServerInterceptor(t *testing.T) {
	i := NewInjector(slog.New(slog.NewTextHandler(io.Discard, nil)))
	intercept := i.UnaryServerInterceptor(func(method string) bool { return method == "/grpc.health.v1.Health/Check" })
	var handled int
	handler := func(context.Context, any) (any, error) { handled++; return "ok", nil }
	call := func(method string) error {
		_, err := intercept(context.Background(), nil, &grpc.UnaryServerInfo{FullMethod: method}, handler)
		return err
	}

	if err := call("/account.v1.AccountService/Debit"); err != nil {
		t.Fatalf("no fault: %v", err)
	}
	i.cfg.Store(&Config{ErrorRate: 1})
	if got := status.Code(call("/account.v1.AccountService/Debit")); got != codes.Unavailable {
		t.Fatalf("error_rate 1: code %s, want Unavailable", got)
	}
	if err := call("/grpc.health.v1.Health/Check"); err != nil {
		t.Fatalf("skipped method got a fault: %v", err)
	}
	if handled != 2 {
		t.Fatalf("handler ran %d times, want 2: an injected fault must not reach the handler", handled)
	}

	// A caller deadline shorter than the delay: the handler must not run.
	i.cfg.Store(&Config{DelayMS: 200})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err := intercept(ctx, nil, &grpc.UnaryServerInfo{FullMethod: "/account.v1.AccountService/Debit"}, handler)
	if status.Code(err) != codes.DeadlineExceeded || handled != 2 {
		t.Fatalf("err = %v, handled = %d; want DeadlineExceeded and no processing", err, handled)
	}
}
