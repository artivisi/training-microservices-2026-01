create table if not exists transfer (
    id             uuid           primary key default gen_random_uuid(),
    from_account   varchar(10)    not null,
    to_account     varchar(10)    not null,
    amount         numeric(19, 2) not null check (amount > 0),
    status         varchar(20)    not null,
    failure_reason text,
    created_at     timestamptz    not null default now(),
    updated_at     timestamptz    not null default now()
);

-- Saga states (Lab 5). Re-applied on every start so a database created in
-- Labs 2-4, with only PENDING/COMPLETED/FAILED, gets the new states as well.
alter table transfer alter column status type varchar(20);
alter table transfer drop constraint if exists transfer_status_check;
alter table transfer add constraint transfer_status_check check (status in
    ('PENDING', 'DEBITED', 'COMPLETED', 'FAILED', 'COMPENSATED', 'COMPENSATION_FAILED'));

-- Transactional outbox (Lab 5). An event is inserted in the same transaction as
-- the state change it reports; the relay publishes it to Kafka afterwards and
-- sets published_at. Writing to the database and to Kafka directly would be two
-- systems without a shared transaction: a crash between them loses the event
-- or publishes one for a change that was rolled back.
create table if not exists outbox (
    id           uuid        primary key,
    aggregate_id uuid        not null,
    event_type   varchar(50) not null,
    payload      jsonb       not null,
    created_at   timestamptz not null default now(),
    published_at timestamptz
);

-- The relay only ever looks for unpublished rows; a partial index stays small
-- however many published rows pile up.
create index if not exists outbox_unpublished on outbox (created_at) where published_at is null;

-- Idempotency key (Lab 6): the value of the Idempotency-Key header of POST
-- /transfers. A channel that retries a request whose answer it never got
-- (timeout, dropped connection) sends the same key again and gets the original
-- transfer back instead of a second debit. NULL for requests without the
-- header; PostgreSQL treats NULLs as distinct, so they never collide on the
-- unique index.
alter table transfer add column if not exists idempotency_key varchar(100);
create unique index if not exists transfer_idempotency_key on transfer (idempotency_key);
