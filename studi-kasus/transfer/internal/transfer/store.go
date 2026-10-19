package transfer

import (
	"context"
	_ "embed"
	"errors"
	"fmt"

	pgxdecimal "github.com/jackc/pgx-shopspring-decimal"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
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

func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *PostgresStore) Create(ctx context.Context, req CreateRequest) (Transfer, error) {
	return s.one(ctx, `
		insert into transfer (from_account, to_account, amount, status)
		values (@from, @to, @amount, 'PENDING')
		returning `+columns,
		pgx.NamedArgs{"from": req.FromAccount, "to": req.ToAccount, "amount": req.Amount})
}

func (s *PostgresStore) Finish(ctx context.Context, id string, status Status, reason string) (Transfer, error) {
	return s.one(ctx, `
		update transfer set status = @status, failure_reason = nullif(@reason, ''), updated_at = now()
		where id = @id
		returning `+columns,
		pgx.NamedArgs{"id": id, "status": string(status), "reason": reason})
}

func (s *PostgresStore) Get(ctx context.Context, id string) (Transfer, error) {
	return s.one(ctx, `select `+columns+` from transfer where id = @id`, pgx.NamedArgs{"id": id})
}

func (s *PostgresStore) one(ctx context.Context, sql string, args pgx.NamedArgs) (Transfer, error) {
	rows, err := s.pool.Query(ctx, sql, args)
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
