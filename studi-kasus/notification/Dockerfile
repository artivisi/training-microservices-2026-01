# Multi-stage build of the notification service. Build context: studi-kasus/ (not this
# directory), the same as for account and transfer, so make images builds all
# three the same way. Notification does not import the proto module (the
# events are JSON on Kafka), so only notification/ is copied:
#   docker build -f notification/Dockerfile -t studi-kasus/notification:1.0.0 .
FROM golang:1.27.2-alpine AS build

# GOWORK=off: build this module with its own go.mod/go.sum, not the workspace.
# The image then depends only on this service; a change in another
# service's go.mod does not invalidate the cache here, and the CI pipeline of
# one service builds it alone (Lab 10).
# CGO_ENABLED=0: a static binary without libc, which runs in an empty image.
ENV GOWORK=off CGO_ENABLED=0

# Module files first: the download layer stays cached until go.mod/go.sum
# change, not on every source edit.
WORKDIR /src
COPY notification/go.mod notification/go.sum notification/
WORKDIR /src/notification
RUN go mod download

COPY notification/ /src/notification/
# -trimpath drops the build machine's paths from the binary (reproducible,
# nothing about the builder leaks); -s -w drops the symbol table and DWARF
# debug data (smaller image; stack traces still have function names and lines).
RUN go build -trimpath -ldflags "-s -w" -o /out/notification .

# Empty base image: no shell, no package manager, nothing to patch but the
# binary. The trade-off: no docker exec into a shell for debugging; use
# kubectl debug with an ephemeral container instead.
FROM scratch
# CA certificates for outgoing TLS (an https:// OAuth or OTLP endpoint in
# production). The lab endpoints are plain HTTP, but an image without them
# fails only later, on the first TLS connection.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/notification /notification
# Numeric UID:GID, not a name: scratch has no /etc/passwd, and Kubernetes can
# only check runAsNonRoot against a number. 65532 is the conventional
# "nonroot" ID. Nothing in the image needs a writable or owned path, so the
# binary also runs under the arbitrary UID that OpenShift's restricted SCC
# assigns, and with readOnlyRootFilesystem.
USER 65532:65532
# HTTP 8083. Documentation only: the ports come from the environment
# (HTTP_ADDR).
EXPOSE 8083
ENTRYPOINT ["/notification"]
