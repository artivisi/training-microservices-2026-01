package transfer

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"testing"

	"github.com/shopspring/decimal"
)

type fakeStore struct {
	transfers map[string]Transfer
	seq       int
}

func (f *fakeStore) Create(_ context.Context, req CreateRequest) (Transfer, error) {
	f.seq++
	t := Transfer{ID: fmt.Sprint(f.seq), FromAccount: req.FromAccount, ToAccount: req.ToAccount, Amount: req.Amount, Status: Pending}
	f.transfers[t.ID] = t
	return t, nil
}

func (f *fakeStore) Finish(_ context.Context, id string, status Status, reason string) (Transfer, error) {
	t := f.transfers[id]
	t.Status, t.FailureReason = status, reason
	f.transfers[id] = t
	return t, nil
}

func (f *fakeStore) Get(_ context.Context, id string) (Transfer, error) {
	t, ok := f.transfers[id]
	if !ok {
		return Transfer{}, ErrNotFound
	}
	return t, nil
}

func (f *fakeStore) Ping(context.Context) error { return nil }

// fakeAccounts returns the configured error for each operation and records the calls.
type fakeAccounts struct {
	debitErr, creditErr error
	calls               []string
}

func (f *fakeAccounts) Debit(_ context.Context, number string, amount decimal.Decimal, ref string) error {
	f.calls = append(f.calls, "debit "+number)
	return f.debitErr
}

func (f *fakeAccounts) Credit(_ context.Context, number string, amount decimal.Decimal, ref string) error {
	f.calls = append(f.calls, "credit "+number)
	return f.creditErr
}

func TestExecute(t *testing.T) {
	req := CreateRequest{FromAccount: "1111111111", ToAccount: "2222222222", Amount: decimal.RequireFromString("100000")}
	unavailable := errors.New("connection refused")

	tests := []struct {
		name       string
		accounts   *fakeAccounts
		wantStatus Status
		wantErr    error
		wantCalls  int
	}{
		{"success", &fakeAccounts{}, Completed, nil, 2},
		{"insufficient funds stops before credit", &fakeAccounts{debitErr: ErrInsufficientFunds}, Failed, ErrInsufficientFunds, 1},
		{"credit fails after debit", &fakeAccounts{creditErr: unavailable}, Failed, ErrCreditFailed, 2},
		{"open circuit breaker fails the transfer", &fakeAccounts{debitErr: ErrAccountUnavailable}, Failed, ErrAccountUnavailable, 1},
		{"breaker opens between debit and credit", &fakeAccounts{creditErr: ErrAccountUnavailable}, Failed, ErrCreditFailed, 2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeStore{transfers: map[string]Transfer{}}
			svc := NewService(store, tc.accounts, slog.New(slog.NewTextHandler(io.Discard, nil)))

			got, err := svc.Execute(context.Background(), req)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
			if got.Status != tc.wantStatus {
				t.Fatalf("status = %s, want %s", got.Status, tc.wantStatus)
			}
			if stored := store.transfers[got.ID]; stored.Status != tc.wantStatus {
				t.Fatalf("stored status = %s, want %s", stored.Status, tc.wantStatus)
			}
			if len(tc.accounts.calls) != tc.wantCalls {
				t.Fatalf("account calls = %v, want %d calls", tc.accounts.calls, tc.wantCalls)
			}
		})
	}
}

func TestValidate(t *testing.T) {
	err := CreateRequest{FromAccount: "1111111111", ToAccount: "1111111111", Amount: decimal.Zero}.Validate()
	v, ok := err.(ValidationError)
	if !ok || v["to_account"] == "" || v["amount"] == "" {
		t.Fatalf("got %v, want errors on to_account and amount", err)
	}
}

// TestValidateAmount: the amount must fit numeric(19,2) exactly, or the database
// would round it before the debit.
func TestValidateAmount(t *testing.T) {
	tests := []struct {
		amount string
		want   string
	}{
		{"100.5", ""},
		{"100.50", ""},
		{"100.005", "must have at most 2 decimal places"},
		{"1e-3", "must have at most 2 decimal places"},
		{"100000000000000000", "must be less than 10^17"},
	}
	for _, tc := range tests {
		t.Run(tc.amount, func(t *testing.T) {
			err := CreateRequest{FromAccount: "1111111111", ToAccount: "2222222222", Amount: decimal.RequireFromString(tc.amount)}.Validate()
			var got string
			if v, ok := err.(ValidationError); ok {
				got = v["amount"]
			}
			if got != tc.want {
				t.Fatalf("amount error = %q, want %q", got, tc.want)
			}
		})
	}
}
