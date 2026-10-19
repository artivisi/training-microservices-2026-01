// Package accountclient calls the account service gRPC API through failsafe-go
// policies: per-attempt timeout, retry with backoff, and a circuit breaker,
// installed as a gRPC unary client interceptor.
package accountclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/failsafe-go/failsafe-go"
	"github.com/failsafe-go/failsafe-go/circuitbreaker"
	"github.com/failsafe-go/failsafe-go/failsafegrpc"
	"github.com/failsafe-go/failsafe-go/retrypolicy"
	"github.com/failsafe-go/failsafe-go/timeout"
	"github.com/shopspring/decimal"
	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

// Settings are the resiliency parameters. They live in code, not in environment
// variables: changing them is a design decision that goes through review and
// tests like any other code change. Tests pass shorter durations.
type Settings struct {
	// AttemptTimeout bounds one gRPC attempt, not the whole call with its retries.
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
	conn    *grpc.ClientConn
	api     accountv1.AccountServiceClient
	breaker circuitbreaker.CircuitBreaker[any]
}

// New connects lazily: no network traffic until the first call, so the transfer
// service starts even while the account service is down. opts are extra dial
// options; tests pass an in-memory dialer.
func New(target string, s Settings, log *slog.Logger, opts ...grpc.DialOption) (*Client, error) {
	// R = any: the interceptor sees every RPC of the connection, whatever its
	// response type. The policies only look at the error.
	//
	// One breaker for the whole account service: debit and credit share the same
	// failure domain, so a dead account service stops both.
	breaker := circuitbreaker.NewBuilder[any]().
		HandleIf(countsAsFailure).
		WithFailureThresholdRatio(s.BreakerFailures, s.BreakerWindow).
		WithDelay(s.BreakerDelay).
		WithSuccessThreshold(s.BreakerSuccesses).
		OnStateChanged(func(e circuitbreaker.StateChangedEvent) {
			log.Warn("circuit breaker state changed", "target", "account",
				"from", e.OldState.String(), "to", e.NewState.String())
		}).
		Build()

	retry := retrypolicy.NewBuilder[any]().
		HandleIf(notProcessed).
		// Explicit even though notProcessed already ignores ErrOpen: retrying against
		// an open breaker only burns backoff time and fails anyway.
		AbortOnErrors(circuitbreaker.ErrOpen).
		WithMaxRetries(s.MaxRetries).
		WithBackoff(s.BackoffMin, s.BackoffMax).
		// Jitter spreads the retries of many concurrent transfers so they do not all
		// hit a recovering account service in the same millisecond.
		WithJitterFactor(0.25).
		// Hand the last status error back instead of wrapping it in an ExceededError,
		// so mapError sees the real gRPC code.
		ReturnLastFailure().
		OnRetry(func(e failsafe.ExecutionEvent[any]) {
			log.Warn("retrying account call", "next_attempt", e.Attempts(), "cause", e.LastError())
		}).
		Build()

	// Order matters: retry wraps the breaker, which wraps the timeout. Every attempt
	// gets its own time budget, and every attempt, timeouts included, is counted by
	// the breaker. Same shape as the REST client of Lab 3, now as an interceptor.
	resilience := failsafegrpc.NewUnaryClientInterceptor[any](retry, breaker, timeout.New[any](s.AttemptTimeout))

	opts = append([]grpc.DialOption{
		// Plaintext: fine on a laptop, not in production. Service-to-service calls
		// there go over TLS (or mTLS through a service mesh); Lab 7 adds tokens.
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(resilience),
		// After a failed connect, gRPC waits before reconnecting, growing up to
		// 120 s by default. Capped at 5 s so a restarted account service is used
		// again within seconds, which is what the breaker's half-open trials need.
		grpc.WithConnectParams(grpc.ConnectParams{
			Backoff:           backoff.Config{BaseDelay: time.Second, Multiplier: 1.6, Jitter: 0.2, MaxDelay: 5 * time.Second},
			MinConnectTimeout: 5 * time.Second,
		}),
	}, opts...)
	conn, err := grpc.NewClient(target, opts...)
	if err != nil {
		return nil, fmt.Errorf("account gRPC client for %s: %w", target, err)
	}
	return &Client{conn: conn, api: accountv1.NewAccountServiceClient(conn), breaker: breaker}, nil
}

func (c *Client) Close() error { return c.conn.Close() }

// notProcessed reports whether the call may be retried: only Unavailable, which
// means the server refused the call before running it (the fault injector does
// exactly that) or no connection could be made.
//
// DeadlineExceeded and our own attempt timeout are NOT retried: the account
// service may have applied the debit and only the answer was late. Debit is not
// idempotent yet, so a retry would debit twice. Lab 5 makes mutations idempotent
// by reference; only then are timeouts retried.
//
// Residual risk: gRPC also reports Unavailable when an established connection
// drops after the request was sent, so this is "almost provably" not processed.
// Lab 5's idempotent references close that gap as well.
func notProcessed(_ any, err error) bool {
	return status.Code(err) == codes.Unavailable
}

// countsAsFailure decides what the breaker counts against the account service:
// infrastructure codes and our own attempt timeout. Business codes (NotFound,
// FailedPrecondition, InvalidArgument) are a healthy service saying no and must
// not open the breaker.
func countsAsFailure(_ any, err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, timeout.ErrExceeded) {
		return true
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded, codes.Internal, codes.Unknown:
		return true
	}
	return false
}

// BreakerState is "closed", "open" or "half-open".
func (c *Client) BreakerState() string { return c.breaker.State().String() }

// ServeCircuitBreaker answers GET /debug/circuit-breaker on the transfer service.
func (c *Client) ServeCircuitBreaker(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"account": c.BreakerState()})
}

func (c *Client) Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	_, err := c.api.Debit(ctx, &accountv1.DebitRequest{Number: number, Amount: amount.String(), Reference: reference})
	return mapError("debit", number, err)
}

func (c *Client) Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	_, err := c.api.Credit(ctx, &accountv1.CreditRequest{Number: number, Amount: amount.String(), Reference: reference})
	return mapError("credit", number, err)
}

// mapError turns the account service's gRPC codes into the transfer domain's
// errors, so the transfer package never imports gRPC.
func mapError(kind, number string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, circuitbreaker.ErrOpen) {
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountUnavailable)
	}
	switch status.Code(err) {
	case codes.NotFound:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountNotFound)
	case codes.FailedPrecondition:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrInsufficientFunds)
	}
	return fmt.Errorf("%s %s: %w", kind, number, err)
}
