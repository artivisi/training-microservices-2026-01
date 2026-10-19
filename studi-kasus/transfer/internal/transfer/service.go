package transfer

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
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
func (s *Service) Execute(ctx context.Context, req CreateRequest) (Transfer, error) {
	t, err := s.store.Create(ctx, req)
	if err != nil {
		return Transfer{}, fmt.Errorf("record transfer: %w", err)
	}

	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
		// Known gap: when every attempt timed out, the debit may still have been
		// applied, and FAILED is then wrong. Compensating blindly is no answer
		// either: a reversal of a debit that never happened creates money. The
		// production answer is a reconciliation job that repeats the debit with
		// the same reference (idempotent) until it gets a definite answer, then
		// continues or reverses. Here it stays FAILED and is logged.
		return s.finish(ctx, t, Pending, Failed, fmt.Sprintf("debit failed: %v", err), EventFailed, err)
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
	reason := fmt.Sprintf("credit failed: %v", cause)
	s.log.Warn("credit failed after debit, reversing the debit", "transfer_id", t.ID, "error", cause)

	if err := s.accounts.Reverse(ctx, t.FromAccount, t.Amount, t.ID+ReversalSuffix); err != nil {
		// The source account is short by the amount. The reversal is idempotent, so
		// repeating it later is safe; production runs that from a background job.
		// Here a person repeats it. No event: the customer outcome is not final yet.
		s.log.Error("compensation failed, source account needs manual reversal",
			"transfer_id", t.ID, "from_account", t.FromAccount, "amount", t.Amount, "error", err)
		reason = fmt.Sprintf("%s; reversal failed: %v", reason, err)
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
		s.log.Warn("transfer not completed", "transfer_id", t.ID, "status", to, "reason", reason)
	}
	return done, cause
}

func (s *Service) Get(ctx context.Context, id string) (Transfer, error) {
	return s.store.Get(ctx, id)
}

func (s *Service) Ping(ctx context.Context) error { return s.store.Ping(ctx) }
