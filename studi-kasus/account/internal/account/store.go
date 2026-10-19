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

func (s *PostgresStore) Mutate(ctx context.Context, number string, t MutationType, req MutationRequest) (Account, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Account{}, false, err
	}
	defer tx.Rollback(ctx) // no-op after Commit

	// The mutation row goes in first, as the idempotency check. A concurrent call
	// with the same reference waits on the unique index until this transaction
	// ends and then sees the conflict, so two racing retries still apply once.
	tag, err := tx.Exec(ctx, `
		insert into mutation (account_number, type, amount, reference)
		values (@number, @type, @amount, @reference)
		on conflict (account_number, type, reference) do nothing`,
		pgx.NamedArgs{"number": number, "type": string(t), "amount": req.Amount, "reference": req.Reference})
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" { // foreign_key_violation: no such account
		return Account{}, false, ErrNotFound
	}
	if err != nil {
		return Account{}, false, err
	}
	if tag.RowsAffected() == 0 {
		// Applied before: this is a retry of a call whose answer got lost (timeout,
		// dropped connection). Answer with the current account, as if it were the
		// first call. A stricter API would also compare the amount and reject a
		// different amount under the same reference.
		//
		// Read inside the same transaction, not with s.Get: that would take a second
		// pool connection while this one is still held, and under load (pool
		// exhausted by concurrent retries) wait for itself.
		rows, err := tx.Query(ctx,
			`select number, owner_name, balance, created_at from account where number = @number`,
			pgx.NamedArgs{"number": number})
		if err != nil {
			return Account{}, false, err
		}
		a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
		if err != nil {
			return Account{}, false, err
		}
		return a, false, tx.Commit(ctx)
	}

	delta := req.Amount
	if t == Debit {
		delta = delta.Neg()
	}
	// The balance check sits in the WHERE clause, so two concurrent debits cannot
	// both pass it: the second one waits for the row lock and re-evaluates.
	rows, err := tx.Query(ctx, `
		update account set balance = balance + @delta
		where number = @number and balance + @delta >= 0
		returning number, owner_name, balance, created_at`,
		pgx.NamedArgs{"number": number, "delta": delta})
	if err != nil {
		return Account{}, false, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Account])
	if errors.Is(err, pgx.ErrNoRows) {
		// The account exists (the foreign key accepted the mutation row), so the
		// balance is too low. Rollback removes the mutation row again: a later
		// retry with the same reference is evaluated afresh.
		return Account{}, false, ErrInsufficientFunds
	}
	if err != nil {
		return Account{}, false, err
	}
	return a, true, tx.Commit(ctx)
}

func (s *PostgresStore) List(ctx context.Context) ([]Account, error) {
	rows, err := s.pool.Query(ctx,
		`select number, owner_name, balance, created_at from account order by number limit 100`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Account])
}
