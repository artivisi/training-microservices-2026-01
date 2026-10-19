// Package accountclient calls the account service REST API through failsafe-go
// policies: per-attempt timeout, retry with backoff, and a circuit breaker.
package accountclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/failsafe-go/failsafe-go"
	"github.com/failsafe-go/failsafe-go/circuitbreaker"
	"github.com/failsafe-go/failsafe-go/failsafehttp"
	"github.com/failsafe-go/failsafe-go/retrypolicy"
	"github.com/failsafe-go/failsafe-go/timeout"
	"github.com/shopspring/decimal"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

// Settings are the resiliency parameters. They live in code, not in environment
// variables: changing them is a design decision that goes through review and
// tests like any other code change. Tests pass shorter durations.
type Settings struct {
	// AttemptTimeout bounds one HTTP attempt, not the whole call with its retries.
	AttemptTimeout time.Duration
	MaxRetries     int
	BackoffMin     time.Duration
	BackoffMax     time.Duration
	// The breaker opens when BreakerFailures of the last BreakerWindow calls failed,
	// stays open for BreakerDelay, then lets BreakerSuccesses trial calls through
	// (half-open). All of them must succeed to close it; one failure reopens it.
	BreakerFailures  uint
	BreakerWindow    uint
	BreakerDelay     time.Duration
	BreakerSuccesses uint
}

// ProductionSettings is what the transfer service runs with.
var ProductionSettings = Settings{
	AttemptTimeout:   2 * time.Second,
	MaxRetries:       3,
	BackoffMin:       100 * time.Millisecond,
	BackoffMax:       time.Second,
	BreakerFailures:  5,
	BreakerWindow:    10,
	BreakerDelay:     10 * time.Second,
	BreakerSuccesses: 3,
}

type Client struct {
	baseURL string
	http    *http.Client
	breaker circuitbreaker.CircuitBreaker[*http.Response]
}

func New(baseURL string, s Settings, log *slog.Logger) *Client {
	// One breaker for the whole account service: debit and credit share the same
	// failure domain, so a dead account service stops both.
	breaker := circuitbreaker.NewBuilder[*http.Response]().
		HandleIf(countsAsFailure).
		WithFailureThresholdRatio(s.BreakerFailures, s.BreakerWindow).
		WithDelay(s.BreakerDelay).
		WithSuccessThreshold(s.BreakerSuccesses).
		OnStateChanged(func(e circuitbreaker.StateChangedEvent) {
			log.Warn("circuit breaker state changed", "target", "account",
				"from", e.OldState.String(), "to", e.NewState.String())
		}).
		Build()

	retry := retrypolicy.NewBuilder[*http.Response]().
		HandleIf(notProcessed).
		// Explicit even though notProcessed already ignores ErrOpen: retrying against
		// an open breaker only burns backoff time and fails anyway.
		AbortOnErrors(circuitbreaker.ErrOpen).
		WithMaxRetries(s.MaxRetries).
		WithBackoff(s.BackoffMin, s.BackoffMax).
		// Jitter spreads the retries of many concurrent transfers so they do not all
		// hit a recovering account service in the same millisecond.
		WithJitterFactor(0.25).
		// Hand the last 503 back as a response instead of wrapping it in an
		// ExceededError, so the status mapping in mutate sees it.
		ReturnLastFailure().
		OnRetry(func(e failsafe.ExecutionEvent[*http.Response]) {
			// The response that triggered this retry is discarded; close it so its
			// connection goes back to the pool.
			cause := fmt.Sprint(e.LastError())
			if resp := e.LastResult(); resp != nil {
				cause = resp.Status
				_, _ = io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}
			log.Warn("retrying account call", "next_attempt", e.Attempts(), "cause", cause)
		}).
		Build()

	// Order matters: retry wraps the breaker, which wraps the timeout. Every attempt
	// gets its own time budget, and every attempt, timeouts included, is counted by
	// the breaker.
	rt := failsafehttp.NewRoundTripper(nil, retry, breaker, timeout.New[*http.Response](s.AttemptTimeout))
	return &Client{baseURL: baseURL, http: &http.Client{Transport: rt}, breaker: breaker}
}

// notProcessed reports whether the request provably never reached the account
// logic, the only case where a retry is safe today.
//
// A timeout is NOT retried: the account service may have applied the debit and
// only the answer was late. Debit is not idempotent yet, so a retry would debit
// twice. Lab 5 makes mutations idempotent by reference; only then are timeouts
// retried.
func notProcessed(resp *http.Response, err error) bool {
	if err != nil {
		// Dial failure (connection refused, unknown host): nothing was sent.
		var opErr *net.OpError
		return errors.As(err, &opErr) && opErr.Op == "dial"
	}
	// 503 means the service refused the request before processing it (the fault
	// injector answers 503 without touching the account).
	return resp.StatusCode == http.StatusServiceUnavailable
}

// countsAsFailure decides what the breaker counts against the account service:
// transport errors, timeouts and 5xx. A 4xx is a healthy service saying no
// (unknown account, insufficient funds) and must not open the breaker.
func countsAsFailure(resp *http.Response, err error) bool {
	return err != nil || resp.StatusCode >= 500
}

// BreakerState is "closed", "open" or "half-open".
func (c *Client) BreakerState() string { return c.breaker.State().String() }

// ServeCircuitBreaker answers GET /debug/circuit-breaker on the transfer service.
func (c *Client) ServeCircuitBreaker(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"account": c.BreakerState()})
}

func (c *Client) Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	return c.mutate(ctx, number, "debit", amount, reference)
}

func (c *Client) Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	return c.mutate(ctx, number, "credit", amount, reference)
}

func (c *Client) mutate(ctx context.Context, number, kind string, amount decimal.Decimal, reference string) error {
	body, err := json.Marshal(map[string]any{"amount": amount, "reference": reference})
	if err != nil {
		return err
	}
	url := fmt.Sprintf("%s/accounts/%s/%s", c.baseURL, number, kind)
	// bytes.Reader: failsafehttp replays the body on every retry attempt.
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if errors.Is(err, circuitbreaker.ErrOpen) {
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountUnavailable)
	}
	if err != nil {
		return fmt.Errorf("%s %s: %w", kind, number, err)
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch resp.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusNotFound:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountNotFound)
	case http.StatusUnprocessableEntity:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrInsufficientFunds)
	default:
		return fmt.Errorf("%s %s: account service answered %s: %s", kind, number, resp.Status, bytes.TrimSpace(msg))
	}
}
