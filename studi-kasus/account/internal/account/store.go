package account

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

func (s *PostgresStore) Create(ctx context.Context, req CreateRequest) (Account, error) {
	rows, err := s.pool.Query(ctx, `
		insert into account (number, owner_name, balance)
		values (@number, @owner_name, @balance)
		returning number, owner_name, balance, created_at`,
		pgx.NamedArgs{"number": req.Number, "owner_name": req.OwnerName, "balance": req.InitialBalance})
	if err != nil {
		return Account{}, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
		return Account{}, ErrAlreadyExists
	}
	return a, err
}

func (s *PostgresStore) Get(ctx context.Context, number string) (Account, error) {
	rows, err := s.pool.Query(ctx,
		`select number, owner_name, balance, created_at from account where number = @number`,
		pgx.NamedArgs{"number": number})
	if err != nil {
		return Account{}, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
	if errors.Is(err, pgx.ErrNoRows) {
		return Account{}, ErrNotFound
	}
	return a, err
}

func (s *PostgresStore) List(ctx context.Context) ([]Account, error) {
	rows, err := s.pool.Query(ctx,
		`select number, owner_name, balance, created_at from account order by number limit 100`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Account])
}
