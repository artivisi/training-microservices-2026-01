package notification

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/segmentio/kafka-go"
)

// fakeReader fails the first fetchFailures fetches, then hands out msgs in
// order, records commits, and cancels the run when it has nothing left.
type fakeReader struct {
	msgs          []kafka.Message
	fetchFailures int
	committed     []int64
	done          context.CancelFunc
}

func (f *fakeReader) FetchMessage(ctx context.Context) (kafka.Message, error) {
	if f.fetchFailures > 0 {
		f.fetchFailures--
		return kafka.Message{}, errors.New("failed to dial")
	}
	if len(f.msgs) == 0 {
		f.done()
		<-ctx.Done()
		return kafka.Message{}, ctx.Err()
	}
	m := f.msgs[0]
	f.msgs = f.msgs[1:]
	return m, nil
}

func (f *fakeReader) CommitMessages(_ context.Context, msgs ...kafka.Message) error {
	for _, m := range msgs {
		f.committed = append(f.committed, m.Offset)
	}
	return nil
}

// fakeStore fails the first failures inserts, then stores each event once. An
// insert for an event ID in reject fails with that error on every try.
type fakeStore struct {
	rows      []Notification
	processed map[string]bool
	failures  int
	reject    map[string]error
	inserts   int
}

func (f *fakeStore) Insert(_ context.Context, n Notification) (Notification, bool, error) {
	f.inserts++
	if err := f.reject[n.EventID]; err != nil {
		return Notification{}, false, err
	}
	if f.failures > 0 {
		f.failures--
		return Notification{}, false, errors.New("database down")
	}
	if f.processed[n.EventID] {
		return Notification{}, false, nil
	}
	if f.processed == nil {
		f.processed = map[string]bool{}
	}
	f.processed[n.EventID] = true
	n.ID = int64(len(f.rows) + 1)
	f.rows = append(f.rows, n)
	return n, true, nil
}

func (f *fakeStore) ListByTransfer(_ context.Context, transferID string) ([]Notification, error) {
	var out []Notification
	for _, n := range f.rows {
		if n.TransferID == transferID {
			out = append(out, n)
		}
	}
	return out, nil
}

func (f *fakeStore) Ping(context.Context) error { return nil }

const (
	transferID = "0b6f5c1e-8a4b-4c47-9a53-3c1f1b2a9d10"
	eventID1   = "6c1d2a8e-5f3b-4e1a-9b7c-2d4e6f8a0b11"
	eventID2   = "6c1d2a8e-5f3b-4e1a-9b7c-2d4e6f8a0b12"
	eventID3   = "6c1d2a8e-5f3b-4e1a-9b7c-2d4e6f8a0b13"
)

func event(offset int64, eventType, eventID string) kafka.Message {
	return eventFor(offset, eventType, eventID, transferID)
}

func eventFor(offset int64, eventType, eventID, transferID string) kafka.Message {
	return kafka.Message{
		Offset: offset,
		Key:    []byte(transferID),
		Value: []byte(fmt.Sprintf(`{"event_id":%q,"transfer_id":%q,"from_account":"1111111111",`+
			`"to_account":"2222222222","amount":"100000","status":"COMPLETED"}`, eventID, transferID)),
		Headers: []kafka.Header{{Key: "event_type", Value: []byte(eventType)}, {Key: "event_id", Value: []byte(eventID)}},
	}
}

