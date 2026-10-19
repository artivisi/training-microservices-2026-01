// Package notification tells customers about the outcome of their transfers. It
// learns about transfers only from events on Kafka; it never calls the transfer
// service.
package notification

import (
	"context"
	"fmt"
	"time"

	"github.com/shopspring/decimal"
)

type Notification struct {
	ID         int64     `json:"id"`
	EventID    string    `json:"event_id"`
	TransferID string    `json:"transfer_id"`
	EventType  string    `json:"event_type"`
	Message    string    `json:"message"`
	CreatedAt  time.Time `json:"created_at"`
}

// TransferEvent is the payload published by the transfer service. It is
// declared here again, not imported: services share the message format (the
// contract), not code. This side reads only the fields it needs.
type TransferEvent struct {
	EventID     string          `json:"event_id"`
	TransferID  string          `json:"transfer_id"`
	FromAccount string          `json:"from_account"`
	ToAccount   string          `json:"to_account"`
	Amount      decimal.Decimal `json:"amount"`
	Status      string          `json:"status"`
	OccurredAt  time.Time       `json:"occurred_at"`
}

// Message builds the customer-facing text for an event type. ok is false for an
// event type this service does not notify about.
func Message(eventType string, e TransferEvent) (msg string, ok bool) {
	amount := e.Amount.StringFixed(2)
	switch eventType {
	case "TransferCompleted":
		return fmt.Sprintf("Transfer %s dari %s ke %s berhasil.", amount, e.FromAccount, e.ToAccount), true
	case "TransferFailed":
		return fmt.Sprintf("Transfer %s dari %s ke %s gagal. Saldo tidak berubah.", amount, e.FromAccount, e.ToAccount), true
	case "TransferCompensated":
		return fmt.Sprintf("Transfer %s dari %s ke %s dibatalkan. Dana sudah dikembalikan ke %s.",
			amount, e.FromAccount, e.ToAccount, e.FromAccount), true
	}
	return "", false
}

type Store interface {
	// Insert stores the notification and marks its event as processed, in one
	// transaction. inserted is false, and nothing is stored, when the event was
	// processed before.
	Insert(ctx context.Context, n Notification) (stored Notification, inserted bool, err error)
	ListByTransfer(ctx context.Context, transferID string) ([]Notification, error)
	Ping(ctx context.Context) error
}
