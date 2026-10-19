SERVICES := account transfer notification

# Fault injection on the account service (Lab 3). Faults apply to REST /accounts*
# and, from Lab 4, to the gRPC AccountService; probes, gRPC health and /admin
# stay fast.
ACCOUNT_URL := http://localhost:28081
TRANSFER_URL := http://localhost:28082

KAFKA_TOPIC := transfer-events
KAFKA_BIN := /opt/kafka/bin

.PHONY: infra-up infra-down infra-reset test proto fault-slow fault-error fault-clear fault-status breaker \
	events outbox replay duplicates

# kafka-init creates the topic (idempotent: --if-not-exists).
infra-up:
	docker compose up -d --wait
	docker compose run --rm kafka-init

# --profile init: down skips services of inactive profiles, and a leftover
# kafka-init container would keep the network from being removed.
infra-down:
	docker compose --profile init down

# Removes the database and Kafka volumes too: all lab data is lost.
infra-reset:
	docker compose --profile init down -v

test:
	$(MAKE) -C proto test
	@for s in $(SERVICES); do $(MAKE) -C $$s test || exit 1; done

# Regenerates proto/gen after a .proto change (Lab 4). Needs protoc,
# protoc-gen-go and protoc-gen-go-grpc.
proto:
	$(MAKE) -C proto generate

# 3000 ms is above the transfer client's 2 s per-attempt timeout: every call
# times out and counts as a breaker failure.
fault-slow:
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":3000,"error_rate":0}'

# Usage: make fault-error RATE=0.5 (fraction of requests answered HTTP 503 /
# gRPC Unavailable).
fault-error:
	@test -n "$(RATE)" || { echo "RATE is required, e.g. make fault-error RATE=0.5" >&2; exit 1; }
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":0,"error_rate":$(RATE)}'

fault-clear:
	curl -sS -X DELETE $(ACCOUNT_URL)/admin/fault

fault-status:
	curl -sS $(ACCOUNT_URL)/admin/fault

breaker:
	curl -sS $(TRANSFER_URL)/debug/circuit-breaker

# Lab 5 helpers.

# Prints every event on the topic with its partition, headers and key, then
# exits after 5 s without new events (that exit is logged as a TimeoutException
# by the console consumer; it is not an error).
events:
	docker compose exec kafka $(KAFKA_BIN)/kafka-console-consumer.sh --bootstrap-server localhost:19092 \
		--topic $(KAFKA_TOPIC) --from-beginning --timeout-ms 5000 \
		--property print.key=true --property print.headers=true --property print.partition=true

# The newest outbox rows in the transfer database; published_at empty = not on Kafka yet.
outbox:
	docker compose exec db-transfer psql -U transfer -d transfer -c \
		"select id, aggregate_id, event_type, created_at, published_at from outbox order by created_at desc limit 20"

# Rewinds the notification consumer group to the first event, so every event is
# delivered again. Kafka only resets a group without active members: stop the
# notification service first.
replay:
	docker compose exec kafka $(KAFKA_BIN)/kafka-consumer-groups.sh --bootstrap-server localhost:19092 \
		--group notification --topic $(KAFKA_TOPIC) --reset-offsets --to-earliest --execute

# Lab 6: events with more than one notification. Empty after a replay = the
# consumer is idempotent. Rows from Lab 5 (before processed_event) stay listed.
duplicates:
	docker compose exec db-notification psql -U notification -d notification -c \
		"select event_id, event_type, count(*) as notifications from notification group by event_id, event_type having count(*) > 1"
