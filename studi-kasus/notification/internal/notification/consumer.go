package notification

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/segmentio/kafka-go"
)

// Reader is the part of kafka.Reader the consumer uses; tests can fake it.
type Reader interface {
	FetchMessage(ctx context.Context) (kafka.Message, error)
	CommitMessages(ctx context.Context, msgs ...kafka.Message) error
}

// NewKafkaReader joins the consumer group. Kafka assigns the topic's partitions
// to the group's members; with 3 partitions, up to 3 instances share the work.
func NewKafkaReader(brokers []string, topic, groupID string) *kafka.Reader {
	return kafka.NewReader(kafka.ReaderConfig{
		Brokers: brokers,
		Topic:   topic,
		GroupID: groupID,
		// Where a group without a committed offset starts: from the oldest event,
		// so nothing published before the first start is missed.
		StartOffset: kafka.FirstOffset,
		// 0 = CommitMessages commits synchronously, at the moment we call it.
		CommitInterval: 0,
	})
}

type Consumer struct {
	reader Reader
	store  Store
	log    *slog.Logger
	// retryDelay is the pause before a failed fetch or insert is tried again.
	retryDelay time.Duration
}

func NewConsumer(reader Reader, store Store, log *slog.Logger) *Consumer {
	return &Consumer{reader: reader, store: store, log: log, retryDelay: time.Second}
}

// Run handles events one by one until ctx is cancelled. Kafka or database
// outages are waited out, never a reason to stop.
//
// The offset is committed only AFTER the notification is stored: a crash in
// between means the event is delivered again after the restart (at-least-once),
// never that it is lost. The price is duplicates; together with the outbox
// relay's own duplicate window this consumer does see the same event twice
// sometimes. It is deliberately NOT idempotent yet: a redelivered event becomes
// a second notification. Lab 6 fixes that.
func (c *Consumer) Run(ctx context.Context) {
	for {
		m, err := c.reader.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			// Kafka unreachable or the group rebalancing. Not a reason to stop the
			// service: wait and fetch again; the committed offset says where.
			c.log.Warn("fetching event failed, retrying", "error", err)
			if !c.pause(ctx) {
				return
			}
			continue
		}
		if err := c.handle(ctx, m); err != nil {
			return // only ctx cancellation ends handle with an error
		}
		if err := c.reader.CommitMessages(ctx, m); err != nil {
			if ctx.Err() != nil {
				return
			}
			// The notification is stored but Kafka does not know. The event comes
			// again after a restart or rebalance: one more duplicate, nothing lost.
			c.log.Warn("committing offset failed", "partition", m.Partition, "offset", m.Offset, "error", err)
		}
	}
}

// handle stores the notification for m. Errors fall in two groups:
//
//   - Transient (database down, connection lost, timeout): retried until it
//     succeeds. Skipping would lose the notification, and moving on to later
//     events of the same partition would break their order.
//   - Permanent (the event itself is bad): logged at ERROR and skipped, so the
//     offset is committed. Retrying would fail the same way forever and block
//     every later event of the partition behind it (a poison message). In
//     production the event would go to a dead-letter topic for a person to look
//     at.
//
// The event is validated before the insert, so most bad events never reach the
// database; permanentDBError catches what slips through.
func (c *Consumer) handle(ctx context.Context, m kafka.Message) error {
	eventType := header(m, "event_type")
	log := c.log.With("event_type", eventType, "partition", m.Partition, "offset", m.Offset)

	var e TransferEvent
	if err := json.Unmarshal(m.Value, &e); err != nil {
		log.Error("skipping unreadable event", "error", err, "payload", string(m.Value))
		return nil
	}
	// The columns are uuid: a malformed ID would fail the insert with 22P02 on
	// every try.
	if !isUUID(e.EventID) || !isUUID(e.TransferID) {
		log.Error("skipping event with invalid event_id or transfer_id", "event_id", e.EventID,
			"transfer_id", e.TransferID, "payload", string(m.Value))
		return nil
	}
	msg, ok := Message(eventType, e)
	if !ok {
		log.Warn("skipping event type without notification", "event_id", e.EventID)
		return nil
	}

	n := Notification{EventID: e.EventID, TransferID: e.TransferID, EventType: eventType, Message: msg}
	for {
		stored, err := c.store.Insert(ctx, n)
		if err == nil {
			// Stand-in for the real channel (SMS, push, e-mail).
			log.Info("notification sent", "event_id", e.EventID, "transfer_id", e.TransferID,
				"notification_id", stored.ID, "message", msg)
			return nil
		}
		if permanentDBError(err) {
			log.Error("skipping event the database rejects", "event_id", e.EventID, "error", err,
				"payload", string(m.Value))
			return nil
		}
		log.Warn("storing notification failed, retrying", "event_id", e.EventID, "error", err)
		if !c.pause(ctx) {
			return errors.Join(ctx.Err(), err)
		}
	}
}

// isUUID accepts only the canonical 36-character form, the one the transfer
// service writes. uuid.Validate alone also accepts forms like "urn:uuid:...",
// which PostgreSQL rejects.
func isUUID(s string) bool {
	return len(s) == 36 && uuid.Validate(s) == nil
}

// permanentDBError reports whether PostgreSQL rejected the data itself, so the
// same insert fails the same way on every retry: SQLSTATE class 22 (data
// exception, e.g. 22P02 invalid uuid text, 22001 value too long) and class 23
// (integrity constraint, e.g. 23502 not null, 23514 check). Everything else is
// treated as transient and retried: connection errors, timeouts, and also
// schema errors (class 42, e.g. a missing table). Those fail every event, not
// one; retrying blocks consumption but loses nothing until a fix is deployed,
// while skipping would throw away every notification.
func permanentDBError(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	return strings.HasPrefix(pgErr.Code, "22") || strings.HasPrefix(pgErr.Code, "23")
}

// pause waits retryDelay and reports false when ctx ended first.
func (c *Consumer) pause(ctx context.Context) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(c.retryDelay):
		return true
	}
}

func header(m kafka.Message, key string) string {
	for _, h := range m.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}
