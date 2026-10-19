package account

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"testing"

	"github.com/shopspring/decimal"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
)

// newGRPCClient serves GRPCServer over an in-memory listener (bufconn): the test
// goes through real protobuf encoding and status codes without opening a port.
func newGRPCClient(t *testing.T, store Store) accountv1.AccountServiceClient {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	accountv1.RegisterAccountServiceServer(srv, NewGRPCServer(store, slog.New(slog.NewTextHandler(io.Discard, nil))))
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return accountv1.NewAccountServiceClient(conn)
}

func TestGRPCAccountService(t *testing.T) {
	store := newFakeStore()
	store.accounts["1234567890"] = Account{Number: "1234567890", OwnerName: "Budi", Balance: decimal.RequireFromString("500000")}
	c := newGRPCClient(t, store)
	ctx := context.Background()

	got, err := c.GetAccount(ctx, &accountv1.GetAccountRequest{Number: "1234567890"})
	if err != nil || got.GetAccount().GetBalance() != "500000.00" {
		t.Fatalf("GetAccount = %v, %v; want balance 500000.00", got, err)
	}
	debit, err := c.Debit(ctx, &accountv1.DebitRequest{Number: "1234567890", Amount: "200000.50", Reference: "T-1"})
	if err != nil || debit.GetAccount().GetBalance() != "299999.50" {
		t.Fatalf("Debit = %v, %v; want balance 299999.50", debit, err)
	}
	credit, err := c.Credit(ctx, &accountv1.CreditRequest{Number: "1234567890", Amount: "0.50", Reference: "T-2"})
	if err != nil || credit.GetAccount().GetBalance() != "300000.00" {
		t.Fatalf("Credit = %v, %v; want balance 300000.00", credit, err)
	}

	rejections := []struct {
		name     string
		call     func() error
		wantCode codes.Code
	}{
		{"unknown account", func() error {
			_, err := c.GetAccount(ctx, &accountv1.GetAccountRequest{Number: "0000000000"})
			return err
		}, codes.NotFound},
		{"debit unknown account", func() error {
			_, err := c.Debit(ctx, &accountv1.DebitRequest{Number: "0000000000", Amount: "1", Reference: "T-3"})
			return err
		}, codes.NotFound},
		{"insufficient funds", func() error {
			_, err := c.Debit(ctx, &accountv1.DebitRequest{Number: "1234567890", Amount: "300000.01", Reference: "T-4"})
			return err
		}, codes.FailedPrecondition},
		{"amount not a number", func() error {
			_, err := c.Credit(ctx, &accountv1.CreditRequest{Number: "1234567890", Amount: "1e", Reference: "T-5"})
			return err
		}, codes.InvalidArgument},
		{"three decimal places", func() error {
			_, err := c.Debit(ctx, &accountv1.DebitRequest{Number: "1234567890", Amount: "100.005", Reference: "T-6"})
			return err
		}, codes.InvalidArgument},
		{"exponent notation", func() error {
			_, err := c.Credit(ctx, &accountv1.CreditRequest{Number: "1234567890", Amount: "1e3", Reference: "T-7"})
			return err
		}, codes.InvalidArgument},
		{"negative amount", func() error {
			_, err := c.Credit(ctx, &accountv1.CreditRequest{Number: "1234567890", Amount: "-5", Reference: "T-8"})
			return err
		}, codes.InvalidArgument},
		{"above numeric(19,2)", func() error {
			_, err := c.Credit(ctx, &accountv1.CreditRequest{Number: "1234567890", Amount: "100000000000000000", Reference: "T-9"})
			return err
		}, codes.InvalidArgument},
		{"zero amount, empty reference", func() error {
			_, err := c.Credit(ctx, &accountv1.CreditRequest{Number: "1234567890", Amount: "0"})
			return err
		}, codes.InvalidArgument},
	}
	for _, tc := range rejections {
		t.Run(tc.name, func(t *testing.T) {
			if got := status.Code(tc.call()); got != tc.wantCode {
				t.Fatalf("code = %s, want %s", got, tc.wantCode)
			}
		})
	}
	if a := store.accounts["1234567890"]; !a.Balance.Equal(decimal.RequireFromString("300000")) {
		t.Fatalf("balance after rejected calls = %s, want 300000", a.Balance)
	}
}

// TestGRPCCallerGaveUp checks that a context error from the store (the caller's
// deadline passed or it cancelled mid-query) keeps its meaning instead of
// turning into Internal.
func TestGRPCCallerGaveUp(t *testing.T) {
	for _, tc := range []struct {
		storeErr error
		want     codes.Code
	}{
		{fmt.Errorf("query: %w", context.DeadlineExceeded), codes.DeadlineExceeded},
		{fmt.Errorf("query: %w", context.Canceled), codes.Canceled},
	} {
		t.Run(tc.want.String(), func(t *testing.T) {
			store := newFakeStore()
			store.mutateErr = tc.storeErr
			c := newGRPCClient(t, store)
			_, err := c.Debit(context.Background(), &accountv1.DebitRequest{Number: "1234567890", Amount: "1", Reference: "T-1"})
			if got := status.Code(err); got != tc.want {
				t.Fatalf("code = %s, want %s", got, tc.want)
			}
		})
	}
}
