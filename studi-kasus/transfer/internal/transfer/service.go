package transfer

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
)

// ReversalSuffix marks the compensating credit. The reversal needs its own
// reference: under the transfer ID alone, the account service would treat it
// as a repeat of a credit with that ID (see the idempotency rule in
// account.proto). A retried reversal reuses this reference and is therefore
// applied once as well.
const ReversalSuffix = ":reversal"

type Service struct {
	store    Store
	accounts AccountClient
	log      *slog.Logger
}

func NewService(store Store, accounts AccountClient, log *slog.Logger) *Service {
	return &Service{store: store, accounts: accounts, log: log}
}

// Execute runs the transfer saga, orchestrated from here:
//
//  1. record the transfer                -> PENDING
//  2. debit the source                   -> DEBITED   (failed: FAILED)
//  3. credit the destination             -> COMPLETED (failed: step 4)
//  4. compensate: credit the source back -> COMPENSATED
//
// There is no transaction across the two account calls; every step is a local
// transaction in one service, and a failed step is undone by a compensating
// step instead of a rollback. Each end state and its event are stored together
// (Store.Transition), and the outbox relay publishes the event afterwards.
//
// The returned error is the reason the transfer did not complete; the transfer
// itself is returned whenever it was recorded.
//
// idempotencyKey (optional, from the Idempotency-Key header) makes a retried
// request safe: when the key was seen before, the saga does not run again and
// the original transfer is returned in whatever state it is now, with the
// second result (replayed) true. The error is then the one the original request
// ended with (see replayOutcome), so the HTTP layer answers the replay with the
// same status code. A request still in progress comes back as PENDING or
// DEBITED with ErrInProgress; the client polls GET /transfers/{id}.
//
// A row left PENDING or DEBITED by a crash (SIGKILL between two steps) is never
// resumed: nothing in this lab picks it up again (see the gap in the Lab 5
// README). A replay of its key keeps returning that state with ErrInProgress.
func (s *Service) Execute(ctx context.Context, req CreateRequest, idempotencyKey string) (Transfer, bool, error) {
	t, created, err := s.store.Create(ctx, req, idempotencyKey)
	if err != nil {
		return Transfer{}, false, fmt.Errorf("record transfer: %w", err)
	}
	if !created {
		if !t.SameRequest(req) {
			s.log.Warn("idempotency key reused with a different request",
				"idempotency_key", idempotencyKey, "transfer_id", t.ID)
			return Transfer{}, false, ErrIdempotencyKeyReused
		}
		s.log.Info("idempotent replay, returning the original transfer",
			"idempotency_key", idempotencyKey, "transfer_id", t.ID, "status", t.Status)
		return t, true, replayOutcome(t)
	}
	t, err = s.run(ctx, t)
	return t, false, err
}

// replayOutcome rebuilds, from the stored transfer, the error the original
// request ended with: nil for COMPLETED, ErrReversalFailed for
// COMPENSATION_FAILED, ErrInProgress for PENDING and DEBITED. For FAILED and
// COMPENSATED the cause is only kept as text in failure_reason ("debit failed:
// insufficient funds"); publicReason puts the sentinel's message last. Rows
// written before Lab 7 hold the raw error ("debit failed: debit 1111111111:
// insufficient funds"), which ends the same way. Anything else was a dependency
// failure, the 502 of the original request.
func replayOutcome(t Transfer) error {
	switch t.Status {
	case Completed:
		return nil
	case Pending, Debited:
		return ErrInProgress
	case CompensationFailed:
		return fmt.Errorf("%w: %s", ErrReversalFailed, t.FailureReason)
	}
	for _, cause := range []error{ErrAccountNotFound, ErrInsufficientFunds, ErrAccountUnavailable} {
		if strings.HasSuffix(t.FailureReason, ": "+cause.Error()) {
			return fmt.Errorf("%s: %w", t.Status, cause)
		}
	}
	return fmt.Errorf("%s: %s", t.Status, t.FailureReason)
}

