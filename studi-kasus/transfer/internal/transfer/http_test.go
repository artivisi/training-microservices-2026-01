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
// "nothing applied, safe to retry"; once the debit went through, every credit
// failure is a 502, even when the cause is the open breaker.
func TestCreateStatus(t *testing.T) {
	tests := []struct {
		name     string
		accounts *fakeAccounts
		want     int
	}{
		{"success", &fakeAccounts{}, http.StatusCreated},
		{"insufficient funds", &fakeAccounts{debitErr: ErrInsufficientFunds}, http.StatusUnprocessableEntity},
		{"breaker open before debit", &fakeAccounts{debitErr: ErrAccountUnavailable}, http.StatusServiceUnavailable},
		{"breaker opens between debit and credit", &fakeAccounts{creditErr: ErrAccountUnavailable}, http.StatusBadGateway},
		{"destination not found after debit", &fakeAccounts{creditErr: ErrAccountNotFound}, http.StatusBadGateway},
		{"credit fails after debit", &fakeAccounts{creditErr: errors.New("connection refused")}, http.StatusBadGateway},
		{"debit fails on transport error", &fakeAccounts{debitErr: errors.New("connection refused")}, http.StatusBadGateway},
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
