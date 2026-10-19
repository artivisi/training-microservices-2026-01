package account

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeStore keeps accounts in memory so the HTTP layer is tested without PostgreSQL.
type fakeStore struct {
	accounts map[string]Account
	// applied holds "number type reference" of every mutation, like the unique
	// index on the mutation table.
	applied   map[string]bool
	pingErr   error
	mutateErr error // returned by Mutate when set, e.g. a context error
}

func newFakeStore() *fakeStore {
	return &fakeStore{accounts: map[string]Account{}, applied: map[string]bool{}}
}

func (f *fakeStore) Create(_ context.Context, req CreateRequest) (Account, error) {
	if _, ok := f.accounts[req.Number]; ok {
		return Account{}, ErrAlreadyExists
	}
	a := Account{Number: req.Number, OwnerName: req.OwnerName, Balance: req.InitialBalance, CreatedAt: time.Now()}
	f.accounts[a.Number] = a
	return a, nil
}

func (f *fakeStore) Get(_ context.Context, number string) (Account, error) {
	a, ok := f.accounts[number]
	if !ok {
		return Account{}, ErrNotFound
	}
	return a, nil
}

func (f *fakeStore) List(context.Context) ([]Account, error) {
	var out []Account
	for _, a := range f.accounts {
		out = append(out, a)
	}
	return out, nil
}

func (f *fakeStore) Mutate(_ context.Context, number string, t MutationType, req MutationRequest) (Account, bool, error) {
	if f.mutateErr != nil {
		return Account{}, false, f.mutateErr
	}
	a, ok := f.accounts[number]
	if !ok {
		return Account{}, false, ErrNotFound
	}
	key := number + " " + string(t) + " " + req.Reference
	if f.applied[key] {
		return a, false, nil
	}
	if t == Debit {
		if a.Balance.LessThan(req.Amount) {
			return Account{}, false, ErrInsufficientFunds
		}
		a.Balance = a.Balance.Sub(req.Amount)
	} else {
		a.Balance = a.Balance.Add(req.Amount)
	}
	f.accounts[number] = a
	f.applied[key] = true
	return a, true, nil
}

func (f *fakeStore) Ping(context.Context) error { return f.pingErr }

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
	return rec
}

func TestAccountAPI(t *testing.T) {
	h := NewHandler(newFakeStore(), slog.New(slog.NewTextHandler(io.Discard, nil))).Routes()

	tests := []struct {
		name, method, path, body string
		wantStatus               int
		wantBody                 string
	}{
		{"create", "POST", "/accounts", `{"number":"1234567890","owner_name":"Budi","initial_balance":"500000"}`, 201, `"balance":"500000"`},
		{"duplicate", "POST", "/accounts", `{"number":"1234567890","owner_name":"Budi","initial_balance":"0"}`, 409, "already exists"},
		{"invalid fields", "POST", "/accounts", `{"number":"12","owner_name":" ","initial_balance":"-1"}`, 400, `"number":"must be exactly 10 digits"`},
		{"three decimal places", "POST", "/accounts", `{"number":"1234567891","owner_name":"Budi","initial_balance":"100.005"}`, 400, `"initial_balance":"must have at most 2 decimal places"`},
		{"tiny exponent", "POST", "/accounts", `{"number":"1234567891","owner_name":"Budi","initial_balance":1e-3}`, 400, `"initial_balance":"must have at most 2 decimal places"`},
		{"above numeric(19,2)", "POST", "/accounts", `{"number":"1234567891","owner_name":"Budi","initial_balance":"100000000000000000"}`, 400, `"initial_balance":"must be less than 10^17"`},
		{"unknown field", "POST", "/accounts", `{"nomor":"1234567890"}`, 400, "unknown field"},
		{"get", "GET", "/accounts/1234567890", "", 200, `"owner_name":"Budi"`},
		{"not found", "GET", "/accounts/0000000000", "", 404, "not found"},
		{"wrong method", "DELETE", "/accounts/1234567890", "", 405, ""},
		{"no debit over REST", "POST", "/accounts/1234567890/debit", `{"amount":"1","reference":"T-1"}`, 404, ""},
		{"liveness", "GET", "/healthz", "", 200, "UP"},
		{"readiness", "GET", "/readyz", "", 200, `"database":"UP"`},
	}
	// Subtests run in order and share the handler: "duplicate" and "get" rely on "create".
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, tc.method, tc.path, tc.body)
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body: %s", rec.Code, tc.wantStatus, rec.Body)
			}
			if !strings.Contains(rec.Body.String(), tc.wantBody) {
				t.Fatalf("body %q does not contain %q", rec.Body, tc.wantBody)
			}
		})
	}
}

func TestReadinessDown(t *testing.T) {
	store := newFakeStore()
	store.pingErr = context.DeadlineExceeded
	h := NewHandler(store, slog.New(slog.NewTextHandler(io.Discard, nil))).Routes()
	if rec := do(t, h, "GET", "/readyz", ""); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}
