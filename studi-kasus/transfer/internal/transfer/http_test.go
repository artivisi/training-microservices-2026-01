package transfer

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/shopspring/decimal"
)

// allowAll stands in for the JWT middleware, which has its own tests (internal/auth).
func allowAll(_ string, next http.Handler) http.Handler { return next }

func TestRoutesRequireScopes(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	var asked []string
	record := func(scope string, _ http.Handler) http.Handler {
		asked = append(asked, scope)
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusForbidden) })
	}
	h := NewHandler(NewService(newFakeStore(), &fakeAccounts{}, log), log).Routes(record)
	if got := strings.Join(asked, ","); got != ScopeWrite+","+ScopeRead {
		t.Fatalf("scopes = %s, want POST write, GET read", got)
	}
	for _, path := range []string{"/healthz", "/readyz"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s = %d, want 200 without a token", path, rec.Code)
		}
	}
}

// TestCreateStatus checks the HTTP status for each outcome. 503 is reserved for
// "no money moved, safe to retry": the breaker refused the debit, or refused the
// credit and the debit was reversed. A failed reversal is a 500 whatever the
// cause, never a 503.
//
// The same cases run twice with an Idempotency-Key: the replay must answer with
// the status of the first request, plus Idempotent-Replayed: true, without
// calling the account service again.
func TestCreateStatus(t *testing.T) {
	tests := []struct {
		name     string
		accounts *fakeAccounts
		want     int
	}{
		{"success", &fakeAccounts{}, http.StatusCreated},
		{"insufficient funds", fails("debit 1111111111", ErrInsufficientFunds), http.StatusUnprocessableEntity},
		{"breaker open before debit", fails("debit 1111111111", ErrAccountUnavailable), http.StatusServiceUnavailable},
		{"breaker opens between debit and credit, reversed", fails("credit 2222222222", ErrAccountUnavailable), http.StatusServiceUnavailable},
		{"destination not found, reversed", fails("credit 2222222222", ErrAccountNotFound), http.StatusUnprocessableEntity},
		{"credit fails on transport error, reversed", fails("credit 2222222222", errors.New("connection refused")), http.StatusBadGateway},
		{"debit fails on transport error", fails("debit 1111111111", errors.New("connection refused")), http.StatusBadGateway},
		{"breaker open on credit, reversal fails", &fakeAccounts{errs: map[string]error{
			"credit 2222222222": ErrAccountUnavailable, "reverse 1111111111": errors.New("connection refused")}},
			http.StatusInternalServerError},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			log := slog.New(slog.NewTextHandler(io.Discard, nil))
			svc := NewService(newFakeStore(), tc.accounts, log)
			srv := httptest.NewServer(NewHandler(svc, log).Routes(allowAll))
			defer srv.Close()

			first := post(t, srv.URL, "k-1")
			if first.StatusCode != tc.want || first.Header.Get("Idempotent-Replayed") != "" {
				t.Fatalf("first: status = %d, replayed = %q, want %d", first.StatusCode, first.Header.Get("Idempotent-Replayed"), tc.want)
			}
			calls := len(tc.accounts.calls)
			replay := post(t, srv.URL, "k-1")
			if replay.StatusCode != tc.want || replay.Header.Get("Idempotent-Replayed") != "true" {
				t.Fatalf("replay: status = %d, replayed = %q, want %d, true", replay.StatusCode, replay.Header.Get("Idempotent-Replayed"), tc.want)
			}
			if len(tc.accounts.calls) != calls {
				t.Fatalf("account calls = %q, want none for the replay", tc.accounts.calls[calls:])
			}
		})
	}
}

func fails(desc string, err error) *fakeAccounts {
	return &fakeAccounts{errs: map[string]error{desc: err}}
}

func post(t *testing.T, url, key string) *http.Response {
	t.Helper()
	body := `{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}`
	req, err := http.NewRequest(http.MethodPost, url+"/transfers", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Idempotency-Key", key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp
}

func TestCreateIdempotencyKeyHTTP(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	store := newFakeStore()
	h := NewHandler(NewService(store, &fakeAccounts{}, log), log).Routes(allowAll)
	body := `{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}`

	// A transfer whose first request is still running (or was cut off by a crash).
	store.transfers["99"] = Transfer{ID: "99", FromAccount: "1111111111", ToAccount: "2222222222",
		Amount: decimal.RequireFromString("100000"), Status: Debited}
	store.keys["k-running"] = "99"

	tests := []struct {
		name         string
		key          string
		body         string
		wantStatus   int
		wantBody     string
		wantReplayed string
	}{
		{"new transfer", "k-1", body, http.StatusCreated, `"status":"COMPLETED"`, ""},
		{"same key again", "k-1", body, http.StatusCreated, `"id":"1"`, "true"},
		{"same key, still in progress", "k-running", body, http.StatusAccepted, `"status":"DEBITED"`, "true"},
		{"same key, different body", "k-1", strings.Replace(body, "100000", "1", 1),
			http.StatusUnprocessableEntity, "idempotency key", ""},
		{"invalid key", "has space", body, http.StatusBadRequest, "Idempotency-Key", ""},
		{"no key", "", body, http.StatusCreated, `"id":"2"`, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/transfers", strings.NewReader(tc.body))
			if tc.key != "" {
				req.Header.Set("Idempotency-Key", tc.key)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus || !strings.Contains(rec.Body.String(), tc.wantBody) {
				t.Fatalf("%d %s, want %d containing %q", rec.Code, rec.Body, tc.wantStatus, tc.wantBody)
			}
			if got := rec.Header().Get("Idempotent-Replayed"); got != tc.wantReplayed {
				t.Fatalf("Idempotent-Replayed = %q, want %q", got, tc.wantReplayed)
			}
		})
	}
}
