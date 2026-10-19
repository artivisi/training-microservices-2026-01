-- One row per notification sent to the customer (here: logged).
create table if not exists notification (
    id          bigint generated always as identity primary key,
    event_id    uuid        not null,
    transfer_id uuid        not null,
    event_type  varchar(50) not null,
    message     text        not null,
    created_at  timestamptz not null default now()
);

create index if not exists notification_transfer on notification (transfer_id);

-- Idempotent consumer (Lab 6): one row per event already handled. It is
-- inserted in the same transaction as the notification, so "handled" and
-- "notification stored" are always both true or both false. A redelivered event
-- (relay duplicate, rebalance, replay) hits the primary key and is skipped.
--
-- A separate table, not a unique index on notification.event_id: the dedup rule
-- is "this event was handled", which also covers events that produce no row
-- or several rows. It also keeps the duplicate notifications of Lab 5 as they
-- are instead of failing the index creation on them.
create table if not exists processed_event (
    event_id     uuid        primary key,
    processed_at timestamptz not null default now()
);

-- Events handled in Lab 5, before this table existed, count as processed: a
-- replay after the upgrade must not notify about them once more. Re-running it
-- on every start changes nothing.
insert into processed_event (event_id)
select distinct event_id from notification
on conflict (event_id) do nothing;
