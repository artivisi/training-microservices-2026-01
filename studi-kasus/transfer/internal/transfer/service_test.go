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
	keys      map[string]string // idempotency key -> transfer ID
	events    []EventType
	seq       int
}

func newFakeStore() *fakeStore {
	return &fakeStore{transfers: map[string]Transfer{}, keys: map[string]string{}}
}

func (f *fakeStore) Create(_ context.Context, req CreateRequest, key string) (Transfer, bool, error) {
	if id, ok := f.keys[key]; ok && key != "" {
		return f.transfers[id], false, nil
	}
	f.seq++
	t := Transfer{ID: fmt.Sprint(f.seq), FromAccount: req.FromAccount, ToAccount: req.ToAccount, Amount: req.Amount, Status: Pending}
	f.transfers[t.ID] = t
	if key != "" {
		f.keys[key] = t.ID
	}
	return t, true, nil
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
			store := newFakeStore()
			accounts := &fakeAccounts{errs: tc.errs}
			svc := NewService(store, accounts, slog.New(slog.NewTextHandler(io.Discard, nil)))

			got, _, err := svc.Execute(context.Background(), req, "")
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

func TestExecuteIdempotencyKey(t *testing.T) {
	req := CreateRequest{FromAccount: "1111111111", ToAccount: "2222222222", Amount: decimal.RequireFromString("100000")}
	store := newFakeStore()
	accounts := &fakeAccounts{}
	svc := NewService(store, accounts, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx := context.Background()

	first, replayed, err := svc.Execute(ctx, req, "key-1")
	if err != nil || replayed || first.Status != Completed {
		t.Fatalf("first: %+v replayed=%v err=%v, want COMPLETED", first, replayed, err)
	}

	// Same key, same body written differently: the original, no new account calls.
	same := req
	same.Amount = decimal.RequireFromString("100000.00")
	again, replayed, err := svc.Execute(ctx, same, "key-1")
	if err != nil || !replayed || again.ID != first.ID {
		t.Fatalf("replay: %+v replayed=%v err=%v, want transfer %s replayed", again, replayed, err, first.ID)
	}
	if len(accounts.calls) != 2 {
		t.Fatalf("account calls = %q, want only the first transfer's debit and credit", accounts.calls)
	}

	// Same key, different body.
	other := req
	other.Amount = decimal.RequireFromString("5")
	if _, _, err := svc.Execute(ctx, other, "key-1"); !errors.Is(err, ErrIdempotencyKeyReused) {
		t.Fatalf("err = %v, want ErrIdempotencyKeyReused", err)
	}

	// Without a key every request is a new transfer.
	a, _, _ := svc.Execute(ctx, req, "")
	b, _, _ := svc.Execute(ctx, req, "")
	if a.ID == b.ID || a.ID == first.ID {
		t.Fatalf("ids %s, %s, %s: want three different transfers", first.ID, a.ID, b.ID)
	}
}

// TestReplayOutcome: a replay gets back the error class of the original
// request, rebuilt from the stored status and failure_reason.
func TestReplayOutcome(t *testing.T) {
	tests := []struct {
		status Status
		reason string
		want   error
	}{
		{Completed, "", nil},
		{Pending, "", ErrInProgress},
		{Debited, "", ErrInProgress},
		{Failed, "debit failed: debit 1111111111: insufficient funds", ErrInsufficientFunds},
		{Failed, "debit failed: debit 1111111111: account service unavailable", ErrAccountUnavailable},
		{Compensated, "credit failed: credit 9999999999: account not found", ErrAccountNotFound},
		{Compensated, "credit failed: credit 2222222222: account service unavailable", ErrAccountUnavailable},
		{CompensationFailed, "credit failed: x; reversal failed: y", ErrReversalFailed},
	}
	for _, tc := range tests {
		err := replayOutcome(Transfer{Status: tc.status, FailureReason: tc.reason})
		if !errors.Is(err, tc.want) || (tc.want == nil && err != nil) {
			t.Errorf("%s %q: err = %v, want %v", tc.status, tc.reason, err, tc.want)
		}
	}
	// A transport failure maps to none of the sentinels: the 502 of the original.
	err := replayOutcome(Transfer{Status: Failed, FailureReason: "debit failed: debit 1111111111: rpc error: code = Unavailable"})
	for _, s := range []error{ErrAccountNotFound, ErrInsufficientFunds, ErrAccountUnavailable, ErrReversalFailed, ErrInProgress} {
		if err == nil || errors.Is(err, s) {
			t.Fatalf("transport failure: err = %v, want a plain error", err)
		}
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

// The API and the events show what happened, never internal addresses (Lab 7).
func TestFailureReasonIsGeneric(t *testing.T) {
	req := CreateRequest{FromAccount: "1111111111", ToAccount: "2222222222", Amount: decimal.RequireFromString("100000")}
	internal := errors.New("rpc error: code = Unavailable desc = dial tcp 10.0.3.7:9091: connect: connection refused")
	tests := []struct {
		name       string
		errs       map[string]error
		wantReason string
	}{
		{"infrastructure error", map[string]error{"debit 1111111111": internal}, "debit failed: account service error"},
		{"business rejection", map[string]error{"debit 1111111111": fmt.Errorf("debit 1111111111: %w", ErrInsufficientFunds)},
			"debit failed: insufficient funds"},
		{"compensation failed", map[string]error{"credit 2222222222": ErrAccountNotFound, "reverse 1111111111": internal},
			"credit failed: account not found; reversal failed: account service error"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			svc := NewService(newFakeStore(), &fakeAccounts{errs: tc.errs}, slog.New(slog.NewTextHandler(io.Discard, nil)))
			got, _, _ := svc.Execute(context.Background(), req, "")
			if got.FailureReason != tc.wantReason {
				t.Fatalf("failure_reason = %q, want %q", got.FailureReason, tc.wantReason)
			}
		})
	}
}
