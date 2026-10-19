// Package accountclient calls the account service gRPC API through failsafe-go
// policies: per-attempt timeout, retry with backoff, and a circuit breaker,
// installed as a gRPC unary client interceptor. The saga's reversal credit goes
// through a second connection with its own policy (see Reverse). Every call, on
// both connections, carries an OAuth2 access token (Lab 7).
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
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/shopspring/decimal"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/telemetry"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

// Breaker metrics (Lab 8). The state as a number so Grafana can graph it and
// alert on it; transitions as a counter, because a breaker that flaps between
// open and closed within one scrape interval never shows up in the gauge.
var (
	breakerState = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "circuit_breaker_state",
		Help: "Circuit breaker state per target: 0 closed, 1 half-open, 2 open.",
	}, []string{"target"})
	breakerTransitions = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "circuit_breaker_transitions_total",
		Help: "Circuit breaker state changes per target.",
	}, []string{"target", "from", "to"})
)

// stateValue maps the breaker state to the circuit_breaker_state value.
func stateValue(s circuitbreaker.State) float64 {
	switch s {
	case circuitbreaker.HalfOpenState:
		return 1
	case circuitbreaker.OpenState:
		return 2
	}
	return 0
}

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
	// The reversal (saga compensation) keeps retrying for up to ReversalMaxDuration,
	// with backoff from ReversalBackoffMin to ReversalBackoffMax, and no breaker.
	ReversalMaxDuration time.Duration
	ReversalBackoffMin  time.Duration
	ReversalBackoffMax  time.Duration
}

// jitterFactor is the same for both policies: a delay varies by up to ±25%.
const jitterFactor = 0.25

// WorstCaseCall is the longest a Debit or Credit can take: every attempt runs
// into its timeout, with the longest backoff (plus jitter) between attempts.
func (s Settings) WorstCaseCall() time.Duration {
	attempts := time.Duration(s.MaxRetries + 1)
	backoff := time.Duration(float64(s.BackoffMax) * (1 + jitterFactor))
	return attempts*s.AttemptTimeout + time.Duration(s.MaxRetries)*backoff
}

// WorstCaseReversal is the longest a Reverse can take: the retry window, plus
// one last attempt that started just before the window closed.
func (s Settings) WorstCaseReversal() time.Duration {
	return s.ReversalMaxDuration + s.AttemptTimeout
}

// WorstCaseSaga is the longest the account calls of one transfer can take:
// debit, credit, and the reversal, each at its worst.
func (s Settings) WorstCaseSaga() time.Duration {
	return 2*s.WorstCaseCall() + s.WorstCaseReversal()
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
	// 30 s covers a restart of the account service (or a pod rescheduled in
	// Kubernetes), which is the usual reason for the forward credit to fail.
	ReversalMaxDuration: 30 * time.Second,
	ReversalBackoffMin:  200 * time.Millisecond,
	ReversalBackoffMax:  5 * time.Second,
}

type Client struct {
	conn    *grpc.ClientConn
	api     accountv1.AccountServiceClient
	breaker circuitbreaker.CircuitBreaker[any]
	// reversalConn carries only Reverse, under the reversal policy.
	reversalConn *grpc.ClientConn
	reversalAPI  accountv1.AccountServiceClient
}

