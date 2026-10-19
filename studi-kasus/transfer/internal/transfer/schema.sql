create table if not exists transfer (
    id             uuid           primary key default gen_random_uuid(),
    from_account   varchar(10)    not null,
    to_account     varchar(10)    not null,
    amount         numeric(19, 2) not null check (amount > 0),
    status         varchar(10)    not null check (status in ('PENDING', 'COMPLETED', 'FAILED')),
    failure_reason text,
    created_at     timestamptz    not null default now(),
    updated_at     timestamptz    not null default now()
);
