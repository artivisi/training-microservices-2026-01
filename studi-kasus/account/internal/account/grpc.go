package account

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"strings"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
)

// GRPCServer is the internal API for other services. It uses the same Store as
// the REST handler; only the transport and the error vocabulary differ.
type GRPCServer struct {
	accountv1.UnimplementedAccountServiceServer
	store Store
	log   *slog.Logger
}

func NewGRPCServer(store Store, log *slog.Logger) *GRPCServer {
	return &GRPCServer{store: store, log: log}
}

func (s *GRPCServer) GetAccount(ctx context.Context, req *accountv1.GetAccountRequest) (*accountv1.GetAccountResponse, error) {
	a, err := s.store.Get(ctx, req.GetNumber())
	if err != nil {
		return nil, s.toStatus(err)
	}
	return &accountv1.GetAccountResponse{Account: toProto(a)}, nil
}

func (s *GRPCServer) Debit(ctx context.Context, req *accountv1.DebitRequest) (*accountv1.DebitResponse, error) {
	a, err := s.mutate(ctx, Debit, req.GetNumber(), req.GetAmount(), req.GetReference())
	if err != nil {
		return nil, err
	}
	return &accountv1.DebitResponse{Account: toProto(a)}, nil
}

func (s *GRPCServer) Credit(ctx context.Context, req *accountv1.CreditRequest) (*accountv1.CreditResponse, error) {
	a, err := s.mutate(ctx, Credit, req.GetNumber(), req.GetAmount(), req.GetReference())
	if err != nil {
		return nil, err
	}
	return &accountv1.CreditResponse{Account: toProto(a)}, nil
}

func (s *GRPCServer) mutate(ctx context.Context, t MutationType, number, amount, reference string) (Account, error) {
	parsed, err := parseAmount(amount)
	if err != nil {
		return Account{}, s.toStatus(err)
	}
	req := MutationRequest{Amount: parsed, Reference: reference}
	if err := req.Validate(); err != nil {
		return Account{}, s.toStatus(err)
	}
	a, applied, err := s.store.Mutate(ctx, number, t, req)
	if err != nil {
		return Account{}, s.toStatus(err)
	}
	if !applied {
		// Not an error: the caller retried after losing our first answer. It gets
		// a success with the current balance, and the money moved only once.
		s.log.Info("mutation already applied, not repeated", "number", a.Number, "type", t, "reference", req.Reference)
		return a, nil
	}
	s.log.Info("account mutated", "number", a.Number, "type", t, "amount", req.Amount, "reference", req.Reference)
	return a, nil
}

// toStatus maps domain errors to gRPC codes. Callers branch on the code, so the
// mapping is part of the contract (see account.proto):
//   - NotFound and FailedPrecondition are business answers from a healthy
//     service; clients must not retry them or count them against the breaker.
//   - Canceled / DeadlineExceeded: the caller gave up (its deadline passed or it
//     hung up) while the store was still working. Not our failure, so it is
//     not logged as one; the caller already has its own error.
//   - Anything unexpected becomes Internal, with the detail only in our log.
func (s *GRPCServer) toStatus(err error) error {
	var v ValidationError
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		st := status.FromContextError(err)
		s.log.Warn("caller gave up before the request finished", "code", st.Code().String(), "error", err)
		return st.Err()
	case errors.As(err, &v):
		return status.Error(codes.InvalidArgument, v.describe())
	case errors.Is(err, ErrNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, ErrInsufficientFunds):
		return status.Error(codes.FailedPrecondition, err.Error())
	default:
		s.log.Error("grpc request failed", "error", err)
		return status.Error(codes.Internal, "internal error")
	}
}

// describe renders "amount: must be ...; reference: must be ..." in a stable order.
func (v ValidationError) describe() string {
	var parts []string
	for _, field := range slices.Sorted(maps.Keys(v)) {
		parts = append(parts, fmt.Sprintf("%s: %s", field, v[field]))
	}
	return strings.Join(parts, "; ")
}

func toProto(a Account) *accountv1.Account {
	return &accountv1.Account{
		Number:    a.Number,
		OwnerName: a.OwnerName,
		Balance:   a.Balance.StringFixed(2),
		CreatedAt: timestamppb.New(a.CreatedAt),
	}
}
