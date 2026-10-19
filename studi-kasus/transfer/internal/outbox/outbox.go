// Package outbox implements the transactional outbox: events are stored in the
// service's own database, in the same transaction as the state change they
// report, and a relay publishes them to Kafka afterwards.
package outbox

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/segmentio/kafka-go"
)

// Message is one outbox row. The table itself is created by the transfer schema.
type Message struct {
	ID          string // event ID, also sent as Kafka header event_id
	AggregateID string // transfer ID, used as the Kafka key
	EventType   string
	Payload     []byte // JSON
}

// Insert writes m inside tx. tx must be the transaction that also writes the
// state change, otherwise the outbox gives no guarantee at all.
func Insert(ctx context.Context, tx pgx.Tx, m Message) error {
	_, err := tx.Exec(ctx, `
		insert into outbox (id, aggregate_id, event_type, payload)
		values (@id, @aggregate_id, @event_type, @payload)`,
		pgx.NamedArgs{"id": m.ID, "aggregate_id": m.AggregateID, "event_type": m.EventType, "payload": m.Payload})
	if err != nil {
		return fmt.Errorf("insert outbox message: %w", err)
	}
	return nil
}

// Publisher is the part of kafka.Writer the relay uses; tests can fake it.
type Publisher interface {
	WriteMessages(ctx context.Context, msgs ...kafka.Message) error
}

// NewKafkaWriter builds the producer for the relay.
func NewKafkaWriter(brokers []string, topic string) *kafka.Writer {
	return &kafka.Writer{
		Addr:  kafka.TCP(brokers...),
		Topic: topic,
		// Same key, same partition: all events of one transfer stay in order.
		Balancer: &kafka.Hash{},
		// Acknowledged by every in-sync replica before WriteMessages returns; only
		// then may the relay mark the rows published.
		RequiredAcks: kafka.RequireAll,
		// The topic is created on purpose, with its partition count (compose
		// kafka-init). A typo in KAFKA_TOPIC must fail, not create a new topic.
		AllowAutoTopicCreation: false,
		// The relay hands over a whole batch in one call; do not wait the default
		// 1 s for more messages that will not come.
		BatchTimeout: 10 * time.Millisecond,
		BatchSize:    BatchSize,
	}
}

const (
	// PollInterval is how long an event waits at most before the relay looks.
	PollInterval = 500 * time.Millisecond
	// BatchSize caps the rows claimed per poll.
	BatchSize = 100
)

type Relay struct {
	pool *pgxpool.Pool
	pub  Publisher
	log  *slog.Logger
}

func NewRelay(pool *pgxpool.Pool, pub Publisher, log *slog.Logger) *Relay {
	return &Relay{pool: pool, pub: pub, log: log}
}

// Run polls the outbox until ctx is cancelled. A failed batch (Kafka down,
// database down) is logged and tried again on the next tick: the rows stay
// unpublished, nothing is lost.
func (r *Relay) Run(ctx context.Context) {
	r.log.Info("outbox relay started", "interval", PollInterval.String())
	ticker := time.NewTicker(PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			r.log.Info("outbox relay stopped")
			return
		case <-ticker.C:
		}
		n, err := r.publishBatch(ctx)
		if err != nil {
			if ctx.Err() == nil {
				r.log.Warn("outbox publish failed, will retry", "error", err)
			}
			continue
		}
		if n > 0 {
			r.log.Info("outbox events published", "count", n)
		}
	}
}

// publishBatch claims up to BatchSize unpublished rows, publishes them, and marks
// them published, all while holding the row locks of one transaction.
//
// "for update skip locked" lets several transfer instances run a relay each:
// rows locked by one relay are skipped by the others instead of being published
// twice or blocking them.
//
// Delivery is at-least-once. Kafka has acknowledged the batch before the update
// commits; when the commit fails or the process dies in between, the rows are
// still unpublished and go out again on the next poll. Consumers therefore see
// duplicates now and then and must be idempotent (Lab 6). The opposite order,
// commit first and publish after, would lose events instead: worse.
func (r *Relay) publishBatch(ctx context.Context) (int, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

	rows, err := tx.Query(ctx, `
		select id::text, aggregate_id::text, event_type, payload
		from outbox
		where published_at is null
		order by created_at
		limit @limit
		for update skip locked`,
		pgx.NamedArgs{"limit": BatchSize})
	if err != nil {
		return 0, err
	}
	pending, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Message])
	if err != nil {
		return 0, err
	}
	if len(pending) == 0 {
		return 0, nil
	}

	msgs := make([]kafka.Message, len(pending))
	ids := make([]string, len(pending))
	for i, m := range pending {
		msgs[i] = kafka.Message{
			Key:   []byte(m.AggregateID),
			Value: m.Payload,
			Headers: []kafka.Header{
				{Key: "event_type", Value: []byte(m.EventType)},
				{Key: "event_id", Value: []byte(m.ID)},
			},
		}
		ids[i] = m.ID
	}
	// Bounded, so a hanging broker does not hold the row locks forever.
	pubCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := r.pub.WriteMessages(pubCtx, msgs...); err != nil {
		return 0, fmt.Errorf("publish %d events: %w", len(msgs), err)
	}

	// The duplicate window described above starts here.
	if _, err := tx.Exec(ctx, `update outbox set published_at = now() where id = any(@ids::uuid[])`,
		pgx.NamedArgs{"ids": ids}); err != nil {
		return 0, fmt.Errorf("mark %d events published: %w", len(ids), err)
	}
	return len(pending), tx.Commit(ctx)
}
