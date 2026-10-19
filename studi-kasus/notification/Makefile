# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := notification

.PHONY: run test build clean

run:
	HTTP_ADDR=:28083 \
	DATABASE_URL=postgres://notification:notification123@localhost:15434/notification \
	KAFKA_BROKERS=localhost:19092 \
	KAFKA_TOPIC=transfer-events \
	KAFKA_GROUP_ID=notification \
	OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317 \
	OTEL_SERVICE_NAME=notification \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin

# image, push, deploy (Lab 10).
include ../pipeline.mk
