# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := transfer

.PHONY: run test build clean

run:
	HTTP_ADDR=:8082 \
	DATABASE_URL=postgres://transfer:transfer123@localhost:15433/transfer \
	ACCOUNT_GRPC_ADDR=localhost:9091 \
	KAFKA_BROKERS=localhost:9092 \
	KAFKA_TOPIC=transfer-events \
	OAUTH_ISSUER=http://localhost:4444/ \
	OAUTH_JWKS_URL=http://localhost:4444/.well-known/jwks.json \
	OAUTH_CLIENT_ID=transfer-service \
	OAUTH_CLIENT_SECRET=transfer-service-secret \
	OAUTH_TOKEN_URL=http://localhost:4444/oauth2/token \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
