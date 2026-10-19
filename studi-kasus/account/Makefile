# Every pipeline step calls a target here, so CI and laptops run the same commands.
SERVICE := account

.PHONY: run test build clean

run:
	HTTP_ADDR=:8081 \
	DATABASE_URL=postgres://account:account123@localhost:15432/account \
	go run .

test:
	go vet ./...
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/$(SERVICE) .

clean:
	rm -rf bin
