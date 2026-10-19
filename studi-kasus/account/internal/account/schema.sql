create table if not exists account (
    number     varchar(10)    primary key,
    owner_name varchar(100)   not null,
    balance    numeric(19, 2) not null check (balance >= 0),
    created_at timestamptz    not null default now()
);
