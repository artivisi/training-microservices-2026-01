// Package account holds the account domain: model, validation, storage, the
// channel-facing HTTP API and the internal gRPC API.
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

// MutationRequest is a debit or credit, received over gRPC. Reference ties the
// mutation to the business transaction that caused it, e.g. a transfer ID.
type MutationRequest struct {
	Amount    decimal.Decimal
	Reference string
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

// Balances and amounts are numeric(19,2) in the database: at most 17 digits
// before the decimal point and 2 after. PostgreSQL rounds extra decimal places
// without complaint (100.005 becomes 100.01), so they are rejected here instead.
var maxAmount = decimal.New(1, 17)

// amountProblem returns what is wrong with d as a numeric(19,2) value, or "".
// Sign is checked by the caller: a balance may be zero, an amount may not.
func amountProblem(d decimal.Decimal) string {
	switch {
	case d.Exponent() < -2:
		return "must have at most 2 decimal places"
	case d.Abs().GreaterThanOrEqual(maxAmount):
		return "must be less than 10^17"
	}
	return ""
}

// amountPattern is the wire format of an amount on the gRPC contract: plain
// digits with an optional fraction of 1 or 2 digits. No sign, no exponent ("1e3")
// and no grouping, so what the caller wrote is exactly what gets stored.
var amountPattern = regexp.MustCompile(`^[0-9]+(\.[0-9]{1,2})?$`)

// parseAmount parses a gRPC amount string. Range and sign are left to
// MutationRequest.Validate.
func parseAmount(s string) (decimal.Decimal, error) {
	if !amountPattern.MatchString(s) {
		return decimal.Decimal{}, ValidationError{"amount": "must be digits with at most 2 decimal places, e.g. 150000.50"}
	}
	return decimal.NewFromString(s)
}

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
	} else if p := amountProblem(r.InitialBalance); p != "" {
		v["initial_balance"] = p
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
	} else if p := amountProblem(r.Amount); p != "" {
		v["amount"] = p
	}
	if strings.TrimSpace(r.Reference) == "" || len(r.Reference) > 64 {
		v["reference"] = "must be 1 to 64 characters"
	}
	if len(v) > 0 {
		return v
	}
	return nil
}

// Store is the persistence contract; the HTTP and gRPC handlers depend on this,
// not on PostgreSQL.
type Store interface {
	Create(ctx context.Context, req CreateRequest) (Account, error)
	Get(ctx context.Context, number string) (Account, error)
	List(ctx context.Context) ([]Account, error)
	// Mutate debits or credits the account and records the mutation, atomically.
	// It returns the account with its new balance.
	Mutate(ctx context.Context, number string, t MutationType, req MutationRequest) (Account, error)
	Ping(ctx context.Context) error
}
