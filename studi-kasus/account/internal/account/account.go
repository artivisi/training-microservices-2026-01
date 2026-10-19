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

var (
	ErrNotFound      = errors.New("account not found")
	ErrAlreadyExists = errors.New("account already exists")
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

// Store is the persistence contract; the HTTP handler depends on this, not on PostgreSQL.
type Store interface {
	Create(ctx context.Context, req CreateRequest) (Account, error)
	Get(ctx context.Context, number string) (Account, error)
	List(ctx context.Context) ([]Account, error)
	Ping(ctx context.Context) error
}
