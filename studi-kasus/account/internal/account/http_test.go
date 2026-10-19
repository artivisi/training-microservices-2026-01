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
	pingErr  error
}

func newFakeStore() *fakeStore { return &fakeStore{accounts: map[string]Account{}} }

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

func (f *fakeStore) Mutate(_ context.Context, number string, t MutationType, req MutationRequest) (Account, error) {
	a, ok := f.accounts[number]
	if !ok {
		return Account{}, ErrNotFound
	}
	if t == Debit {
		if a.Balance.LessThan(req.Amount) {
			return Account{}, ErrInsufficientFunds
		}
		a.Balance = a.Balance.Sub(req.Amount)
	} else {
		a.Balance = a.Balance.Add(req.Amount)
	}
	f.accounts[number] = a
	return a, nil
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
		{"unknown field", "POST", "/accounts", `{"nomor":"1234567890"}`, 400, "unknown field"},
		{"get", "GET", "/accounts/1234567890", "", 200, `"owner_name":"Budi"`},
		{"not found", "GET", "/accounts/0000000000", "", 404, "not found"},
		{"wrong method", "DELETE", "/accounts/1234567890", "", 405, ""},
		{"debit", "POST", "/accounts/1234567890/debit", `{"amount":"200000","reference":"T-1"}`, 200, `"balance":"300000"`},
		{"credit", "POST", "/accounts/1234567890/credit", `{"amount":"50000","reference":"T-2"}`, 200, `"balance":"350000"`},
		{"insufficient funds", "POST", "/accounts/1234567890/debit", `{"amount":"350000.01","reference":"T-3"}`, 422, "insufficient funds"},
		{"debit unknown account", "POST", "/accounts/0000000000/debit", `{"amount":"1","reference":"T-4"}`, 404, "not found"},
		{"invalid mutation", "POST", "/accounts/1234567890/credit", `{"amount":"0","reference":""}`, 400, `"amount":"must be greater than zero"`},
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
