SERVICES := account transfer

# Fault injection on the account service (Lab 3). Faults apply to /accounts*
# only; probes and /admin stay fast.
ACCOUNT_URL := http://localhost:28081
TRANSFER_URL := http://localhost:28082

.PHONY: infra-up infra-down infra-reset test fault-slow fault-error fault-clear fault-status breaker

infra-up:
	docker compose up -d --wait

infra-down:
	docker compose down

# Removes the database volumes too: all lab data is lost.
infra-reset:
	docker compose down -v

test:
	@for s in $(SERVICES); do $(MAKE) -C $$s test || exit 1; done

# 3000 ms is above the transfer client's 2 s per-attempt timeout: every call
# times out and counts as a breaker failure.
fault-slow:
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":3000,"error_rate":0}'

# Usage: make fault-error RATE=0.5 (fraction of requests answered 503).
fault-error:
	@test -n "$(RATE)" || { echo "RATE is required, e.g. make fault-error RATE=0.5" >&2; exit 1; }
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":0,"error_rate":$(RATE)}'

fault-clear:
	curl -sS -X DELETE $(ACCOUNT_URL)/admin/fault

fault-status:
	curl -sS $(ACCOUNT_URL)/admin/fault

breaker:
	curl -sS $(TRANSFER_URL)/debug/circuit-breaker
