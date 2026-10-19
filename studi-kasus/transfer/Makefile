# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := transfer

.PHONY: run test build clean

run:
	HTTP_ADDR=:8082 \
	DATABASE_URL=postgres://transfer:transfer123@localhost:15433/transfer \
	ACCOUNT_GRPC_ADDR=localhost:9091 \
	KAFKA_BROKERS=localhost:9092 \
	KAFKA_TOPIC=transfer-events \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
