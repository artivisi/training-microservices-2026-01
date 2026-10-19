package transfer

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
)

type Service struct {
	store    Store
	accounts AccountClient
	log      *slog.Logger
}

func NewService(store Store, accounts AccountClient, log *slog.Logger) *Service {
	return &Service{store: store, accounts: accounts, log: log}
}

// Execute records the transfer, debits the source, then credits the destination.
// The returned error is the reason the transfer FAILED; the transfer itself is
// returned whenever it was recorded.
//
// Known gap: debit and credit are two calls to another service, with no shared
// database transaction. When the credit fails after a successful debit, the money
// has left the source account and arrived nowhere. The transfer is marked FAILED
// and logged for manual reversal.
func (s *Service) Execute(ctx context.Context, req CreateRequest) (Transfer, error) {
	t, err := s.store.Create(ctx, req)
	if err != nil {
		return Transfer{}, fmt.Errorf("record transfer: %w", err)
	}

	if err := s.accounts.Debit(ctx, t.FromAccount, t.Amount, t.ID); err != nil {
		return s.fail(ctx, t, "debit failed", err)
	}
	if err := s.accounts.Credit(ctx, t.ToAccount, t.Amount, t.ID); err != nil {
		s.log.Error("credit failed after debit, source account needs manual reversal",
			"transfer_id", t.ID, "from_account", t.FromAccount, "amount", t.Amount, "error", err)
		return s.fail(ctx, t, "credit failed after debit", err)
	}

	done, err := s.store.Finish(ctx, t.ID, Completed, "")
	if err != nil {
		return t, fmt.Errorf("mark transfer completed: %w", err)
	}
	s.log.Info("transfer completed", "transfer_id", t.ID, "amount", t.Amount)
	return done, nil
}

func (s *Service) fail(ctx context.Context, t Transfer, step string, cause error) (Transfer, error) {
	reason := fmt.Sprintf("%s: %v", step, cause)
	failed, err := s.store.Finish(ctx, t.ID, Failed, reason)
	if err != nil {
		return t, errors.Join(cause, fmt.Errorf("mark transfer failed: %w", err))
	}
	s.log.Warn("transfer failed", "transfer_id", t.ID, "reason", reason)
	return failed, cause
}

func (s *Service) Get(ctx context.Context, id string) (Transfer, error) {
	return s.store.Get(ctx, id)
}

func (s *Service) Ping(ctx context.Context) error { return s.store.Ping(ctx) }
