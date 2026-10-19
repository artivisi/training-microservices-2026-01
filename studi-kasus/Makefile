SERVICES := account transfer

# Fault injection on the account service (Lab 3). Faults apply to REST /accounts*
# and, from Lab 4, to the gRPC AccountService; probes, gRPC health and /admin
# stay fast.
ACCOUNT_URL := http://localhost:8081
TRANSFER_URL := http://localhost:8082

.PHONY: infra-up infra-down infra-reset test proto fault-slow fault-error fault-clear fault-status breaker

infra-up:
	docker compose up -d --wait

infra-down:
	docker compose down

# Removes the database volumes too: all lab data is lost.
infra-reset:
	docker compose down -v

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