// New connects lazily: no network traffic until the first call, so the transfer
// service starts even while the account service is down. fetch gets the access
// token sent with every call; it runs on the first call, not here, so startup
// does not depend on the authorization server either. opts are extra dial
// options; tests pass an in-memory dialer.
func New(target string, s Settings, fetch FetchToken, log *slog.Logger, opts ...grpc.DialOption) (*Client, error) {
	// A zero duration here would mean "retry forever": the reversal policy has
	// no retry count limit.
	if s.ReversalMaxDuration <= 0 {
		return nil, errors.New("accountclient: Settings.ReversalMaxDuration must be positive")
	}
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
			// No request context: the change belongs to the breaker, not to the
			// call that happened to trigger it.
			log.Warn("circuit breaker state changed", "target", "account",
				"from", e.OldState.String(), "to", e.NewState.String())
			breakerState.WithLabelValues("account").Set(stateValue(e.NewState))
			breakerTransitions.WithLabelValues("account", e.OldState.String(), e.NewState.String()).Inc()
		}).
		Build()
	breakerState.WithLabelValues("account").Set(stateValue(breaker.State()))

	retry := retrypolicy.NewBuilder[any]().
		HandleIf(retryable).
		// Explicit even though retryable already ignores ErrOpen: retrying against
		// an open breaker only burns backoff time and fails anyway.
		AbortOnErrors(circuitbreaker.ErrOpen).
		WithMaxRetries(s.MaxRetries).
		WithBackoff(s.BackoffMin, s.BackoffMax).
		// Jitter spreads the retries of many concurrent transfers so they do not all
		// hit a recovering account service in the same millisecond.
		WithJitterFactor(jitterFactor).
		// Hand the last status error back instead of wrapping it in an ExceededError,
		// so mapError sees the real gRPC code.
		ReturnLastFailure().
		OnRetry(func(e failsafe.ExecutionEvent[any]) {
			log.WarnContext(e.Context(), "retrying account call", "next_attempt", e.Attempts(), "cause", e.LastError())
		}).
		Build()

	// Order matters: retry wraps the breaker, which wraps the timeout. Every attempt
	// gets its own time budget, and every attempt, timeouts included, is counted by
	// the breaker. Same shape as the REST client of Lab 3, now as an interceptor.
	resilience := failsafegrpc.NewUnaryClientInterceptor[any](retry, breaker, timeout.New[any](s.AttemptTimeout))

	// The reversal policy: retry without a breaker, for a longer but bounded window.
	//
	// A reversal runs right after the forward credit failed, and the usual reason
	// for that failure is the account service being down or the breaker being
	// open. Behind the same breaker, the reversal would be rejected instantly and
	// the transfer would end in COMPENSATION_FAILED: money stuck, a person needed.
	// The breaker exists to protect callers from waiting on a dead service and to
	// spare the service a flood of calls; neither weighs as much here. A reversal
	// is rare, and giving up on it costs a manual correction. So it waits for the
	// account service to come back, up to ReversalMaxDuration.
	//
	// Repeating is safe: every attempt carries the same reference
	// (<transfer_id>:reversal), and the account service applies a reference once.
	reversalRetry := retrypolicy.NewBuilder[any]().
		// Every infrastructure failure, Internal included: giving up early is the
		// expensive outcome here. Business codes (NotFound) are still final.
		HandleIf(countsAsFailure).
		WithMaxRetries(-1). // bounded by the duration, not the count
		WithMaxDuration(s.ReversalMaxDuration).
		WithBackoff(s.ReversalBackoffMin, s.ReversalBackoffMax).
		WithJitterFactor(jitterFactor).
		ReturnLastFailure().
		OnRetry(func(e failsafe.ExecutionEvent[any]) {
			log.WarnContext(e.Context(), "retrying reversal", "next_attempt", e.Attempts(), "elapsed", e.ElapsedTime(), "cause", e.LastError())
		}).
		Build()
	reversalResilience := failsafegrpc.NewUnaryClientInterceptor[any](reversalRetry, timeout.New[any](s.AttemptTimeout))

	// One token cache for both connections: they talk to the same service with
	// the same client identity.
	tokens := &tokenCredentials{fetch: fetch}

	// An interceptor belongs to a connection, so the reversal gets a connection of
	// its own. The cost is one more TCP connection to the account service.
	conn, err := dial(target, tokens, resilience, opts)
	if err != nil {
		return nil, err
	}
	reversalConn, err := dial(target, tokens, reversalResilience, opts)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return &Client{
		conn: conn, api: accountv1.NewAccountServiceClient(conn), breaker: breaker,
		reversalConn: reversalConn, reversalAPI: accountv1.NewAccountServiceClient(reversalConn),
	}, nil
}

func dial(target string, tokens *tokenCredentials, resilience grpc.UnaryClientInterceptor, extra []grpc.DialOption) (*grpc.ClientConn, error) {
	opts := append([]grpc.DialOption{
		// Plaintext: fine on a laptop, not in production. Service-to-service calls
		// there go over TLS (or mTLS through a service mesh).
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		// The token is added per attempt, after the interceptors, so a retried
		// attempt carries a valid token too.
		grpc.WithPerRPCCredentials(tokens),
		// First interceptor = outermost: a call repeated with a new token goes
		// through the resiliency policies again. The correlation ID is added once,
		// before all of them.
		grpc.WithChainUnaryInterceptor(telemetry.UnaryClientCorrelation(), tokens.refreshOnUnauthenticated, resilience),
		// Lab 8: one client span per attempt, so retries and timeouts are visible
		// in the trace, and the trace context sent along in the metadata.
		grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
		// After a failed connect, gRPC waits before reconnecting, growing up to
		// 120 s by default. Capped at 5 s so a restarted account service is used
		// again within seconds, which is what the breaker's half-open trials and
		// the reversal retries need.
		grpc.WithConnectParams(grpc.ConnectParams{
			Backoff:           backoff.Config{BaseDelay: time.Second, Multiplier: 1.6, Jitter: 0.2, MaxDelay: 5 * time.Second},
			MinConnectTimeout: 5 * time.Second,
		}),
	}, extra...)
	conn, err := grpc.NewClient(target, opts...)
	if err != nil {
		return nil, fmt.Errorf("account gRPC client for %s: %w", target, err)
	}
	return conn, nil
}

func (c *Client) Close() error { return errors.Join(c.conn.Close(), c.reversalConn.Close()) }

// retryable reports whether the call may be retried:
//   - Unavailable: the server refused the call before running it (the fault
//     injector does exactly that) or no connection could be made.
//   - DeadlineExceeded and our own attempt timeout: the answer was late, and the
//     account service may have applied the mutation anyway. Retrying is safe
//     since Lab 5 because Debit and Credit are idempotent by reference (the
//     transfer ID): a repeated call is not applied twice. Before Lab 5 a
//     timed-out debit was never retried, because a retry could debit twice.
//
// Internal and Unknown are not retried: they come from a bug or a broken
// dependency on the server side, and the same request will most likely fail the
// same way. Business codes are final answers.
func retryable(_ any, err error) bool {
	if errors.Is(err, timeout.ErrExceeded) {
		return true
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded:
		return true
	}
	return false
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

// Reverse credits the amount back to the source account as the saga's
// compensating step, under the reversal policy (see New): no breaker, retries
// for up to ReversalMaxDuration.
func (c *Client) Reverse(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	_, err := c.reversalAPI.Credit(ctx, &accountv1.CreditRequest{Number: number, Amount: amount.String(), Reference: reference})
	return mapError("reverse", number, err)
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
