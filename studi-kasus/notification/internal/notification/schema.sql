-- One row per notification sent to the customer (here: logged).
-- event_id is deliberately NOT unique yet: a redelivered event is stored and
-- sent again. Lab 6 makes the consumer idempotent.
create table if not exists notification (
    id          bigint generated always as identity primary key,
    event_id    uuid        not null,
    transfer_id uuid        not null,
    event_type  varchar(50) not null,
    message     text        not null,
    created_at  timestamptz not null default now()
);

create index if not exists notification_transfer on notification (transfer_id);
