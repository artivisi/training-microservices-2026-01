package notification

import (
	"context"
	_ "embed"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schema string

const columns = `id, event_id::text, transfer_id::text, event_type, message, created_at`

type PostgresStore struct {
	pool *pgxpool.Pool
}

// NewPostgresStore connects, verifies the connection, and applies the schema.
func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
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

func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *PostgresStore) Insert(ctx context.Context, n Notification) (Notification, error) {
	rows, err := s.pool.Query(ctx, `
		insert into notification (event_id, transfer_id, event_type, message)
		values (@event_id, @transfer_id, @event_type, @message)
		returning `+columns,
		pgx.NamedArgs{"event_id": n.EventID, "transfer_id": n.TransferID, "event_type": n.EventType, "message": n.Message})
	if err != nil {
		return Notification{}, err
	}
	return pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Notification])
}

func (s *PostgresStore) ListByTransfer(ctx context.Context, transferID string) ([]Notification, error) {
	rows, err := s.pool.Query(ctx,
		`select `+columns+` from notification where transfer_id = @transfer_id order by id`,
		pgx.NamedArgs{"transfer_id": transferID})
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Notification])
}
