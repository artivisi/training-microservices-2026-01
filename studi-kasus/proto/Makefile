# Generated code is committed: services build without protoc installed, and a
# contract change shows up in review as a diff of the generated API too.
MODULE := github.com/artivisi/training-microservices-2026-01/studi-kasus/proto
PROTO_FILES := $(shell find . -name '*.proto' -not -path './gen/*')
GOBIN := $(shell go env GOPATH)/bin

.PHONY: generate test

generate:
	PATH="$$PATH:$(GOBIN)" protoc -I . \
		--go_out=. --go_opt=module=$(MODULE) \
		--go-grpc_out=. --go-grpc_opt=module=$(MODULE) \
		$(PROTO_FILES)

# Nothing to test in generated code; vet catches a broken generation.
test:
	go vet ./...
