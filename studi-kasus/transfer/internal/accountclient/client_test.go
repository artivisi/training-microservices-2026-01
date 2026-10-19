package accountclient

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/shopspring/decimal"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

// testSettings keeps the production policy shape with short durations so the
// tests run in milliseconds.
var testSettings = Settings{
	AttemptTimeout:   100 * time.Millisecond,
	MaxRetries:       3,
	BackoffMin:       time.Millisecond,
	BackoffMax:       5 * time.Millisecond,
	BreakerFailures:  5,
	BreakerWindow:    10,
	BreakerDelay:     time.Hour, // stays open for the whole test
	BreakerSuccesses: 3,
}

func newTestClient(url string) *Client {
	return New(url, testSettings, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func debit(c *Client) error {
	return c.Debit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
}

// countingServer answers each request with status(n), n = 1 for the first request.
func countingServer(t *testing.T, status func(n int64) int) (*httptest.Server, *atomic.Int64) {
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status(calls.Add(1)))
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

func TestStatusMapping(t *testing.T) {
	tests := []struct {
		status  int
		wantErr error
	}{
		{http.StatusOK, nil},
		{http.StatusNotFound, transfer.ErrAccountNotFound},
		{http.StatusUnprocessableEntity, transfer.ErrInsufficientFunds},
	}
	for _, tc := range tests {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost || r.URL.Path != "/accounts/1111111111/debit" {
				t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			}
			w.WriteHeader(tc.status)
		}))
		err := debit(newTestClient(srv.URL))
		srv.Close()
		if !errors.Is(err, tc.wantErr) {
			t.Errorf("status %d: err = %v, want %v", tc.status, err, tc.wantErr)
		}
	}
}

func TestServerError(t *testing.T) {
	srv, calls := countingServer(t, func(int64) int { return http.StatusInternalServerError })
	err := newTestClient(srv.URL).Credit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
	if err == nil || errors.Is(err, transfer.ErrAccountNotFound) || errors.Is(err, transfer.ErrInsufficientFunds) {
		t.Fatalf("err = %v, want a non-business error", err)
	}
	// A 500 may come from a request that was half processed: no retry.
	if got := calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1", got)
	}
}

func TestRetryOn503Succeeds(t *testing.T) {
	srv, calls := countingServer(t, func(n int64) int {
		if n <= 2 {
			return http.StatusServiceUnavailable
		}
		return http.StatusOK
	})
	if err := debit(newTestClient(srv.URL)); err != nil {
		t.Fatalf("err = %v, want success after retries", err)
	}
	if got := calls.Load(); got != 3 {
		t.Fatalf("calls = %d, want 3 (two 503, then 200)", got)
	}
}

func TestRetryGivesUpAfterMaxRetries(t *testing.T) {
	srv, calls := countingServer(t, func(int64) int { return http.StatusServiceUnavailable })
	if err := debit(newTestClient(srv.URL)); err == nil {
		t.Fatal("err = nil, want failure")
	}
	if got := calls.Load(); got != 4 {
		t.Fatalf("calls = %d, want 4 (1 attempt + 3 retries)", got)
	}
}

func TestNoRetryOnTimeout(t *testing.T) {
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		select {
		case <-time.After(300 * time.Millisecond):
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(srv.Close)

	start := time.Now()
	err := debit(newTestClient(srv.URL))
	if err == nil {
		t.Fatal("err = nil, want timeout")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1: a timed-out debit may have been applied", got)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("took %s, want about the attempt timeout", elapsed)
	}
}

func TestRetryOnConnectionRefused(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close() // nothing listens on this port any more

	var logs bytes.Buffer
	c := New(url, testSettings, slog.New(slog.NewTextHandler(&logs, nil)))
	if err := debit(c); err == nil || errors.Is(err, transfer.ErrAccountUnavailable) {
		t.Fatalf("err = %v, want a connection error", err)
	}
	if got := strings.Count(logs.String(), "retrying account call"); got != 3 {
		t.Fatalf("retries = %d, want 3; logs:\n%s", got, logs.String())
	}
	// 4 refused attempts count as 4 breaker failures, still under 5.
	if got := c.BreakerState(); got != "closed" {
		t.Fatalf("breaker = %s, want closed", got)
	}
}

func TestBreakerOpensAndRejectsFast(t *testing.T) {
	srv, calls := countingServer(t, func(int64) int { return http.StatusInternalServerError })
	c := newTestClient(srv.URL)

	for range 5 {
		_ = debit(c)
	}
	if got := c.BreakerState(); got != "open" {
		t.Fatalf("breaker = %s, want open after 5 failures", got)
	}

	start := time.Now()
	err := debit(c)
	if !errors.Is(err, transfer.ErrAccountUnavailable) {
		t.Fatalf("err = %v, want ErrAccountUnavailable", err)
	}
	if got := calls.Load(); got != 5 {
		t.Fatalf("calls = %d, want 5: an open breaker must not reach the server", got)
	}
	if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
		t.Fatalf("rejected in %s, want immediately", elapsed)
	}

	rec := httptest.NewRecorder()
	c.ServeCircuitBreaker(rec, httptest.NewRequest(http.MethodGet, "/debug/circuit-breaker", nil))
	if body := rec.Body.String(); body != `{"account":"open"}`+"\n" {
		t.Fatalf("debug body = %q", body)
	}
}

func TestBusinessRejectionsDoNotOpenBreaker(t *testing.T) {
	srv, _ := countingServer(t, func(int64) int { return http.StatusUnprocessableEntity })
	c := newTestClient(srv.URL)
	for range 10 {
		if err := debit(c); !errors.Is(err, transfer.ErrInsufficientFunds) {
			t.Fatalf("err = %v, want ErrInsufficientFunds", err)
		}
	}
	if got := c.BreakerState(); got != "closed" {
		t.Fatalf("breaker = %s, want closed", got)
	}
}

func TestBreakerHalfOpenCloses(t *testing.T) {
	var fail atomic.Bool
	fail.Store(true)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if fail.Load() {
			w.WriteHeader(http.StatusInternalServerError)
		}
	}))
	t.Cleanup(srv.Close)

	s := testSettings
	s.BreakerDelay = 50 * time.Millisecond
	c := New(srv.URL, s, slog.New(slog.NewTextHandler(io.Discard, nil)))
	for range 5 {
		_ = debit(c)
	}
	if got := c.BreakerState(); got != "open" {
		t.Fatalf("breaker = %s, want open", got)
	}

	fail.Store(false)
	time.Sleep(60 * time.Millisecond)
	if err := debit(c); err != nil {
		t.Fatalf("trial call: %v", err)
	}
	if got := c.BreakerState(); got != "half-open" {
		t.Fatalf("breaker = %s, want half-open after 1 of 3 trial successes", got)
	}
	for range 2 {
		if err := debit(c); err != nil {
			t.Fatalf("trial call: %v", err)
		}
	}
	if got := c.BreakerState(); got != "closed" {
		t.Fatalf("breaker = %s, want closed after 3 trial successes", got)
	}
}
