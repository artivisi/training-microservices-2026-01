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
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/telemetry"
)

// pendingGauge is the backlog of the relay. Normally 0 or close to it; a value that
// keeps growing means Kafka is unreachable or the relay is stuck, and every
// notification waits.
var pendingGauge = promauto.NewGauge(prometheus.GaugeOpts{
	Name: "outbox_pending",
	Help: "Outbox events not yet published to Kafka.",
})

// Message is one outbox row. The table itself is created by the transfer schema.
type Message struct {
	ID          string // event ID, also sent as Kafka header event_id
	AggregateID string // transfer ID, used as the Kafka key
	EventType   string
	Payload     []byte // JSON
	// CorrelationID and TraceContext belong to the request that wrote the row
	// (Lab 8). Insert takes them from its ctx.
	CorrelationID string
	TraceContext  map[string]string
}

// Insert writes m inside tx. tx must be the transaction that also writes the
// state change, otherwise the outbox gives no guarantee at all.
//
// The correlation ID and the trace context of ctx are stored with the row: the
// relay publishes it later from its own goroutine, where the request's context
// is long gone. Without them, the trace would end at the transfer service.
func Insert(ctx context.Context, tx pgx.Tx, m Message) error {
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	_, err := tx.Exec(ctx, `
		insert into outbox (id, aggregate_id, event_type, payload, correlation_id, trace_context)
		values (@id, @aggregate_id, @event_type, @payload, nullif(@correlation_id, ''), @trace_context)`,
		pgx.NamedArgs{"id": m.ID, "aggregate_id": m.AggregateID, "event_type": m.EventType, "payload": m.Payload,
			"correlation_id": telemetry.CorrelationID(ctx), "trace_context": map[string]string(carrier)})
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
	pool   *pgxpool.Pool
	pub    Publisher
	topic  string
	tracer trace.Tracer
	log    *slog.Logger
}

// NewRelay takes topic only to name the spans; pub decides where messages go.
func NewRelay(pool *pgxpool.Pool, pub Publisher, topic string, log *slog.Logger) *Relay {
	return &Relay{pool: pool, pub: pub, topic: topic, tracer: otel.Tracer("transfer/outbox"), log: log}
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
		switch {
		case err != nil && ctx.Err() == nil:
			r.log.Warn("outbox publish failed, will retry", "error", err)
		case n > 0:
			r.log.Info("outbox events published", "count", n)
		}
		// After a failure too: a growing backlog while Kafka is down is exactly
		// what the gauge is for.
		r.updatePending(ctx)
	}
}

func (r *Relay) updatePending(ctx context.Context) {
	var n int64
	// Cheap: the partial index outbox_unpublished holds only unpublished rows.
	if err := r.pool.QueryRow(ctx, `select count(*) from outbox where published_at is null`).Scan(&n); err != nil {
		if ctx.Err() == nil {
			r.log.Warn("counting pending outbox events failed", "error", err)
		}
		return
	}
	pendingGauge.Set(float64(n))
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
		select id::text, aggregate_id::text, event_type, payload,
		       coalesce(correlation_id, ''), coalesce(trace_context, '{}'::jsonb)
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
	spans := make([]trace.Span, len(pending))
	for i, m := range pending {
		msgs[i], spans[i] = r.message(ctx, m)
		ids[i] = m.ID
	}
	// Bounded, so a hanging broker does not hold the row locks forever.
	pubCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := r.pub.WriteMessages(pubCtx, msgs...); err != nil {
		// The spans of a failed batch are not ended, so they are never exported.
		// While Kafka is down the batch fails every 500 ms; ending them would hang
		// one more failed span per attempt on every waiting transfer's trace. The
		// warning in Run and outbox_pending report the outage instead.
		return 0, fmt.Errorf("publish %d events: %w", len(msgs), err)
	}
	for _, span := range spans {
		span.End()
	}

	// The duplicate window described above starts here.
	if _, err := tx.Exec(ctx, `update outbox set published_at = now() where id = any(@ids::uuid[])`,
		pgx.NamedArgs{"ids": ids}); err != nil {
		return 0, fmt.Errorf("mark %d events published: %w", len(ids), err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	// One line per event, in the event's own trace: Loki shows it under the
	// transfer's trace next to the log lines of the other services.
	for i, m := range pending {
		evCtx := telemetry.WithCorrelationID(trace.ContextWithSpan(ctx, spans[i]), m.CorrelationID)
		r.log.InfoContext(evCtx, "event published", "event_id", m.ID, "event_type", m.EventType, "transfer_id", m.AggregateID)
	}
	return len(pending), nil
}

// message builds the Kafka message for m and starts its "publish" span as a
// child of the request that wrote m, so the trace continues across the
// asynchronous gap. The span's own context goes into the headers: the
// consumer's span becomes its child. The caller ends the span once Kafka
// has acknowledged the message.
func (r *Relay) message(ctx context.Context, m Message) (kafka.Message, trace.Span) {
	parent := otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(m.TraceContext))
	spanCtx, span := r.tracer.Start(parent, "publish "+r.topic,
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.operation.type", "send"),
			attribute.String("messaging.destination.name", r.topic),
			attribute.String("messaging.message.id", m.ID),
			attribute.String("messaging.kafka.message.key", m.AggregateID),
			attribute.String("event.type", m.EventType),
		))

	headers := []kafka.Header{
		{Key: "event_type", Value: []byte(m.EventType)},
		{Key: "event_id", Value: []byte(m.ID)},
	}
	if m.CorrelationID != "" {
		headers = append(headers, kafka.Header{Key: telemetry.CorrelationKafkaHeader, Value: []byte(m.CorrelationID)})
	}
	otel.GetTextMapPropagator().Inject(spanCtx, telemetry.KafkaHeaders{Headers: &headers})
	return kafka.Message{Key: []byte(m.AggregateID), Value: m.Payload, Headers: headers}, span
}