func runConsumer(t *testing.T, store *fakeStore, msgs ...kafka.Message) *fakeReader {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Kafka unreachable at first: the consumer must wait it out, not stop.
	reader := &fakeReader{msgs: msgs, fetchFailures: 2, done: cancel}
	c := NewConsumer(reader, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	c.retryDelay = time.Millisecond
	c.Run(ctx)
	return reader
}

func TestConsumerStoresAndCommits(t *testing.T) {
	store := &fakeStore{failures: 2} // the first event needs 3 tries
	reader := runConsumer(t, store,
		event(0, "TransferCompleted", eventID1),
		kafka.Message{Offset: 1, Value: []byte("not json")},
		event(2, "SomethingElse", eventID2),
	)

	if len(store.rows) != 1 || !strings.Contains(store.rows[0].Message, "berhasil") {
		t.Fatalf("rows = %+v, want one completed notification", store.rows)
	}
	// Skipped events are committed too, otherwise they block the partition.
	if fmt.Sprint(reader.committed) != "[0 1 2]" {
		t.Fatalf("committed = %v, want [0 1 2]", reader.committed)
	}
}

// The same event delivered twice (relay duplicate or replay) becomes one
// notification, and both deliveries are committed.
func TestConsumerSkipsDuplicates(t *testing.T) {
	store := &fakeStore{}
	reader := runConsumer(t, store,
		event(0, "TransferCompensated", eventID1),
		event(1, "TransferCompleted", eventID2),
		event(0, "TransferCompensated", eventID1), // replay from the start
		event(1, "TransferCompleted", eventID2),
	)
	if len(store.rows) != 2 {
		t.Fatalf("rows = %d, want 2 (duplicates skipped)", len(store.rows))
	}
	if fmt.Sprint(reader.committed) != "[0 1 0 1]" {
		t.Fatalf("committed = %v, want [0 1 0 1]", reader.committed)
	}
}

// TestConsumerSkipsPoisonMessages: events that can never be stored are logged
// and committed, so the events behind them in the partition still get through.
// Only transient errors are retried.
func TestConsumerSkipsPoisonMessages(t *testing.T) {
	store := &fakeStore{
		failures: 1, // one transient error first: retried, not skipped
		reject: map[string]error{
			eventID2: &pgconn.PgError{Code: "23514", Message: "check constraint violated"},
		},
	}
	reader := runConsumer(t, store,
		eventFor(0, "TransferCompleted", "e-1", transferID),                // not a UUID
		eventFor(1, "TransferCompleted", eventID1, "not-a-uuid"),           // not a UUID
		eventFor(2, "TransferCompleted", "urn:uuid:"+eventID1, transferID), // UUID, not the canonical form
		event(3, "TransferCompleted", eventID2),                            // database rejects it
		event(4, "TransferCompleted", eventID3),                            // good, after one retry
	)

	if len(store.rows) != 1 || store.rows[0].EventID != eventID3 {
		t.Fatalf("rows = %+v, want only %s", store.rows, eventID3)
	}
	if fmt.Sprint(reader.committed) != "[0 1 2 3 4]" {
		t.Fatalf("committed = %v, want [0 1 2 3 4]", reader.committed)
	}
	// Malformed events never reach the database; the rejected one is tried once;
	// the good one twice (transient failure, then success).
	if store.inserts != 3 {
		t.Fatalf("inserts = %d, want 3", store.inserts)
	}
}

func TestPermanentDBError(t *testing.T) {
	tests := []struct {
		err  error
		want bool
	}{
		{&pgconn.PgError{Code: "22P02"}, true},                              // invalid text representation
		{fmt.Errorf("insert: %w", &pgconn.PgError{Code: "23502"}), true},    // not null, wrapped
		{&pgconn.PgError{Code: "23514"}, true},                              // check
		{&pgconn.PgError{Code: "42P01"}, false},                             // undefined table: every event fails
		{&pgconn.PgError{Code: "57P01"}, false},                             // admin shutdown
		{errors.New("dial tcp 127.0.0.1:15434: connection refused"), false}, // no PgError
		{context.DeadlineExceeded, false},
	}
	for _, tc := range tests {
		if got := permanentDBError(tc.err); got != tc.want {
			t.Errorf("permanentDBError(%v) = %v, want %v", tc.err, got, tc.want)
		}
	}
}

func TestListNotifications(t *testing.T) {
	store := &fakeStore{rows: []Notification{{ID: 1, TransferID: transferID, Message: "ok"}}}
	h := NewHandler(store, slog.New(slog.NewTextHandler(io.Discard, nil))).Routes()

	tests := []struct {
		query      string
		wantStatus int
		wantBody   string
	}{
		{"?transfer_id=" + transferID, 200, `"message":"ok"`},
		{"?transfer_id=11111111-1111-1111-1111-111111111111", 200, "[]"},
		{"", 400, "transfer_id"},
		{"?transfer_id=abc", 400, "transfer_id"},
	}
	for _, tc := range tests {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/notifications"+tc.query, nil))
		if rec.Code != tc.wantStatus || !strings.Contains(rec.Body.String(), tc.wantBody) {
			t.Errorf("%q: %d %s, want %d containing %q", tc.query, rec.Code, rec.Body, tc.wantStatus, tc.wantBody)
		}
	}
}
