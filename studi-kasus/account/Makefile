# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := account

.PHONY: run test build clean

run:
	HTTP_ADDR=:28081 \
	GRPC_ADDR=:29091 \
	DATABASE_URL=postgres://account:account123@localhost:15432/account \
	OAUTH_ISSUER=http://localhost:14444/ \
	OAUTH_JWKS_URL=http://localhost:14444/.well-known/jwks.json \
	OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317 \
	OTEL_SERVICE_NAME=account \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
