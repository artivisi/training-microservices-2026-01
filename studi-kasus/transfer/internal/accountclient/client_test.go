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
	AttemptTimeout:      100 * time.Millisecond,
	MaxRetries:          3,
	BackoffMin:          time.Millisecond,
	BackoffMax:          5 * time.Millisecond,
	BreakerFailures:     5,
	BreakerWindow:       10,
	BreakerDelay:        time.Hour, // stays open for the whole test
	BreakerSuccesses:    3,
	ReversalMaxDuration: 300 * time.Millisecond,
	ReversalBackoffMin:  time.Millisecond,
	ReversalBackoffMax:  10 * time.Millisecond,
}

// fakeAccountService answers every Debit/Credit with answer(n), n = 1 for the
// first call; answer returns the gRPC error (nil = success).
type fakeAccountService struct {
	accountv1.UnimplementedAccountServiceServer
	calls  atomic.Int64
	answer func(ctx context.Context, n int64) error
	last   atomic.Pointer[accountv1.DebitRequest]
	// credits holds the reference of every Credit that reached the server.
	credits chan string
}

func (f *fakeAccountService) Debit(ctx context.Context, req *accountv1.DebitRequest) (*accountv1.DebitResponse, error) {
	f.last.Store(req)
	if err := f.answer(ctx, f.calls.Add(1)); err != nil {
		return nil, err
	}
	return &accountv1.DebitResponse{Account: &accountv1.Account{Number: req.GetNumber()}}, nil
}

func (f *fakeAccountService) Credit(ctx context.Context, req *accountv1.CreditRequest) (*accountv1.CreditResponse, error) {
	f.credits <- req.GetReference()
	if err := f.answer(ctx, f.calls.Add(1)); err != nil {
		return nil, err
	}
	return &accountv1.CreditResponse{Account: &accountv1.Account{Number: req.GetNumber()}}, nil
}

// serve runs the fake on an in-memory listener (bufconn) and returns a client
// wired to it with s and log. No TCP port is opened.
func serve(t *testing.T, answer func(ctx context.Context, n int64) error, s Settings, log *slog.Logger) (*Client, *fakeAccountService, *bufconn.Listener) {
	t.Helper()
	fake := &fakeAccountService{answer: answer, credits: make(chan string, 1000)}
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
	// Internal is a server-side failure; the same request most likely fails again.
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

// A timed-out attempt is retried since Lab 5: the account service deduplicates
// by reference, so even a debit that was applied late is not applied twice.
func TestRetryOnTimeout(t *testing.T) {
	c, fake := newTestClient(t, func(ctx context.Context, n int64) error {
		if n == 1 {
			select {
			case <-time.After(300 * time.Millisecond):
			case <-ctx.Done():
			}
		}
		return nil
	})
	if err := debit(c); err != nil {
		t.Fatalf("err = %v, want success on the second attempt", err)
	}
	if got := fake.calls.Load(); got != 2 {
		t.Fatalf("calls = %d, want 2 (timeout, then OK)", got)
	}
	if req := fake.last.Load(); req.GetReference() != "ref" {
		t.Fatalf("retry reference = %q, want the same reference", req.GetReference())
	}
}

func TestRetryOnDeadlineExceeded(t *testing.T) {
	c, fake := newTestClient(t, always(codes.DeadlineExceeded))
	if err := debit(c); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("err = %v, want DeadlineExceeded", err)
	}
	if got := fake.calls.Load(); got != 4 {
		t.Fatalf("calls = %d, want 4 (1 attempt + 3 retries)", got)
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

// TestReversalBypassesOpenBreaker is the saga situation: the account service
// fails, the breaker opens, the forward credit is rejected without being sent.
// The reversal must still be sent, keep retrying while the service is down,
// and succeed once it is back, with the same reference on every attempt.
func TestReversalBypassesOpenBreaker(t *testing.T) {
	var down atomic.Bool
	down.Store(true)
	c, fake := newTestClient(t, func(context.Context, int64) error {
		if down.Load() {
			return status.Error(codes.Unavailable, "account down")
		}
		return nil
	})
	ctx := context.Background()
	for range 2 {
		_ = debit(c) // 4 attempts each: the breaker opens after 5 failures
	}
	if got := c.BreakerState(); got != "open" {
		t.Fatalf("breaker = %s, want open", got)
	}
	err := c.Credit(ctx, "2222222222", decimal.NewFromInt(10), "T-1")
	if !errors.Is(err, transfer.ErrAccountUnavailable) {
		t.Fatalf("forward credit err = %v, want ErrAccountUnavailable", err)
	}
	if n := len(fake.credits); n != 0 {
		t.Fatalf("forward credit reached the server %d times, want 0", n)
	}

	// The account service comes back while the reversal is retrying.
	go func() {
		time.Sleep(50 * time.Millisecond)
		down.Store(false)
	}()
	if err := c.Reverse(ctx, "1111111111", decimal.NewFromInt(10), "T-1:reversal"); err != nil {
		t.Fatalf("reverse err = %v, want success once the account service is back", err)
	}
	close(fake.credits)
	attempts := 0
	for ref := range fake.credits {
		attempts++
		if ref != "T-1:reversal" {
			t.Fatalf("reversal attempt %d reference = %q, want T-1:reversal", attempts, ref)
		}
	}
	if attempts < 2 {
		t.Fatalf("reversal attempts = %d, want retries while the service was down", attempts)
	}
	if got := c.BreakerState(); got != "open" {
		t.Fatalf("breaker = %s, want still open: the reversal does not touch it", got)
	}
}

// TestReversalGivesUpAfterMaxDuration: the window is bounded, so a saga does not
// hang forever on a dead account service; it ends in COMPENSATION_FAILED.
func TestReversalGivesUpAfterMaxDuration(t *testing.T) {
	c, _ := newTestClient(t, always(codes.Unavailable))
	start := time.Now()
	err := c.Reverse(context.Background(), "1111111111", decimal.NewFromInt(10), "T-1:reversal")
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("err = %v, want the last Unavailable", err)
	}
	elapsed := time.Since(start)
	if elapsed < testSettings.ReversalMaxDuration || elapsed > testSettings.WorstCaseReversal()+100*time.Millisecond {
		t.Fatalf("gave up after %s, want between %s and %s", elapsed, testSettings.ReversalMaxDuration, testSettings.WorstCaseReversal())
	}
}

func TestReversalBusinessRejectionIsFinal(t *testing.T) {
	c, fake := newTestClient(t, always(codes.NotFound))
	err := c.Reverse(context.Background(), "1111111111", decimal.NewFromInt(10), "T-1:reversal")
	if !errors.Is(err, transfer.ErrAccountNotFound) {
		t.Fatalf("err = %v, want ErrAccountNotFound", err)
	}
	if got := fake.calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1", got)
	}
}

func TestNewRejectsMissingReversalWindow(t *testing.T) {
	s := testSettings
	s.ReversalMaxDuration = 0
	if _, err := New("passthrough:///bufnet", s, slog.New(slog.NewTextHandler(io.Discard, nil))); err == nil {
		t.Fatal("New accepted ReversalMaxDuration = 0, which would retry forever")
	}
}