// run executes the saga steps on a freshly recorded transfer.
func (s *Service) run(ctx context.Context, t Transfer) (Transfer, error) {

	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
		// Known gap: when every attempt timed out, the debit may still have been
		// applied, and FAILED is then wrong. Compensating blindly is no answer
		// either: a reversal of a debit that never happened creates money. The
		// production answer is a reconciliation job that repeats the debit with
		// the same reference (idempotent) until it gets a definite answer, then
		// continues or reverses. Here it stays FAILED and is logged.
		return s.finish(ctx, t, Pending, Failed, "debit failed: "+publicReason(err), EventFailed, err)
	}

	debited, err := s.store.Transition(ctx, t.ID, Pending, Debited, "", "")
	if err != nil {
		// The money left the source but our own database did not record it. The
		// transfer stays PENDING; the reconciliation above would find it.
		s.log.Error("debit applied but not recorded", "transfer_id", t.ID, "error", err)
		return t, fmt.Errorf("mark transfer debited: %w", err)
	}

	if err := s.accounts.Credit(ctx, debited.ToAccount, debited.Amount, debited.ID); err != nil {
		return s.compensate(ctx, debited, err)
	}

	return s.finish(ctx, debited, Debited, Completed, "", EventCompleted, nil)
}

// compensate undoes the debit by crediting the amount back to the source.
//
// The reversal goes through AccountClient.Reverse, not Credit: the forward credit
// has often just failed because the account service is down, which may well have
// opened the shared breaker. Reverse has no breaker and keeps retrying for a
// while (see accountclient), so a short outage ends in COMPENSATED instead of
// COMPENSATION_FAILED.
//
// Same ambiguity as the debit: a credit that timed out on every attempt may have
// arrived, and the reversal then gives the money back twice over (destination
// and source). Business rejections (destination not found) and an open breaker
// are certain not to have been applied; the reconciliation job resolves the rest.
func (s *Service) compensate(ctx context.Context, t Transfer, cause error) (Transfer, error) {
	reason := "credit failed: " + publicReason(cause)
	s.log.Warn("credit failed after debit, reversing the debit", "transfer_id", t.ID, "error", cause)

	if err := s.accounts.Reverse(ctx, t.FromAccount, t.Amount, t.ID+ReversalSuffix); err != nil {
		// The source account is short by the amount. The reversal is idempotent, so
		// repeating it later is safe; production runs that from a background job.
		// Here a person repeats it. No event: the customer outcome is not final yet.
		s.log.Error("compensation failed, source account needs manual reversal",
			"transfer_id", t.ID, "from_account", t.FromAccount, "amount", t.Amount, "error", err)
		reason = reason + "; reversal failed: " + publicReason(err)
		return s.finish(ctx, t, Debited, CompensationFailed, reason, "", fmt.Errorf("%w: %w", ErrReversalFailed, errors.Join(cause, err)))
	}
	return s.finish(ctx, t, Debited, Compensated, reason, EventCompensated, cause)
}

// finish stores the end state with its event. cause is the saga's outcome error
// (nil on success) and is returned as is, so the HTTP layer can map it.
func (s *Service) finish(ctx context.Context, t Transfer, from, to Status, reason string, event EventType, cause error) (Transfer, error) {
	done, err := s.store.Transition(ctx, t.ID, from, to, reason, event)
	if err != nil {
		s.log.Error("saga end state not recorded", "transfer_id", t.ID, "status", to, "error", err)
		return t, errors.Join(cause, fmt.Errorf("mark transfer %s: %w", to, err))
	}
	switch to {
	case Completed:
		s.log.Info("transfer completed", "transfer_id", t.ID, "amount", t.Amount)
	case CompensationFailed:
		// logged in compensate
	default:
		s.log.Warn("transfer not completed", "transfer_id", t.ID, "status", to, "reason", reason, "error", cause)
	}
	return done, cause
}

// publicReason is the failure text stored in failure_reason, returned by the
// API and carried in the events (Lab 7). Business outcomes are named; any other
// error becomes one generic phrase, because its text can hold internal
// addresses, ports and library messages (e.g. "dial tcp 10.0.3.7:9091:
// connection refused") that the caller cannot act on and an attacker can
// use. The full error is in the log next to the transfer ID.
func publicReason(err error) string {
	switch {
	case errors.Is(err, ErrInsufficientFunds):
		return ErrInsufficientFunds.Error()
	case errors.Is(err, ErrAccountNotFound):
		return ErrAccountNotFound.Error()
	case errors.Is(err, ErrAccountUnavailable):
		return ErrAccountUnavailable.Error()
	default:
		return "account service error"
	}
}

func (s *Service) Get(ctx context.Context, id string) (Transfer, error) {
	return s.store.Get(ctx, id)
}

func (s *Service) Ping(ctx context.Context) error { return s.store.Ping(ctx) }
