package transfer

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestCreateStatus checks the HTTP status for each outcome. 503 is reserved for
// "no money moved, safe to retry": the breaker refused the debit, or refused the
// credit and the debit was reversed. A failed reversal is a 500 whatever the
// cause, never a 503.
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
			svc := NewService(&fakeStore{transfers: map[string]Transfer{}}, tc.accounts, log)
			srv := httptest.NewServer(NewHandler(svc, log).Routes())
			defer srv.Close()

			body := `{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}`
			resp, err := http.Post(srv.URL+"/transfers", "application/json", strings.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.want)
			}
		})
	}
}

func fails(desc string, err error) *fakeAccounts {
	return &fakeAccounts{errs: map[string]error{desc: err}}
}
