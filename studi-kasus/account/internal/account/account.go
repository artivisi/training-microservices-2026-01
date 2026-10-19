// Package account holds the account domain: model, validation, storage, and HTTP API.
package account

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/shopspring/decimal"
)

type Account struct {
	Number    string          `json:"number"`
	OwnerName string          `json:"owner_name"`
	Balance   decimal.Decimal `json:"balance"`
	CreatedAt time.Time       `json:"created_at"`
}

type CreateRequest struct {
	Number         string          `json:"number"`
	OwnerName      string          `json:"owner_name"`
	InitialBalance decimal.Decimal `json:"initial_balance"`
}

// MutationRequest is the body of a debit or credit. Reference ties the mutation to
// the business transaction that caused it, e.g. a transfer ID.
type MutationRequest struct {
	Amount    decimal.Decimal `json:"amount"`
	Reference string          `json:"reference"`
}

type MutationType string

const (
	Debit  MutationType = "DEBIT"
	Credit MutationType = "CREDIT"
)

var (
	ErrNotFound          = errors.New("account not found")
	ErrAlreadyExists     = errors.New("account already exists")
	ErrInsufficientFunds = errors.New("insufficient funds")
)

// ValidationError maps field name to the problem found in that field.
type ValidationError map[string]string

func (v ValidationError) Error() string { return "validation failed" }

var numberPattern = regexp.MustCompile(`^[0-9]{10}$`)

func (r CreateRequest) Validate() error {
	v := ValidationError{}
	if !numberPattern.MatchString(r.Number) {
		v["number"] = "must be exactly 10 digits"
	}
	if strings.TrimSpace(r.OwnerName) == "" {
		v["owner_name"] = "must not be empty"
	}
	if r.InitialBalance.IsNegative() {
		v["initial_balance"] = "must not be negative"
	}
	if len(v) > 0 {
		return v
	}
	return nil
}

func (r MutationRequest) Validate() error {
	v := ValidationError{}
	if !r.Amount.IsPositive() {
		v["amount"] = "must be greater than zero"
	}
	if strings.TrimSpace(r.Reference) == "" || len(r.Reference) > 64 {
		v["reference"] = "must be 1 to 64 characters"
	}
	if len(v) > 0 {
		return v
	}
	return nil
}

// Store is the persistence contract; the HTTP handler depends on this, not on PostgreSQL.
type Store interface {
	Create(ctx context.Context, req CreateRequest) (Account, error)
	Get(ctx context.Context, number string) (Account, error)
	List(ctx context.Context) ([]Account, error)
	// Mutate debits or credits the account and records the mutation, atomically.
	// It returns the account with its new balance.
	Mutate(ctx context.Context, number string, t MutationType, req MutationRequest) (Account, error)
	Ping(ctx context.Context) error
}
