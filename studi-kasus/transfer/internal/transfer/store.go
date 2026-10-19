package transfer

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
	pgxdecimal "github.com/jackc/pgx-shopspring-decimal"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/outbox"
)

//go:embed schema.sql
var schema string

// columns is shared by every query so RowToStructByPos maps them onto Transfer in order.
const columns = `id::text, from_account, to_account, amount, status, coalesce(failure_reason, ''), created_at, updated_at`

type PostgresStore struct {
	pool *pgxpool.Pool
}

// NewPostgresStore connects, verifies the connection, and applies the schema.
func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	cfg.AfterConnect = func(_ context.Context, conn *pgx.Conn) error {
		pgxdecimal.Register(conn.TypeMap())
		return nil
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect to database: %w", err)
	}
	if _, err := pool.Exec(ctx, schema); err != nil {
		pool.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &PostgresStore{pool: pool}, nil
}

func (s *PostgresStore) Close() { s.pool.Close() }

// Pool is shared with the outbox relay, which reads the outbox table of this
// same database.
func (s *PostgresStore) Pool() *pgxpool.Pool { return s.pool }

func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *PostgresStore) Create(ctx context.Context, req CreateRequest) (Transfer, error) {
	return one(ctx, s.pool, `
		insert into transfer (from_account, to_account, amount, status)
		values (@from, @to, @amount, 'PENDING')
		returning `+columns,
		pgx.NamedArgs{"from": req.FromAccount, "to": req.ToAccount, "amount": req.Amount})
}

func (s *PostgresStore) Transition(ctx context.Context, id string, from, to Status, reason string, event EventType) (Transfer, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Transfer{}, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

	// "and status = @from" guards the state machine: a transfer that some other
	// process moved on already is not overwritten.
	t, err := one(ctx, tx, `
		update transfer set status = @to, failure_reason = nullif(@reason, ''), updated_at = now()
		where id = @id and status = @from
		returning `+columns,
		pgx.NamedArgs{"id": id, "from": string(from), "to": string(to), "reason": reason})
	if errors.Is(err, ErrNotFound) {
		return Transfer{}, fmt.Errorf("%s -> %s: %w", from, to, ErrStaleState)
	}
	if err != nil {
		return Transfer{}, err
	}

	if event != "" {
		e := Event{
			EventID:     uuid.NewString(),
			TransferID:  t.ID,
			FromAccount: t.FromAccount,
			ToAccount:   t.ToAccount,
			Amount:      t.Amount,
			Status:      t.Status,
			Reason:      t.FailureReason,
			OccurredAt:  t.UpdatedAt,
		}
		payload, err := json.Marshal(e)
		if err != nil {
			return Transfer{}, err
		}
		if err := outbox.Insert(ctx, tx, outbox.Message{
			ID: e.EventID, AggregateID: t.ID, EventType: string(event), Payload: payload,
		}); err != nil {
			return Transfer{}, err
		}
	}
	return t, tx.Commit(ctx)
}

func (s *PostgresStore) Get(ctx context.Context, id string) (Transfer, error) {
	return one(ctx, s.pool, `select `+columns+` from transfer where id = @id`, pgx.NamedArgs{"id": id})
}

// querier is what the pool and a transaction have in common.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func one(ctx context.Context, q querier, sql string, args pgx.NamedArgs) (Transfer, error) {
	rows, err := q.Query(ctx, sql, args)
	if err != nil {
		return Transfer{}, err
	}
	t, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Transfer])
	var pgErr *pgconn.PgError
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return Transfer{}, ErrNotFound
	case errors.As(err, &pgErr) && pgErr.Code == "22P02": // invalid_text_representation: not a UUID
		return Transfer{}, ErrNotFound
	}
	return t, err
}
