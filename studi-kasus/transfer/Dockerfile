# Multi-stage build of the transfer service. Build context: studi-kasus/ (not this
# directory), so the proto module that go.mod's replace directive points to
# (../proto) is part of the context:
#   docker build -f transfer/Dockerfile -t studi-kasus/transfer:1.0.0 .
FROM golang:1.27.2-alpine AS build

# GOWORK=off: build this module with its own go.mod/go.sum, not the workspace.
# The image then depends only on this service and proto; a change in another
# service's go.mod does not invalidate the cache here, and the CI pipeline of
# one service builds it alone (Lab 10).
# CGO_ENABLED=0: a static binary without libc, which runs in an empty image.
ENV GOWORK=off CGO_ENABLED=0

# Module files first: the download layer stays cached until go.mod/go.sum
# change, not on every source edit.
WORKDIR /src
COPY proto/go.mod proto/go.sum proto/
COPY transfer/go.mod transfer/go.sum transfer/
WORKDIR /src/transfer
RUN go mod download

COPY proto/ /src/proto/
COPY transfer/ /src/transfer/
# -trimpath drops the build machine's paths from the binary (reproducible,
# nothing about the builder leaks); -s -w drops the symbol table and DWARF
# debug data (smaller image; stack traces still have function names and lines).
RUN go build -trimpath -ldflags "-s -w" -o /out/transfer .

# Empty base image: no shell, no package manager, nothing to patch but the
# binary. The trade-off: no docker exec into a shell for debugging; use
# kubectl debug with an ephemeral container instead.
FROM scratch
# CA certificates for outgoing TLS (an https:// OAuth or OTLP endpoint in
# production). The lab endpoints are plain HTTP, but an image without them
# fails only later, on the first TLS connection.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/transfer /transfer
# Numeric UID:GID, not a name: scratch has no /etc/passwd, and Kubernetes can
# only check runAsNonRoot against a number. 65532 is the conventional
# "nonroot" ID. Nothing in the image needs a writable or owned path, so the
# binary also runs under the arbitrary UID that OpenShift's restricted SCC
# assigns, and with readOnlyRootFilesystem.
USER 65532:65532
# HTTP 8082. Documentation only: the ports come from the environment
# (HTTP_ADDR).
EXPOSE 8082
ENTRYPOINT ["/transfer"]
