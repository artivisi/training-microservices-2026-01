SERVICES := account

.PHONY: infra-up infra-down infra-reset test

infra-up:
	docker compose up -d --wait

infra-down:
	docker compose down

# Removes the database volumes too: all lab data is lost.
infra-reset:
	docker compose down -v

test:
	@for s in $(SERVICES); do $(MAKE) -C $$s test || exit 1; done
