module github.com/artivisi/training-microservices-2026-01/studi-kasus/account

go 1.26.0

require (
	github.com/MicahParks/keyfunc/v3 v3.8.2
	github.com/artivisi/training-microservices-2026-01/studi-kasus/proto v0.0.0
	github.com/golang-jwt/jwt/v5 v5.3.1
	github.com/jackc/pgx-shopspring-decimal v0.0.0-20220624020537-1d36b5a1853e
	github.com/jackc/pgx/v5 v5.11.0
	github.com/shopspring/decimal v1.6.0
	golang.org/x/time v0.15.0
	google.golang.org/grpc v1.80.0
	google.golang.org/protobuf v1.36.12
)

require (
	github.com/MicahParks/jwkset v0.11.3 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	golang.org/x/net v0.49.0 // indirect
	golang.org/x/sync v0.19.0 // indirect
	golang.org/x/sys v0.40.0 // indirect
	golang.org/x/text v0.33.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260120221211-b8f7ae30c516 // indirect
)

replace github.com/artivisi/training-microservices-2026-01/studi-kasus/proto => ../proto
