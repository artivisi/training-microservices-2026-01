create table if not exists account (
    number     varchar(10)    primary key,
    owner_name varchar(100)   not null,
    balance    numeric(19, 2) not null check (balance >= 0),
    created_at timestamptz    not null default now()
);

-- Every balance change is recorded; the balance column is the running total.
create table if not exists mutation (
    id             bigint generated always as identity primary key,
    account_number varchar(10)    not null references account (number),
    type           varchar(6)     not null check (type in ('DEBIT', 'CREDIT')),
    amount         numeric(19, 2) not null check (amount > 0),
    reference      varchar(64)    not null,
    created_at     timestamptz    not null default now()
);
