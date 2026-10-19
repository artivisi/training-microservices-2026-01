# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := transfer

.PHONY: run test build clean

run:
	HTTP_ADDR=:8082 \
	DATABASE_URL=postgres://transfer:transfer123@localhost:15433/transfer \
	ACCOUNT_SERVICE_URL=http://localhost:8081 \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
