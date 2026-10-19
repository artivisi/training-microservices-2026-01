SERVICES := account transfer notification

# Fault injection on the account service (Lab 3). Faults apply to REST /accounts*
# and, from Lab 4, to the gRPC AccountService; probes, gRPC health and /admin
# stay fast.
ACCOUNT_URL := http://localhost:8081
TRANSFER_URL := http://localhost:8082
NOTIFICATION_URL := http://localhost:8083

HYDRA_URL := http://localhost:4444

KAFKA_TOPIC := transfer-events
KAFKA_BIN := /opt/kafka/bin

.PHONY: infra-up infra-down infra-reset test proto fault-slow fault-error fault-clear fault-status breaker \
	events outbox replay duplicates token metrics

# kafka-init creates the topic (idempotent: --if-not-exists); hydra-init
# (re)creates the OAuth2 clients, which Hydra's in-memory storage loses on every
# restart.
infra-up:
	docker compose up -d --wait
	docker compose run --rm kafka-init
	docker compose run --rm hydra-init

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
	docker compose exec kafka $(KAFKA_BIN)/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
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
	docker compose exec kafka $(KAFKA_BIN)/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
		--group notification --topic $(KAFKA_TOPIC) --reset-offsets --to-earliest --execute

# Lab 6: events with more than one notification. Empty after a replay = the
# consumer is idempotent. Rows from Lab 5 (before processed_event) stay listed.
duplicates:
	docker compose exec db-notification psql -U notification -d notification -c \
		"select event_id, event_type, count(*) as notifications from notification group by event_id, event_type having count(*) > 1"

# Lab 7: prints an access token of the channel-app client (scopes transfer:read
# transfer:write), valid for 1 hour. Usage:
#   TOKEN=$(make -s token)
#   curl -H "Authorization: Bearer $TOKEN" localhost:8082/transfers/<id>
# SCOPE narrows it, e.g. make -s token SCOPE=transfer:read.
SCOPE := transfer:read transfer:write
token:
	@resp=$$(curl -sS -u channel-app:channel-app-secret -d grant_type=client_credentials -d "scope=$(SCOPE)" \
		$(HYDRA_URL)/oauth2/token) || exit 1; \
	case "$$resp" in *'"access_token"'*) ;; *) echo "$$resp" >&2; exit 1;; esac; \
	echo "$$resp" | sed -E 's/.*"access_token":"([^"]+)".*/\1/'

# Lab 8: the domain metrics of the three services, straight from their
# /metrics endpoints (what Prometheus scrapes every 5 s). Grafana:
# http://localhost:3000, dashboard "Studi Kasus: Transfer".
metrics:
	@for u in $(ACCOUNT_URL) $(TRANSFER_URL) $(NOTIFICATION_URL); do \
		echo "# $$u/metrics"; \
		curl -sS $$u/metrics | grep -E '^(transfers_total|circuit_breaker_|outbox_pending|notifications_processed_total)' || true; \
	done
