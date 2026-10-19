// Package transfer moves money between two accounts by calling the account service.
package transfer

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/shopspring/decimal"
)

type Status string

const (
	Pending   Status = "PENDING"
	Completed Status = "COMPLETED"
	Failed    Status = "FAILED"
)

type Transfer struct {
	ID            string          `json:"id"`
	FromAccount   string          `json:"from_account"`
	ToAccount     string          `json:"to_account"`
	Amount        decimal.Decimal `json:"amount"`
	Status        Status          `json:"status"`
	FailureReason string          `json:"failure_reason,omitempty"`
	CreatedAt     time.Time       `json:"created_at"`
	UpdatedAt     time.Time       `json:"updated_at"`
}

type CreateRequest struct {
	FromAccount string          `json:"from_account"`
	ToAccount   string          `json:"to_account"`
	Amount      decimal.Decimal `json:"amount"`
}

var (
	ErrNotFound = errors.New("transfer not found")
	// Business rejections from the account service: the request itself cannot succeed.
	ErrAccountNotFound   = errors.New("account not found")
	ErrInsufficientFunds = errors.New("insufficient funds")
)

type ValidationError map[string]string

func (v ValidationError) Error() string { return "validation failed" }

var numberPattern = regexp.MustCompile(`^[0-9]{10}$`)

func (r CreateRequest) Validate() error {
	v := ValidationError{}
	if !numberPattern.MatchString(r.FromAccount) {
		v["from_account"] = "must be exactly 10 digits"
	}
	if !numberPattern.MatchString(r.ToAccount) {
		v["to_account"] = "must be exactly 10 digits"
	}
	if r.FromAccount == r.ToAccount {
		v["to_account"] = "must differ from from_account"
	}
	if !r.Amount.IsPositive() {
		v["amount"] = "must be greater than zero"
	}
	if len(v) > 0 {
		return v
	}
	return nil
}

type Store interface {
	// Create records a new transfer in status PENDING.
	Create(ctx context.Context, req CreateRequest) (Transfer, error)
	Finish(ctx context.Context, id string, status Status, reason string) (Transfer, error)
	Get(ctx context.Context, id string) (Transfer, error)
	Ping(ctx context.Context) error
}

// AccountClient is what the transfer needs from the account service. The reference
// passed to the account service is the transfer ID.
type AccountClient interface {
	Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error
	Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error
}
