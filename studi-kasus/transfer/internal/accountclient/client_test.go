package accountclient

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/shopspring/decimal"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
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

// fakeAccountService answers every Debit/Credit with answer(n), n = 1 for the
// first call; answer returns the gRPC error (nil = success).
type fakeAccountService struct {
	accountv1.UnimplementedAccountServiceServer
	calls  atomic.Int64
	answer func(ctx context.Context, n int64) error
	last   atomic.Pointer[accountv1.DebitRequest]
}

func (f *fakeAccountService) Debit(ctx context.Context, req *accountv1.DebitRequest) (*accountv1.DebitResponse, error) {
	f.last.Store(req)
	if err := f.answer(ctx, f.calls.Add(1)); err != nil {
		return nil, err
	}
	return &accountv1.DebitResponse{Account: &accountv1.Account{Number: req.GetNumber()}}, nil
}

func (f *fakeAccountService) Credit(ctx context.Context, req *accountv1.CreditRequest) (*accountv1.CreditResponse, error) {
	if err := f.answer(ctx, f.calls.Add(1)); err != nil {
		return nil, err
	}
	return &accountv1.CreditResponse{Account: &accountv1.Account{Number: req.GetNumber()}}, nil
}

// serve runs the fake on an in-memory listener (bufconn) and returns a client
// wired to it with s and log. No TCP port is opened.
func serve(t *testing.T, answer func(ctx context.Context, n int64) error, s Settings, log *slog.Logger) (*Client, *fakeAccountService, *bufconn.Listener) {
	t.Helper()
	fake := &fakeAccountService{answer: answer}
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	accountv1.RegisterAccountServiceServer(srv, fake)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	c, err := New("passthrough:///bufnet", s, log,
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c, fake, lis
}

func newTestClient(t *testing.T, answer func(ctx context.Context, n int64) error) (*Client, *fakeAccountService) {
	c, fake, _ := serve(t, answer, testSettings, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return c, fake
}

func always(code codes.Code) func(context.Context, int64) error {
	return func(context.Context, int64) error { return status.Error(code, code.String()) }
}

func debit(c *Client) error {
	return c.Debit(context.Background(), "1111111111", decimal.RequireFromString("10.50"), "ref")
}

func TestCodeMapping(t *testing.T) {
	tests := []struct {
		code    codes.Code
		wantErr error
	}{
		{codes.OK, nil},
		{codes.NotFound, transfer.ErrAccountNotFound},
		{codes.FailedPrecondition, transfer.ErrInsufficientFunds},
	}
	for _, tc := range tests {
		c, fake := newTestClient(t, func(context.Context, int64) error {
			if tc.code == codes.OK {
				return nil
			}
			return status.Error(tc.code, "no")
		})
		if err := debit(c); !errors.Is(err, tc.wantErr) {
			t.Errorf("code %s: err = %v, want %v", tc.code, err, tc.wantErr)
		}
		req := fake.last.Load()
		if req.GetNumber() != "1111111111" || req.GetAmount() != "10.5" || req.GetReference() != "ref" {
			t.Errorf("request = %v", req)
		}
	}
}

func TestInternalIsNotRetried(t *testing.T) {
	c, fake := newTestClient(t, always(codes.Internal))
	err := c.Credit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
	if err == nil || errors.Is(err, transfer.ErrAccountNotFound) || errors.Is(err, transfer.ErrInsufficientFunds) {
		t.Fatalf("err = %v, want a non-business error", err)
	}
	// Internal may come from a call that was half processed: no retry.
	if got := fake.calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1", got)
	}
}

func TestRetryOnUnavailableSucceeds(t *testing.T) {
	c, fake := newTestClient(t, func(_ context.Context, n int64) error {
		if n <= 2 {
			return status.Error(codes.Unavailable, "injected fault")
		}
		return nil
	})
	if err := debit(c); err != nil {
		t.Fatalf("err = %v, want success after retries", err)
	}
	if got := fake.calls.Load(); got != 3 {
		t.Fatalf("calls = %d, want 3 (two Unavailable, then OK)", got)
	}
}

func TestRetryGivesUpAfterMaxRetries(t *testing.T) {
	c, fake := newTestClient(t, always(codes.Unavailable))
	if err := debit(c); status.Code(err) != codes.Unavailable {
		t.Fatalf("err = %v, want the last Unavailable", err)
	}
	if got := fake.calls.Load(); got != 4 {
		t.Fatalf("calls = %d, want 4 (1 attempt + 3 retries)", got)
	}
}

func TestNoRetryOnTimeout(t *testing.T) {
	c, fake := newTestClient(t, func(ctx context.Context, _ int64) error {
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
		}
		return nil
	})
	start := time.Now()
	if err := debit(c); err == nil {
		t.Fatal("err = nil, want timeout")
	}
	if got := fake.calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1: a timed-out debit may have been applied", got)
	}
	if elapsed := time.Since(start); elapsed > 250*time.Millisecond {
		t.Fatalf("took %s, want about the attempt timeout", elapsed)
	}
}

func TestNoRetryOnDeadlineExceeded(t *testing.T) {
	c, fake := newTestClient(t, always(codes.DeadlineExceeded))
	if err := debit(c); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("err = %v, want DeadlineExceeded", err)
	}
	if got := fake.calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1", got)
	}
}

func TestRetryOnConnectionRefused(t *testing.T) {
	var logs bytes.Buffer
	c, fake, lis := serve(t, always(codes.OK), testSettings, slog.New(slog.NewTextHandler(&logs, nil)))
	lis.Close() // nothing accepts connections any more

	if err := debit(c); status.Code(err) != codes.Unavailable {
		t.Fatalf("err = %v, want Unavailable", err)
	}
	if got := strings.Count(logs.String(), "retrying account call"); got != 3 {
		t.Fatalf("retries = %d, want 3; logs:\n%s", got, logs.String())
	}
	if got := fake.calls.Load(); got != 0 {
		t.Fatalf("calls = %d, want 0", got)
	}
	// 4 refused attempts count as 4 breaker failures, still under 5.
	if got := c.BreakerState(); got != "closed" {
		t.Fatalf("breaker = %s, want closed", got)
	}
}

func TestBreakerOpensAndRejectsFast(t *testing.T) {
	c, fake := newTestClient(t, always(codes.Internal))
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
	if got := fake.calls.Load(); got != 5 {
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
	c, _ := newTestClient(t, always(codes.FailedPrecondition))
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
	s := testSettings
	s.BreakerDelay = 50 * time.Millisecond
	c, _, _ := serve(t, func(context.Context, int64) error {
		if fail.Load() {
			return status.Error(codes.Internal, "boom")
		}
		return nil
	}, s, slog.New(slog.NewTextHandler(io.Discard, nil)))

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
