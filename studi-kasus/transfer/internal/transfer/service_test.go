package transfer

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"slices"
	"testing"

	"github.com/shopspring/decimal"
)

// fakeStore keeps transfers in memory and records the outbox events written
// with each transition.
type fakeStore struct {
	transfers map[string]Transfer
	events    []EventType
	seq       int
}

func (f *fakeStore) Create(_ context.Context, req CreateRequest) (Transfer, error) {
	f.seq++
	t := Transfer{ID: fmt.Sprint(f.seq), FromAccount: req.FromAccount, ToAccount: req.ToAccount, Amount: req.Amount, Status: Pending}
	f.transfers[t.ID] = t
	return t, nil
}

func (f *fakeStore) Transition(_ context.Context, id string, from, to Status, reason string, event EventType) (Transfer, error) {
	t := f.transfers[id]
	if t.Status != from {
		return Transfer{}, ErrStaleState
	}
	t.Status, t.FailureReason = to, reason
	f.transfers[id] = t
	if event != "" {
		f.events = append(f.events, event)
	}
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

// fakeAccounts answers each call by its description ("debit 1111111111",
// "credit 2222222222", "reverse 1111111111") and records the calls with their
// references.
type fakeAccounts struct {
	errs  map[string]error
	calls []string
}

func (f *fakeAccounts) Debit(_ context.Context, number string, _ decimal.Decimal, ref string) error {
	return f.call("debit "+number, ref)
}

func (f *fakeAccounts) Credit(_ context.Context, number string, _ decimal.Decimal, ref string) error {
	return f.call("credit "+number, ref)
}

func (f *fakeAccounts) Reverse(_ context.Context, number string, _ decimal.Decimal, ref string) error {
	return f.call("reverse "+number, ref)
}

func (f *fakeAccounts) call(desc, ref string) error {
	f.calls = append(f.calls, desc+" ref="+ref)
	return f.errs[desc]
}

func TestExecuteSaga(t *testing.T) {
	req := CreateRequest{FromAccount: "1111111111", ToAccount: "2222222222", Amount: decimal.RequireFromString("100000")}
	unavailable := errors.New("connection refused")

	tests := []struct {
		name       string
		errs       map[string]error
		wantStatus Status
		wantErr    error
		wantCalls  []string
		wantEvents []EventType
	}{
		{"success", nil, Completed, nil,
			[]string{"debit 1111111111 ref=1", "credit 2222222222 ref=1"},
			[]EventType{EventCompleted}},
		{"insufficient funds stops before credit",
			map[string]error{"debit 1111111111": ErrInsufficientFunds}, Failed, ErrInsufficientFunds,
			[]string{"debit 1111111111 ref=1"},
			[]EventType{EventFailed}},
		{"open circuit breaker fails the transfer",
			map[string]error{"debit 1111111111": ErrAccountUnavailable}, Failed, ErrAccountUnavailable,
			[]string{"debit 1111111111 ref=1"},
			[]EventType{EventFailed}},
		{"credit fails after debit: debit reversed",
			map[string]error{"credit 2222222222": ErrAccountNotFound}, Compensated, ErrAccountNotFound,
			[]string{"debit 1111111111 ref=1", "credit 2222222222 ref=1", "reverse 1111111111 ref=1:reversal"},
			[]EventType{EventCompensated}},
		// The breaker opened between debit and credit. The reversal does not go
		// through that breaker (Reverse), so it is still sent.
		{"breaker opens between debit and credit: debit reversed",
			map[string]error{"credit 2222222222": ErrAccountUnavailable}, Compensated, ErrAccountUnavailable,
			[]string{"debit 1111111111 ref=1", "credit 2222222222 ref=1", "reverse 1111111111 ref=1:reversal"},
			[]EventType{EventCompensated}},
		{"reversal fails too: manual",
			map[string]error{"credit 2222222222": unavailable, "reverse 1111111111": unavailable}, CompensationFailed, ErrReversalFailed,
			[]string{"debit 1111111111 ref=1", "credit 2222222222 ref=1", "reverse 1111111111 ref=1:reversal"},
			nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeStore{transfers: map[string]Transfer{}}
			accounts := &fakeAccounts{errs: tc.errs}
			svc := NewService(store, accounts, slog.New(slog.NewTextHandler(io.Discard, nil)))

			got, err := svc.Execute(context.Background(), req)
			if !errors.Is(err, tc.wantErr) || (tc.wantErr == nil && err != nil) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
			if got.Status != tc.wantStatus {
				t.Fatalf("status = %s, want %s", got.Status, tc.wantStatus)
			}
			if stored := store.transfers[got.ID]; stored.Status != tc.wantStatus {
				t.Fatalf("stored status = %s, want %s", stored.Status, tc.wantStatus)
			}
			if !slices.Equal(accounts.calls, tc.wantCalls) {
				t.Fatalf("account calls = %q, want %q", accounts.calls, tc.wantCalls)
			}
			if !slices.Equal(store.events, tc.wantEvents) {
				t.Fatalf("outbox events = %v, want %v", store.events, tc.wantEvents)
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
