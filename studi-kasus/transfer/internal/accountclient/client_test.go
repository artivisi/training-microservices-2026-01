package accountclient

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/shopspring/decimal"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

func TestStatusMapping(t *testing.T) {
	tests := []struct {
		status  int
		wantErr error
	}{
		{http.StatusOK, nil},
		{http.StatusNotFound, transfer.ErrAccountNotFound},
		{http.StatusUnprocessableEntity, transfer.ErrInsufficientFunds},
	}
	for _, tc := range tests {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost || r.URL.Path != "/accounts/1111111111/debit" {
				t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			}
			w.WriteHeader(tc.status)
		}))
		err := New(srv.URL).Debit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
		srv.Close()
		if !errors.Is(err, tc.wantErr) {
			t.Errorf("status %d: err = %v, want %v", tc.status, err, tc.wantErr)
		}
	}
}

func TestServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()
	err := New(srv.URL).Credit(context.Background(), "1111111111", decimal.NewFromInt(10), "ref")
	if err == nil || errors.Is(err, transfer.ErrAccountNotFound) || errors.Is(err, transfer.ErrInsufficientFunds) {
		t.Fatalf("err = %v, want a non-business error", err)
	}
}
