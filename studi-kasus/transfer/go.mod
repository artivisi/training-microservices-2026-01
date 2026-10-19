module github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer

go 1.26.0

require (
	github.com/artivisi/training-microservices-2026-01/studi-kasus/proto v0.0.0
	github.com/failsafe-go/failsafe-go v0.9.8
	github.com/google/uuid v1.6.0
	github.com/jackc/pgx-shopspring-decimal v0.0.0-20220624020537-1d36b5a1853e
	github.com/jackc/pgx/v5 v5.11.0
	github.com/segmentio/kafka-go v0.4.51
	github.com/shopspring/decimal v1.6.0
	google.golang.org/grpc v1.80.0
)

require (
	github.com/bits-and-blooms/bitset v1.24.4 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/klauspost/compress v1.15.9 // indirect
	github.com/pierrec/lz4/v4 v4.1.15 // indirect
	golang.org/x/net v0.49.0 // indirect
	golang.org/x/sync v0.19.0 // indirect
	golang.org/x/sys v0.40.0 // indirect
	golang.org/x/text v0.33.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260120221211-b8f7ae30c516 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
)

replace github.com/artivisi/training-microservices-2026-01/studi-kasus/proto => ../proto
