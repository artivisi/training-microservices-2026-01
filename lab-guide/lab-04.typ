#import "../_template/panduan.typ": note, perintah

= Lab 4: gRPC untuk Komunikasi Antar-_Service_

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

- menulis kontrak _service_ dalam _protocol buffers_ (_protobuf_) dan menghasilkan kode Go darinya dengan `protoc`, `protoc-gen-go` serta `protoc-gen-go-grpc`;
- menjalankan server gRPC di _service_ `account` berdampingan dengan REST API yang sudah ada, lengkap dengan _health service_ dan _reflection_;
- memetakan _error_ domain ke kode status gRPC (`NotFound`, `FailedPrecondition`, `InvalidArgument`) sehingga pemanggil dapat membedakan penolakan bisnis dari gangguan infrastruktur;
- memasang _unary server interceptor_ untuk _logging_ dan _fault injection_;
- memindahkan _policy_ failsafe-go dari Lab 3 ke _unary client interceptor_ di _service_ `transfer`;
- menguji server dan _client_ gRPC tanpa membuka port jaringan dengan `bufconn`.

== Gambaran

Hingga Lab 3, `transfer` memanggil `account` melalui REST: `POST /accounts/{number}/debit` dan `/credit`. REST API tersebut juga terbuka untuk aplikasi _channel_ (aplikasi _mobile_, _web_, mitra). Akibatnya, aplikasi _channel_ secara teknis dapat mengubah saldo tanpa melalui transfer.

Lab ini memisahkan kedua jenis pemanggil:

- *REST untuk _channel_.* Aplikasi _channel_ tetap menggunakan REST API `account` (membuat dan membaca rekening). Format JSON di atas HTTP mudah digunakan dari _browser_, aplikasi _mobile_ maupun sistem mitra.
- *gRPC untuk komunikasi internal.* _Service_ lain memanggil `GetAccount`, `Debit` dan `Credit` melalui gRPC. Kontraknya ditulis dalam file `.proto`, kode _client_ dan server dihasilkan dari kontrak tersebut, dan _payload_-nya dikodekan secara biner (_protobuf_) di atas HTTP/2. Perubahan kontrak terlihat sebagai _diff_ pada file `.proto` dan pada kode hasil _generate_, sehingga ketidakcocokan antara _client_ dan server tertangkap saat kompilasi, sebelum _service_ dijalankan.

Endpoint REST _debit_ dan _credit_ dihapus. Sejak lab ini, perubahan saldo hanya dapat dilakukan melalui gRPC.

```
             REST :28082                   gRPC :29091
 aplikasi ───────────────► transfer ─────────────────────► account
 channel   POST /transfers  (client     Debit, Credit     (server gRPC
                            interceptor:                  + interceptor:
                            retry, breaker,               logging,
                            timeout)                      fault injection)
                                                              │
 aplikasi ───────────────────────────────────────────────────►│ REST :28081
 channel   POST/GET /accounts, /admin/fault                    │
                                                          db-account
```

Kebijakan _resiliency_ dari Lab 3 tidak berubah: _timeout_ 2 detik per percobaan, _retry_ maksimal 3 kali dengan _backoff_ 100 ms hingga 1 detik ditambah _jitter_, dan _circuit breaker_ yang terbuka setelah 5 kegagalan dari 10 panggilan terakhir. Yang berubah adalah tempat pemasangannya. Di Lab 3 _policy_ tersebut dipasang sebagai _round tripper_ HTTP. Di lab ini _policy_ yang sama dipasang sebagai _interceptor_ gRPC, dan aturan _retry_ serta penghitungan kegagalan kini membaca kode status gRPC sebagai pengganti kode status HTTP.

Struktur yang bertambah atau berubah di lab ini:

```
studi-kasus/
├── go.work                      # + ./proto
├── Makefile                     # + target proto, test ikut memeriksa proto
├── proto/                       # modul baru
│   ├── go.mod
│   ├── Makefile                 # generate, test
│   ├── account/v1/account.proto
│   └── gen/account/v1/          # hasil generate, ikut di-commit
├── account/
│   ├── config.go                # + GRPC_ADDR
│   ├── main.go                  # + server gRPC, health, reflection
│   └── internal/
│       ├── account/grpc.go      # baru: implementasi AccountService
│       ├── account/http.go      # - endpoint debit/credit
│       ├── fault/fault.go       # + UnaryServerInterceptor
│       └── interceptor/logging.go   # baru
└── transfer/
    ├── config.go                # ACCOUNT_GRPC_ADDR menggantikan ACCOUNT_SERVICE_URL
    ├── main.go
    └── internal/accountclient/client.go   # client gRPC + failsafegrpc
```

== Titik Awal

Lab ini melanjutkan kondisi kode di akhir Lab 3. Peserta yang menyelesaikan Lab 3 sendiri dapat langsung melanjutkan dari kode miliknya. Peserta yang tertinggal memulai dari _checkpoint_ `lab-03`:

#perintah[```bash
cd studi-kasus
git switch -c kerja-lab-04 lab-03
```]

Pastikan `protoc` dan kedua _plugin_ Go sudah terpasang (bagian dari panduan persiapan). Kedua _plugin_ berada di `$(go env GOPATH)/bin`, sehingga folder tersebut perlu ada di `PATH`:

#perintah[```bash
export PATH="$PATH:$(go env GOPATH)/bin"
protoc --version
protoc-gen-go --version        # protoc-gen-go v1.36.12
protoc-gen-go-grpc --version   # protoc-gen-go-grpc 1.6.2
```]

Bila salah satu _plugin_ belum ada, pasang dengan versi yang sama dengan _checkpoint_:

#perintah[```bash
go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
```]

Jalankan infrastruktur lab (PostgreSQL) bila belum berjalan:

#perintah[```bash
make infra-up
```]

== Langkah

=== Modul `proto` dan Kontrak `AccountService`

Kontrak gRPC ditempatkan di modul Go tersendiri, `studi-kasus/proto`. Dengan modul terpisah, `account` (server) dan `transfer` (_client_) mengimpor kode yang persis sama, dan tidak satu pun dari keduanya menjadi pemilik kontrak.

Buat folder dan file `proto/account/v1/account.proto`. Segmen `v1` pada _path_ dan nama _package_ `account.v1` menyiapkan ruang untuk versi berikutnya: perubahan yang tidak kompatibel ditulis sebagai `account.v2`, sementara `v1` tetap dilayani hingga semua _client_ pindah.

```proto
// Internal contract between services. Channel-facing clients (mobile, web,
// partners) keep using the REST API; gRPC is for service-to-service calls.
syntax = "proto3";

package account.v1;

import "google/protobuf/timestamp.proto";

option go_package = "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1;accountv1";

// AccountService exposes balance reads and mutations to other services.
//
// Errors are gRPC status codes:
//   NOT_FOUND           the account does not exist
//   FAILED_PRECONDITION the balance is too low for a debit
//   INVALID_ARGUMENT    a field is malformed; the message names it
//   UNAVAILABLE         the request was refused before it was processed
service AccountService {
  rpc GetAccount(GetAccountRequest) returns (GetAccountResponse);
  rpc Debit(DebitRequest) returns (DebitResponse);
  rpc Credit(CreditRequest) returns (CreditResponse);
}

// Every RPC has its own request and response message, even when two of them
// look alike today: each can then gain fields without touching the others.

message GetAccountRequest {
  string number = 1;
}

message GetAccountResponse {
  Account account = 1;
}

// Amounts are decimal strings ("150000.50"), not double: binary floating point
// cannot represent most decimal fractions exactly (0.1 + 0.2 != 0.3), and money
// must not drift by rounding. Both sides parse them with shopspring/decimal.
message DebitRequest {
  string number = 1;
  string amount = 2;
  // reference ties the mutation to the business transaction, e.g. a transfer ID.
  string reference = 3;
}

message DebitResponse {
  Account account = 1;
}

message CreditRequest {
  string number = 1;
  string amount = 2;
  string reference = 3;
}

message CreditResponse {
  Account account = 1;
}

message Account {
  string number = 1;
  string owner_name = 2;
  // balance is a decimal string, like the amounts above.
  string balance = 3;
  google.protobuf.Timestamp created_at = 4;
}
```

Beberapa keputusan dalam kontrak tersebut perlu diperhatikan:

- *Nominal sebagai _string_ desimal.* _Protobuf_ memiliki tipe `double`, tetapi bilangan biner berkoma mengambang (_floating point_) tidak dapat menyimpan sebagian besar pecahan desimal secara tepat. Nilai `0.1 + 0.2` pada `double` menghasilkan `0.30000000000000004`. Untuk uang, selisih pembulatan sekecil apa pun tidak dapat diterima. Kedua sisi mengirim nominal sebagai teks (`"150000.50"`) dan mengolahnya dengan `shopspring/decimal`, sama seperti kolom `numeric(19,2)` di database.
- *Nomor _field_ adalah bagian dari kontrak.* Pada format biner, setiap _field_ dikenali dari nomornya (`= 1`, `= 2`), bukan dari namanya. Nomor yang sudah digunakan tidak boleh diganti atau digunakan ulang untuk _field_ lain. _Field_ baru selalu mendapat nomor baru.
- *Satu _message request_ dan satu _message response_ untuk setiap RPC.* `DebitRequest` dan `CreditRequest` saat ini sama persis. Dengan _message_ terpisah, salah satunya dapat ditambah _field_ kelak tanpa mengubah RPC lainnya.
- *Kode _error_ ditulis di komentar kontrak.* Pemanggil mengambil keputusan berdasarkan kode status (misalnya boleh _retry_ atau tidak), sehingga daftar kode tersebut termasuk kontrak, sama pentingnya dengan _field_.

Opsi `go_package` menentukan _import path_ kode Go hasil _generate_ (`.../proto/gen/account/v1`) dan nama _package_-nya (`accountv1`, setelah titik koma).

Selanjutnya buat `proto/Makefile`:

```make
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
```

Opsi `--go_opt=module=...` memotong awalan _module path_ dari `go_package`, sehingga file hasil _generate_ ditulis ke `gen/account/v1/` di dalam modul `proto` tanpa struktur folder `github.com/...` yang panjang.

Tambahkan dua target di `studi-kasus/Makefile`: `test` ikut memeriksa kode hasil _generate_, dan `proto` menjadi jalan pintas untuk _generate_ ulang dari folder `studi-kasus`.

```make
.PHONY: infra-up infra-down infra-reset test proto fault-slow fault-error fault-clear fault-status breaker

test:
	$(MAKE) -C proto test
	@for s in $(SERVICES); do $(MAKE) -C $$s test || exit 1; done

# Regenerates proto/gen after a .proto change (Lab 4). Needs protoc,
# protoc-gen-go and protoc-gen-go-grpc.
proto:
	$(MAKE) -C proto generate
```

=== Kode Go Hasil _Generate_

Jalankan `protoc`, lalu jadikan folder `proto` sebuah modul Go dan daftarkan ke _workspace_:

#perintah[```bash
make -C proto generate
cd proto
go mod init github.com/artivisi/training-microservices-2026-01/studi-kasus/proto
go get google.golang.org/grpc@v1.80.0 google.golang.org/protobuf@v1.36.12
go mod tidy
cd ..
go work use ./proto
```]

Perintah `go work use` menambahkan baris `./proto` ke `go.work`, sehingga _workspace_ kini berisi `account`, `proto` dan `transfer`.

`protoc` menghasilkan dua file di `proto/gen/account/v1/`:

#table(
  columns: (auto, 1fr),
  [File], [Isi],
  [`account.pb.go`], [_Struct_ Go untuk setiap _message_ (`DebitRequest`, `Account`, dan seterusnya) beserta _getter_ seperti `GetNumber()`. Dihasilkan oleh `protoc-gen-go`.],
  [`account_grpc.pb.go`], [_Interface_ `AccountServiceClient` dan konstruktornya `NewAccountServiceClient`, _interface_ `AccountServiceServer`, _struct_ `UnimplementedAccountServiceServer`, fungsi `RegisterAccountServiceServer`, serta `AccountService_ServiceDesc` yang memuat nama _service_. Dihasilkan oleh `protoc-gen-go-grpc`.],
)

Kedua file tersebut ikut di-_commit_. Dengan begitu, _service_ dapat di-_build_ (termasuk di _pipeline_ CI dan di Docker pada Lab 9) tanpa `protoc`, dan setiap perubahan kontrak terlihat di _review_ sebagai _diff_ API Go yang dihasilkannya. File hasil _generate_ tidak boleh diubah dengan tangan: perubahan selalu dimulai dari file `.proto`, lalu `make proto` dijalankan ulang.

#note[Bagian atas file hasil _generate_ memuat komentar pembuka file `.proto` serta versi `protoc` yang digunakan (misalnya `protoc v7.36.2`). Bila versi `protoc` di laptop peserta berbeda dari versi yang digunakan untuk _checkpoint_, baris versi tersebut ikut berbeda saat dibandingkan dengan `git diff lab-04`. Perbedaan tersebut tidak memengaruhi kode.]

=== Dependensi di _Service_ `account`

Modul `account` kini mengimpor modul `proto`. Di dalam _workspace_, Go sudah menemukan modul tersebut lewat `go.work`. Namun `go mod tidy` dan _build_ Docker pada Lab 9 bekerja per modul, tanpa `go.work`, sehingga `go.mod` milik `account` perlu tahu letak modul `proto` melalui direktif `replace`:

#perintah[```bash
cd account
go mod edit \
  -require=github.com/artivisi/training-microservices-2026-01/studi-kasus/proto@v0.0.0 \
  -replace=github.com/artivisi/training-microservices-2026-01/studi-kasus/proto=../proto
cd ..
```]

Versi `v0.0.0` hanya pengisi: dengan `replace`, Go selalu mengambil isi folder `../proto`. Jalankan `go mod tidy` di folder `account` setelah file `grpc.go` dan `main.go` pada langkah berikutnya selesai ditulis, agar `google.golang.org/grpc` ikut tercatat.

=== Implementasi `AccountService` di `account`

Buat file `account/internal/account/grpc.go`. File ini berada di _package_ yang sama dengan _handler_ REST (`http.go`) dan menggunakan `Store` yang sama. Perbedaannya hanya pada _transport_ dan kosakata _error_-nya.

```go
package account

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"strings"

	"github.com/shopspring/decimal"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
)

// GRPCServer is the internal API for other services. It uses the same Store as
// the REST handler; only the transport and the error vocabulary differ.
type GRPCServer struct {
	accountv1.UnimplementedAccountServiceServer
	store Store
	log   *slog.Logger
}

func NewGRPCServer(store Store, log *slog.Logger) *GRPCServer {
	return &GRPCServer{store: store, log: log}
}

func (s *GRPCServer) GetAccount(ctx context.Context, req *accountv1.GetAccountRequest) (*accountv1.GetAccountResponse, error) {
	a, err := s.store.Get(ctx, req.GetNumber())
	if err != nil {
		return nil, s.toStatus(err)
	}
	return &accountv1.GetAccountResponse{Account: toProto(a)}, nil
}

func (s *GRPCServer) Debit(ctx context.Context, req *accountv1.DebitRequest) (*accountv1.DebitResponse, error) {
	a, err := s.mutate(ctx, Debit, req.GetNumber(), req.GetAmount(), req.GetReference())
	if err != nil {
		return nil, err
	}
	return &accountv1.DebitResponse{Account: toProto(a)}, nil
}

func (s *GRPCServer) Credit(ctx context.Context, req *accountv1.CreditRequest) (*accountv1.CreditResponse, error) {
	a, err := s.mutate(ctx, Credit, req.GetNumber(), req.GetAmount(), req.GetReference())
	if err != nil {
		return nil, err
	}
	return &accountv1.CreditResponse{Account: toProto(a)}, nil
}

func (s *GRPCServer) mutate(ctx context.Context, t MutationType, number, amount, reference string) (Account, error) {
	parsed, err := decimal.NewFromString(amount)
	if err != nil {
		return Account{}, status.Errorf(codes.InvalidArgument, "amount: %q is not a decimal number", amount)
	}
	req := MutationRequest{Amount: parsed, Reference: reference}
	if err := req.Validate(); err != nil {
		return Account{}, s.toStatus(err)
	}
	a, err := s.store.Mutate(ctx, number, t, req)
	if err != nil {
		return Account{}, s.toStatus(err)
	}
	s.log.Info("account mutated", "number", a.Number, "type", t, "amount", req.Amount, "reference", req.Reference)
	return a, nil
}

// toStatus maps domain errors to gRPC codes. Callers branch on the code, so the
// mapping is part of the contract (see account.proto):
//   - NotFound and FailedPrecondition are business answers from a healthy
//     service; clients must not retry them or count them against the breaker.
//   - Anything unexpected becomes Internal, with the detail only in our log.
func (s *GRPCServer) toStatus(err error) error {
	var v ValidationError
	switch {
	case errors.As(err, &v):
		return status.Error(codes.InvalidArgument, v.describe())
	case errors.Is(err, ErrNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, ErrInsufficientFunds):
		return status.Error(codes.FailedPrecondition, err.Error())
	default:
		s.log.Error("grpc request failed", "error", err)
		return status.Error(codes.Internal, "internal error")
	}
}

// describe renders "amount: must be ...; reference: must be ..." in a stable order.
func (v ValidationError) describe() string {
	var parts []string
	for _, field := range slices.Sorted(maps.Keys(v)) {
		parts = append(parts, fmt.Sprintf("%s: %s", field, v[field]))
	}
	return strings.Join(parts, "; ")
}

func toProto(a Account) *accountv1.Account {
	return &accountv1.Account{
		Number:    a.Number,
		OwnerName: a.OwnerName,
		Balance:   a.Balance.StringFixed(2),
		CreatedAt: timestamppb.New(a.CreatedAt),
	}
}
```

Hal-hal yang perlu diperhatikan pada kode tersebut:

- *`UnimplementedAccountServiceServer` di-_embed_ di dalam _struct_.* Bila kontrak kelak mendapat RPC baru, server lama tetap terkompilasi dan menjawab RPC baru tersebut dengan kode `Unimplemented`, sampai implementasinya ditulis.
- *Pemetaan _error_ ke kode status di `toStatus`.* Tabel berikut menjadi acuan bagi pemanggil.

#table(
  columns: (auto, 1fr, 1fr),
  [Kode gRPC], [Penyebab], [Padanan REST di Lab 2],
  [`InvalidArgument`], [Nominal bukan angka desimal, nominal nol atau negatif, `reference` kosong], [HTTP 400],
  [`NotFound`], [Nomor rekening tidak terdaftar], [HTTP 404],
  [`FailedPrecondition`], [Saldo tidak cukup untuk _debit_], [HTTP 422],
  [`Internal`], [_Error_ lain, misalnya database bermasalah. Rinciannya hanya dicatat di _log_ `account`], [HTTP 500],
)

`NotFound`, `FailedPrecondition` dan `InvalidArgument` merupakan jawaban bisnis dari _service_ yang sehat. Di sisi `transfer`, kode-kode tersebut tidak di-_retry_ dan tidak dihitung sebagai kegagalan oleh _circuit breaker_. Kode `Internal` hanya membawa teks `internal error` agar detail internal (nama tabel, alamat database) tidak bocor ke pemanggil.

Fungsi `MutationRequest.Validate` dan `Store.Mutate` dari Lab 2 digunakan kembali tanpa perubahan. _Struct_ `MutationRequest` di `account.go` kini hanya diisi dari gRPC, sehingga _tag_ JSON-nya dihapus:

```go
// MutationRequest is a debit or credit, received over gRPC. Reference ties the
// mutation to the business transaction that caused it, e.g. a transfer ID.
type MutationRequest struct {
	Amount    decimal.Decimal
	Reference string
}
```

=== _Interceptor_ _Logging_

_Interceptor_ di gRPC berperan seperti _middleware_ di `net/http`: fungsi yang membungkus setiap pemanggilan RPC sebelum dan sesudah _handler_ berjalan. _Unary interceptor_ berlaku untuk RPC dengan satu _request_ dan satu _response_, yaitu jenis RPC yang digunakan di seluruh studi kasus ini.

_Interceptor_ pertama mencatat setiap RPC beserta kode status dan durasinya, padanan _access log_ di server HTTP. Buat file `account/internal/interceptor/logging.go`:

```go
// Package interceptor holds cross-cutting gRPC server middleware.
package interceptor

import (
	"context"
	"log/slog"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Logging logs every unary call with its status code and duration: the gRPC
// equivalent of an HTTP access log. Business rejections (NotFound,
// FailedPrecondition, InvalidArgument) are logged at INFO because they are
// normal answers; everything else that failed is a WARN worth looking at.
func Logging(log *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		code := status.Code(err)
		level := slog.LevelInfo
		switch code {
		case codes.OK, codes.NotFound, codes.FailedPrecondition, codes.InvalidArgument:
		default:
			level = slog.LevelWarn
		}
		log.Log(ctx, level, "grpc request", "method", info.FullMethod, "code", code.String(),
			"duration_ms", time.Since(start).Milliseconds())
		return resp, err
	}
}
```

Parameter `info.FullMethod` berisi nama lengkap RPC, misalnya `/account.v1.AccountService/Debit`. Parameter `handler` adalah langkah berikutnya dalam rantai: _interceptor_ lain atau implementasi `GRPCServer`.

=== _Fault Injection_ untuk gRPC

Di Lab 3, `PUT /admin/fault` memperlambat atau menggagalkan REST API `account`. Agar latihan _resiliency_ tetap berjalan setelah `transfer` beralih ke gRPC, _injector_ yang sama perlu bekerja juga untuk gRPC. Satu konfigurasi berlaku untuk kedua _transport_, sehingga `make fault-slow` dan `make fault-error` tidak perlu diubah.

Di `account/internal/fault/fault.go`, logika jeda dan _error_ dipindahkan dari `Wrap` ke fungsi bersama `inject`. Fungsi `Wrap` dan _interceptor_ baru sama-sama memanggil fungsi tersebut. Tambahkan _import_ berikut:

```go
import (
	"context"
	// ... import yang sudah ada ...

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)
```

Ganti fungsi `Wrap`, lalu tambahkan `UnaryServerInterceptor` dan `inject` di bawahnya:

```go
// Wrap applies the current fault configuration to every request of next.
func (i *Injector) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if i.inject(r.Context()) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"injected fault"}` + "\n"))
			return
		}
		if r.Context().Err() != nil { // caller gave up during the delay; do not process
			return
		}
		next.ServeHTTP(w, r)
	})
}

// UnaryServerInterceptor is the gRPC counterpart of Wrap, driven by the same
// configuration: one PUT /admin/fault degrades REST and gRPC together. The
// injected error is Unavailable, the gRPC equivalent of HTTP 503 ("refused
// before processing"), which the transfer client is allowed to retry.
// skip names full methods that must stay fast, e.g. the health service.
func (i *Injector) UnaryServerInterceptor(skip func(fullMethod string) bool) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if skip(info.FullMethod) {
			return handler(ctx, req)
		}
		if i.inject(ctx) {
			return nil, status.Error(codes.Unavailable, "injected fault")
		}
		if err := ctx.Err(); err != nil { // caller gave up during the delay; do not process
			return nil, status.FromContextError(err).Err()
		}
		return handler(ctx, req)
	}
}

// inject sleeps for the configured delay (or until ctx ends) and reports whether
// this request must be answered with an injected error.
func (i *Injector) inject(ctx context.Context) bool {
	cfg := i.cfg.Load()
	if cfg.DelayMS > 0 {
		select {
		case <-time.After(time.Duration(cfg.DelayMS) * time.Millisecond):
		case <-ctx.Done():
			return false
		}
	}
	return cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate
}
```

Ubah juga komentar _field_ `ErrorRate` pada _struct_ `Config` menjadi "answered with 503 (HTTP) or Unavailable (gRPC) without being processed".

Dua perilaku pada _interceptor_ tersebut menentukan hasil latihan di bagian Verifikasi:

- Kegagalan yang disuntikkan dijawab `codes.Unavailable` tanpa menjalankan _handler_. Kode tersebut setara dengan HTTP 503 di Lab 3: permintaan ditolak sebelum diproses, sehingga `transfer` boleh mengulanginya.
- Bila pemanggil menyerah selama jeda berlangsung (misalnya karena _timeout_ 2 detik di `transfer`), _handler_ tidak dijalankan dan _interceptor_ mengembalikan kode dari _context_ yang berakhir, yaitu `Canceled` atau `DeadlineExceeded`.

=== Server gRPC di `main.go` `account`

Tambahkan `GRPC_ADDR` di `account/config.go`. Seperti variabel lain, `GRPC_ADDR` wajib diisi: bila kosong, _service_ berhenti saat _startup_ dengan pesan yang menyebut nama variabelnya.

```go
type Config struct {
	HTTPAddr    string
	GRPCAddr    string
	DatabaseURL string
}

// di dalam LoadConfig
	cfg := Config{
		HTTPAddr:    get("HTTP_ADDR"),
		GRPCAddr:    get("GRPC_ADDR"),
		DatabaseURL: get("DATABASE_URL"),
	}
```

Tambahkan nilainya di target `run` pada `account/Makefile`:

```make
run:
	HTTP_ADDR=:28081 \
	GRPC_ADDR=:29091 \
	DATABASE_URL=postgres://account:account123@localhost:15432/account \
	go run .
```

Di `account/main.go`, tambahkan _import_ berikut:

```go
	"fmt"
	"net"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/interceptor"
	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
```

Sisipkan blok berikut setelah deklarasi `srv := &http.Server{...}` dan sebelum _goroutine_ yang menjalankan server HTTP:

```go
	// gRPC: the internal API (GetAccount, Debit, Credit) for other services.
	// Interceptors run in the order given: logging sees the code that the fault
	// injector produced, so injected failures show up in the log like real ones.
	// Health and reflection are excluded from faults, like the HTTP probes.
	grpcSrv := grpc.NewServer(grpc.ChainUnaryInterceptor(
		interceptor.Logging(log),
		faults.UnaryServerInterceptor(func(method string) bool {
			return !strings.HasPrefix(method, "/"+accountv1.AccountService_ServiceDesc.ServiceName+"/")
		}),
	))
	accountv1.RegisterAccountServiceServer(grpcSrv, account.NewGRPCServer(store, log))
	// Standard health protocol (grpc.health.v1): Kubernetes gRPC probes and
	// grpc-health-probe understand it without custom code.
	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(grpcSrv, healthSrv)
	healthSrv.SetServingStatus(accountv1.AccountService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	// Reflection lets grpcurl / Postman list services and methods without the
	// .proto file. Handy in the lab; many teams switch it off in production.
	reflection.Register(grpcSrv)

	lis, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		return fmt.Errorf("listen on GRPC_ADDR %s: %w", cfg.GRPCAddr, err)
	}
```

Penjelasan blok tersebut:

- *`grpc.ChainUnaryInterceptor`* menjalankan _interceptor_ sesuai urutan argumennya. `Logging` berada di luar, sehingga _log_ mencatat kode yang dihasilkan _fault injector_. Kegagalan buatan pun tercatat seperti kegagalan sungguhan.
- *Fungsi `skip`* mengecualikan semua RPC di luar `account.v1.AccountService`, yaitu _health service_ dan _reflection_. Prinsipnya sama dengan Lab 3: _probe_ tetap cepat walaupun API sedang diganggu.
- *_Health service_* (`grpc.health.v1`) adalah protokol standar. _Probe_ gRPC di Kubernetes dan `grpc-health-probe` dapat memeriksanya tanpa kode tambahan.
- *_Reflection_* memungkinkan _tools_ seperti `grpcurl` atau Postman menampilkan daftar _service_ dan RPC tanpa file `.proto`. Fitur ini memudahkan di lab, dan banyak tim mematikannya di _production_.

Server HTTP dan server gRPC kini berjalan bersamaan, masing-masing di _goroutine_ sendiri. Ganti bagian akhir fungsi `run`, mulai dari `errCh`, dengan kode berikut:

```go
	errCh := make(chan error, 2)
	go func() {
		log.Info("account service listening", "protocol", "http", "addr", cfg.HTTPAddr)
		errCh <- srv.ListenAndServe()
	}()
	go func() {
		log.Info("account service listening", "protocol", "grpc", "addr", cfg.GRPCAddr)
		errCh <- grpcSrv.Serve(lis)
	}()

	select {
	case err := <-errCh:
		srv.Close()
		grpcSrv.Stop()
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		// NOT_SERVING first, so health checkers stop routing new calls here
		// while in-flight ones finish.
		healthSrv.Shutdown()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		grpcDone := make(chan struct{})
		go func() {
			grpcSrv.GracefulStop()
			close(grpcDone)
		}()
		httpErr := srv.Shutdown(shutdownCtx)
		select {
		case <-grpcDone:
		case <-shutdownCtx.Done():
			// Same 10 s budget as HTTP: calls still running now are cut off.
			grpcSrv.Stop()
		}
		if httpErr != nil && !errors.Is(httpErr, http.ErrServerClosed) {
			return httpErr
		}
		return nil
	}
```

Kapasitas `errCh` menjadi 2 karena ada dua server yang dapat berhenti. Bila salah satu server gagal, server lainnya ikut dihentikan, sehingga proses tidak berjalan setengah hidup. Saat _shutdown_, `healthSrv.Shutdown()` mengubah status _health_ menjadi `NOT_SERVING` lebih dahulu. Setelah itu `GracefulStop` menunggu RPC yang sedang berjalan selesai, dengan batas waktu 10 detik yang sama dengan server HTTP.

=== Penghapusan Endpoint REST _Debit_ dan _Credit_

Di `account/internal/account/http.go`, hapus dua rute berikut beserta fungsi `mutate` milik `Handler`:

```go
	mux.HandleFunc("POST /accounts/{number}/debit", h.mutate(Debit))
	mux.HandleFunc("POST /accounts/{number}/credit", h.mutate(Credit))
```

Tambahkan penjelasan di atas fungsi `Routes`, agar pembaca kode berikutnya tahu ke mana kedua endpoint tersebut pindah:

```go
// Routes uses the Go 1.22+ ServeMux patterns: method + path, with {wildcards}.
//
// This is the channel-facing API. Debit and credit are not here: since Lab 4
// other services mutate balances over gRPC only (see grpc.go), and no channel
// client should change a balance without going through a transfer.
```

Hapus juga _import_ yang tidak lagi digunakan bila kompilator memintanya. Di `http_test.go`, lima kasus uji _debit_ dan _credit_ diganti dengan satu kasus yang memastikan endpoint tersebut sudah tidak ada:

```go
		{"no debit over REST", "POST", "/accounts/1234567890/debit", `{"amount":"1","reference":"T-1"}`, 404, ""},
```

#note[Sejak _checkpoint_ `lab-04`, perintah `curl` dari Lab 2 dan Lab 3 yang memanggil `/accounts/{number}/debit` atau `/credit` secara langsung tidak berlaku lagi. Saldo hanya berubah melalui `POST /transfers`.]

Setelah semua perubahan di `account` selesai, rapikan `go.mod` dan pastikan kode terkompilasi:

#perintah[```bash
cd account
go mod tidy
go build ./...
cd ..
```]

=== Pengujian Server gRPC dengan `bufconn`

Server gRPC dapat diuji melalui jalur yang sama dengan pemanggilan sungguhan, yaitu _encoding_ _protobuf_, HTTP/2 dan kode status, tanpa membuka port TCP. Paket `google.golang.org/grpc/test/bufconn` menyediakan _listener_ di memori. Server mendengarkan di _listener_ tersebut, dan _client_ terhubung dengannya melalui `WithContextDialer`.

Buat `account/internal/account/grpc_test.go`. Fungsi pembantunya sebagai berikut (`newFakeStore` sudah tersedia dari pengujian Lab 1):

```go
// newGRPCClient serves GRPCServer over an in-memory listener (bufconn): the test
// goes through real protobuf encoding and status codes without opening a port.
func newGRPCClient(t *testing.T, store Store) accountv1.AccountServiceClient {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	accountv1.RegisterAccountServiceServer(srv, NewGRPCServer(store, slog.New(slog.NewTextHandler(io.Discard, nil))))
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return accountv1.NewAccountServiceClient(conn)
}
```

Skema `passthrough:///` membuat gRPC meneruskan alamat `bufnet` apa adanya ke _dialer_, tanpa mencoba me-_resolve_ nama tersebut lewat DNS.

Uji `TestGRPCAccountService` di _checkpoint_ memeriksa dua hal:

- Jalur sukses: `GetAccount` mengembalikan saldo `"500000.00"`, `Debit` sebesar `"200000.50"` menghasilkan saldo `"299999.50"`, dan `Credit` sebesar `"0.50"` menghasilkan `"300000.00"`. Saldo selalu dikirim dengan dua angka desimal karena `toProto` memanggil `StringFixed(2)`.
- Penolakan: rekening tidak ada menghasilkan `NotFound`, saldo kurang menghasilkan `FailedPrecondition`, nominal `"1e"` atau nominal nol tanpa `reference` menghasilkan `InvalidArgument`. Saldo tidak berubah setelah semua penolakan tersebut.

Di `account/internal/fault/fault_test.go`, uji `TestUnaryServerInterceptor` memanggil fungsi _interceptor_ secara langsung dengan `grpc.UnaryServerInfo` buatan. Uji tersebut memastikan `error_rate` 1 menghasilkan `Unavailable` tanpa menjalankan _handler_, RPC _health_ tidak terkena gangguan, dan _deadline_ pemanggil yang lebih pendek dari jeda menghasilkan `DeadlineExceeded` tanpa menjalankan _handler_. Kode lengkap kedua uji tersedia di _checkpoint_ `lab-04`.

=== Dependensi dan Konfigurasi di _Service_ `transfer`

`transfer` juga mengimpor modul `proto`, sehingga membutuhkan direktif `replace` yang sama:

#perintah[```bash
cd transfer
go mod edit \
  -require=github.com/artivisi/training-microservices-2026-01/studi-kasus/proto@v0.0.0 \
  -replace=github.com/artivisi/training-microservices-2026-01/studi-kasus/proto=../proto
cd ..
```]

Di `transfer/config.go`, `ACCOUNT_SERVICE_URL` diganti dengan `ACCOUNT_GRPC_ADDR`. Nilainya berupa `host:port`, tanpa skema `http://`.

```go
type Config struct {
	HTTPAddr    string
	DatabaseURL string
	// AccountGRPCAddr is host:port of the account service's gRPC API.
	AccountGRPCAddr string
}

// di dalam LoadConfig
	cfg := Config{
		HTTPAddr:        get("HTTP_ADDR"),
		DatabaseURL:     get("DATABASE_URL"),
		AccountGRPCAddr: get("ACCOUNT_GRPC_ADDR"),
	}
```

Sesuaikan target `run` di `transfer/Makefile`:

```make
run:
	HTTP_ADDR=:28082 \
	DATABASE_URL=postgres://transfer:transfer123@localhost:15433/transfer \
	ACCOUNT_GRPC_ADDR=localhost:29091 \
	go run .
```

=== _Client_ gRPC dengan _Interceptor_ failsafe-go

File `transfer/internal/accountclient/client.go` ditulis ulang. Struktur luarnya tetap: _struct_ `Settings`, nilai `ProductionSettings`, metode `Debit`, `Credit`, `BreakerState` dan `ServeCircuitBreaker`. Bagian dalamnya berganti dari HTTP ke gRPC. Paket `transfer` (logika transfer) tidak berubah sama sekali, karena paket tersebut hanya mengenal _interface_ `AccountClient` dan _error_ domain seperti `ErrInsufficientFunds`.

failsafe-go menyediakan integrasi gRPC di paket `failsafegrpc`. Fungsi `failsafegrpc.NewUnaryClientInterceptor` menerima _policy_ yang sama dengan `failsafehttp.NewRoundTripper` di Lab 3 dan menghasilkan _unary client interceptor_. Ganti blok _import_ dengan:

```go
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/failsafe-go/failsafe-go"
	"github.com/failsafe-go/failsafe-go/circuitbreaker"
	"github.com/failsafe-go/failsafe-go/failsafegrpc"
	"github.com/failsafe-go/failsafe-go/retrypolicy"
	"github.com/failsafe-go/failsafe-go/timeout"
	"github.com/shopspring/decimal"
	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)
```

_Struct_ `Settings` dan `ProductionSettings` tetap seperti Lab 3. Ganti _struct_ `Client` dan fungsi `New`:

```go
type Client struct {
	conn    *grpc.ClientConn
	api     accountv1.AccountServiceClient
	breaker circuitbreaker.CircuitBreaker[any]
}

// New connects lazily: no network traffic until the first call, so the transfer
// service starts even while the account service is down. opts are extra dial
// options; tests pass an in-memory dialer.
func New(target string, s Settings, log *slog.Logger, opts ...grpc.DialOption) (*Client, error) {
	// R = any: the interceptor sees every RPC of the connection, whatever its
	// response type. The policies only look at the error.
	//
	// One breaker for the whole account service: debit and credit share the same
	// failure domain, so a dead account service stops both.
	breaker := circuitbreaker.NewBuilder[any]().
		HandleIf(countsAsFailure).
		WithFailureThresholdRatio(s.BreakerFailures, s.BreakerWindow).
		WithDelay(s.BreakerDelay).
		WithSuccessThreshold(s.BreakerSuccesses).
		OnStateChanged(func(e circuitbreaker.StateChangedEvent) {
			log.Warn("circuit breaker state changed", "target", "account",
				"from", e.OldState.String(), "to", e.NewState.String())
		}).
		Build()

	retry := retrypolicy.NewBuilder[any]().
		HandleIf(notProcessed).
		// Explicit even though notProcessed already ignores ErrOpen: retrying against
		// an open breaker only burns backoff time and fails anyway.
		AbortOnErrors(circuitbreaker.ErrOpen).
		WithMaxRetries(s.MaxRetries).
		WithBackoff(s.BackoffMin, s.BackoffMax).
		// Jitter spreads the retries of many concurrent transfers so they do not all
		// hit a recovering account service in the same millisecond.
		WithJitterFactor(0.25).
		// Hand the last status error back instead of wrapping it in an ExceededError,
		// so mapError sees the real gRPC code.
		ReturnLastFailure().
		OnRetry(func(e failsafe.ExecutionEvent[any]) {
			log.Warn("retrying account call", "next_attempt", e.Attempts(), "cause", e.LastError())
		}).
		Build()

	// Order matters: retry wraps the breaker, which wraps the timeout. Every attempt
	// gets its own time budget, and every attempt, timeouts included, is counted by
	// the breaker. Same shape as the REST client of Lab 3, now as an interceptor.
	resilience := failsafegrpc.NewUnaryClientInterceptor[any](retry, breaker, timeout.New[any](s.AttemptTimeout))

	opts = append([]grpc.DialOption{
		// Plaintext: fine on a laptop, not in production. Service-to-service calls
		// there go over TLS (or mTLS through a service mesh); Lab 7 adds tokens.
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(resilience),
		// After a failed connect, gRPC waits before reconnecting, growing up to
		// 120 s by default. Capped at 5 s so a restarted account service is used
		// again within seconds, which is what the breaker's half-open trials need.
		grpc.WithConnectParams(grpc.ConnectParams{
			Backoff:           backoff.Config{BaseDelay: time.Second, Multiplier: 1.6, Jitter: 0.2, MaxDelay: 5 * time.Second},
			MinConnectTimeout: 5 * time.Second,
		}),
	}, opts...)
	conn, err := grpc.NewClient(target, opts...)
	if err != nil {
		return nil, fmt.Errorf("account gRPC client for %s: %w", target, err)
	}
	return &Client{conn: conn, api: accountv1.NewAccountServiceClient(conn), breaker: breaker}, nil
}

func (c *Client) Close() error { return c.conn.Close() }
```

Perbedaan dengan versi REST di Lab 3:

- *Parameter tipe `[any]`.* Di Lab 3 _policy_ bertipe `[*http.Response]`. Satu _interceptor_ gRPC melayani semua RPC pada koneksi tersebut, dan setiap RPC memiliki tipe _response_ sendiri. Karena keputusan _policy_ hanya bergantung pada _error_, tipe `any` sudah cukup.
- *Urutan _policy_ tetap sama:* _retry_ membungkus _circuit breaker_, dan _circuit breaker_ membungkus _timeout_. Setiap percobaan mendapat jatah waktu 2 detik sendiri, dan setiap percobaan dihitung oleh _circuit breaker_.
- *`grpc.NewClient` tidak langsung membuka koneksi.* Koneksi baru dibuat saat RPC pertama. Dengan perilaku ini, `transfer` tetap dapat dijalankan walaupun `account` sedang mati.
- *`insecure.NewCredentials()`* berarti koneksi tanpa TLS. Pilihan ini hanya untuk laptop. Di _production_, komunikasi antar-_service_ menggunakan TLS atau mTLS (misalnya lewat _service mesh_).
- *_Reconnect backoff_ dibatasi 5 detik.* Setelah gagal tersambung, gRPC menunggu sebelum mencoba lagi, dan bawaannya dapat mencapai 120 detik. Batas 5 detik membuat `account` yang baru dijalankan ulang segera digunakan lagi, sehingga panggilan uji pada kondisi _half-open_ tidak terbuang.

Ganti `notProcessed` dan `countsAsFailure`:

```go
// notProcessed reports whether the call may be retried: only Unavailable, which
// means the server refused the call before running it (the fault injector does
// exactly that) or no connection could be made.
//
// DeadlineExceeded and our own attempt timeout are NOT retried: the account
// service may have applied the debit and only the answer was late. Debit is not
// idempotent yet, so a retry would debit twice. Lab 5 makes mutations idempotent
// by reference; only then are timeouts retried.
//
// Residual risk: gRPC also reports Unavailable when an established connection
// drops after the request was sent, so this is "almost provably" not processed.
// Lab 5's idempotent references close that gap as well.
func notProcessed(_ any, err error) bool {
	return status.Code(err) == codes.Unavailable
}

// countsAsFailure decides what the breaker counts against the account service:
// infrastructure codes and our own attempt timeout. Business codes (NotFound,
// FailedPrecondition, InvalidArgument) are a healthy service saying no and must
// not open the breaker.
func countsAsFailure(_ any, err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, timeout.ErrExceeded) {
		return true
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded, codes.Internal, codes.Unknown:
		return true
	}
	return false
}
```

Aturan _retry_ di Lab 3 menggunakan dua sinyal untuk "permintaan pasti belum diproses": kegagalan _dial_ dan HTTP 503. Di gRPC kedua sinyal tersebut sama-sama muncul sebagai `Unavailable`. Kode `DeadlineExceeded` dan _timeout_ milik failsafe-go tetap tidak di-_retry_ dengan alasan yang sama seperti di Lab 3: _debit_ mungkin sudah dijalankan di `account` dan hanya jawabannya yang terlambat, sedangkan _debit_ belum _idempotent_. Komentar di atas `notProcessed` juga mencatat satu celah: gRPC mengembalikan `Unavailable` pula ketika koneksi yang sudah terbentuk putus setelah _request_ terkirim. Celah tersebut ditutup di Lab 5, ketika mutasi saldo menjadi _idempotent_ berdasarkan `reference`.

Ringkasan perlakuan setiap kode status di sisi `transfer`:

#table(
  columns: (auto, 1fr, auto, auto),
  [Kode], [Arti], [Di-_retry_], [Dihitung _breaker_],
  [`NotFound`], [Rekening tidak ada], [Tidak], [Tidak],
  [`FailedPrecondition`], [Saldo tidak cukup], [Tidak], [Tidak],
  [`InvalidArgument`], [_Field_ tidak valid], [Tidak], [Tidak],
  [`Unavailable`], [Ditolak sebelum diproses (termasuk _fault injection_) atau koneksi gagal], [Ya], [Ya],
  [`DeadlineExceeded`, _timeout_ 2 detik], [Jawaban terlambat, _debit_ mungkin sudah terjadi], [Tidak], [Ya],
  [`Internal`, `Unknown`], [Kesalahan di server], [Tidak], [Ya],
)

Terakhir, ganti `Debit`, `Credit` dan fungsi `mutate` versi REST dengan pemanggilan gRPC dan fungsi `mapError`:

```go
func (c *Client) Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	_, err := c.api.Debit(ctx, &accountv1.DebitRequest{Number: number, Amount: amount.String(), Reference: reference})
	return mapError("debit", number, err)
}

func (c *Client) Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	_, err := c.api.Credit(ctx, &accountv1.CreditRequest{Number: number, Amount: amount.String(), Reference: reference})
	return mapError("credit", number, err)
}

// mapError turns the account service's gRPC codes into the transfer domain's
// errors, so the transfer package never imports gRPC.
func mapError(kind, number string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, circuitbreaker.ErrOpen) {
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountUnavailable)
	}
	switch status.Code(err) {
	case codes.NotFound:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountNotFound)
	case codes.FailedPrecondition:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrInsufficientFunds)
	}
	return fmt.Errorf("%s %s: %w", kind, number, err)
}
```

Kode REST di Lab 3 harus menyusun URL, mengodekan JSON, membaca _body_ dan menutupnya. Dengan gRPC, pemanggilan cukup satu baris `c.api.Debit(...)`. _Policy_ _resiliency_ tidak tampak di metode `Debit`, karena _interceptor_ sudah membungkus setiap RPC. Fungsi `mapError` menerjemahkan kode gRPC menjadi _error_ domain, sehingga paket `transfer` tidak perlu mengimpor gRPC dan _handler_ HTTP `transfer` tetap memetakan _error_ tersebut ke HTTP 422, 503 atau 502 seperti sebelumnya.

=== `main.go` di `transfer`

`accountclient.New` kini dapat mengembalikan _error_ (misalnya alamat target tidak valid), dan koneksinya perlu ditutup saat _service_ berhenti. Ubah `transfer/main.go`:

```go
	accounts, err := accountclient.New(cfg.AccountGRPCAddr, accountclient.ProductionSettings, log)
	if err != nil {
		return err
	}
	defer accounts.Close()
```

Sesuaikan juga _log_ saat _startup_:

```go
		log.Info("transfer service listening", "addr", cfg.HTTPAddr, "account_grpc", cfg.AccountGRPCAddr)
```

Rapikan dependensi dan pastikan kode terkompilasi:

#perintah[```bash
cd transfer
go mod tidy
go build ./...
cd ..
```]

=== Pengujian _Client_ dengan `bufconn`

Uji _client_ di Lab 3 menggunakan `httptest.Server`. Padanannya untuk gRPC adalah server gRPC palsu yang berjalan di `bufconn`. Server palsu ini mengimplementasikan `AccountServiceServer` dan menjawab setiap panggilan sesuai fungsi `answer` yang ditentukan oleh masing-masing uji.

```go
// fakeAccountService answers every Debit/Credit with answer(n), n = 1 for the
// first call; answer returns the gRPC error (nil = success).
type fakeAccountService struct {
	accountv1.UnimplementedAccountServiceServer
	calls  atomic.Int64
	answer func(ctx context.Context, n int64) error
	last   atomic.Pointer[accountv1.DebitRequest]
}

// serve runs the fake on an in-memory listener (bufconn) and returns a client
// wired to it with s and log. No TCP port is opened.
func serve(t *testing.T, answer func(ctx context.Context, n int64) error, s Settings, log *slog.Logger) (*Client, *fakeAccountService, *bufconn.Listener) {
	t.Helper()
	fake := &fakeAccountService{answer: answer}
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	accountv1.RegisterAccountServiceServer(srv, fake)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	c, err := New("passthrough:///bufnet", s, log,
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c, fake, lis
}
```

Parameter variadik `opts` pada `New` memungkinkan uji memasukkan _dialer_ `bufconn`, sementara `main.go` tidak mengirim opsi tambahan. Nilai `testSettings` mempertahankan bentuk _policy_ di `ProductionSettings` (3 _retry_, ambang 5 dari 10, 3 keberhasilan untuk menutup) dengan durasi pendek: _timeout_ 100 ms dan _backoff_ beberapa milidetik.

Daftar uji di _checkpoint_ `lab-04`:

#table(
  columns: (auto, 1fr),
  [Uji], [Yang dipastikan],
  [`TestCodeMapping`], [`NotFound` dan `FailedPrecondition` menjadi `ErrAccountNotFound` dan `ErrInsufficientFunds`. Nominal `10.50` terkirim sebagai `"10.5"`.],
  [`TestInternalIsNotRetried`], [`Internal` hanya dipanggil sekali.],
  [`TestRetryOnUnavailableSucceeds`], [Dua kali `Unavailable` lalu OK: transfer berhasil setelah 3 panggilan.],
  [`TestRetryGivesUpAfterMaxRetries`], [`Unavailable` terus-menerus: 4 panggilan (1 percobaan + 3 _retry_), _error_ terakhir dikembalikan apa adanya.],
  [`TestNoRetryOnTimeout`], [Server lambat: hanya 1 panggilan, selesai dalam waktu sekitar _timeout_ percobaan.],
  [`TestNoRetryOnDeadlineExceeded`], [`DeadlineExceeded` dari server tidak di-_retry_.],
  [`TestRetryOnConnectionRefused`], [_Listener_ ditutup: 3 kali _retry_ tercatat di _log_, server tidak menerima panggilan, dan 4 kegagalan belum membuka _breaker_.],
  [`TestBreakerOpensAndRejectsFast`], [Setelah 5 kali `Internal`, _breaker_ terbuka. Panggilan berikutnya ditolak seketika dengan `ErrAccountUnavailable` tanpa mencapai server, dan `/debug/circuit-breaker` menampilkan `{"account":"open"}`.],
  [`TestBusinessRejectionsDoNotOpenBreaker`], [Sepuluh kali `FailedPrecondition` tidak membuka _breaker_.],
  [`TestBreakerHalfOpenCloses`], [Setelah jeda berlalu, _breaker_ masih _half-open_ sesudah satu panggilan uji sukses dan baru tertutup sesudah tiga panggilan uji sukses.],
)

Uji terpenting bagi keamanan uang memastikan _timeout_ tidak di-_retry_:

```go
func TestNoRetryOnTimeout(t *testing.T) {
	c, fake := newTestClient(t, func(ctx context.Context, _ int64) error {
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
		}
		return nil
	})
	start := time.Now()
	if err := debit(c); err == nil {
		t.Fatal("err = nil, want timeout")
	}
	if got := fake.calls.Load(); got != 1 {
		t.Fatalf("calls = %d, want 1: a timed-out debit may have been applied", got)
	}
	if elapsed := time.Since(start); elapsed > 250*time.Millisecond {
		t.Fatalf("took %s, want about the attempt timeout", elapsed)
	}
}
```

Salin _file_ uji lengkap dari _checkpoint_ bila tidak ingin menulisnya sendiri:

#perintah[```bash
git show lab-04:studi-kasus/transfer/internal/accountclient/client_test.go \
  > transfer/internal/accountclient/client_test.go
git show lab-04:studi-kasus/account/internal/account/grpc_test.go \
  > account/internal/account/grpc_test.go
```]

Jalankan seluruh uji dari folder `studi-kasus`:

#perintah[```bash
make test
```]

Target tersebut menjalankan `go vet` pada modul `proto`, lalu `go vet` dan `go test` pada `account` dan `transfer`. Semua paket harus berstatus `ok`.

== Verifikasi

Jalankan kedua _service_ di dua terminal terpisah dari folder `studi-kasus`:

#perintah[```bash
make -C account run
```]

#perintah[```bash
make -C transfer run
```]

_Log_ `account` saat _startup_ menampilkan dua _listener_:

#perintah[```
level=INFO msg="account service listening" protocol=http addr=:28081
level=INFO msg="account service listening" protocol=grpc addr=:29091
```]

_Log_ `transfer` menampilkan alamat gRPC tujuan:

#perintah[```
level=INFO msg="transfer service listening" addr=:28082 account_grpc=localhost:29091
```]

=== Transfer Berhasil melalui gRPC

Buat dua rekening uji melalui REST API `account`. Bila rekening tersebut sudah ada dari lab sebelumnya, `account` menjawab HTTP 409 dan langkah ini boleh dilewati.

#perintah[```bash
curl -sS -X POST localhost:28081/accounts \
  -d '{"number":"1111111111","owner_name":"Budi","initial_balance":"1000000"}'
curl -sS -X POST localhost:28081/accounts \
  -d '{"number":"2222222222","owner_name":"Sari","initial_balance":"500000"}'
```]

Kirim transfer:

#perintah[```bash
curl -sS -i -X POST localhost:28082/transfers \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

Hasil yang diharapkan adalah `HTTP/1.1 201 Created` dengan `"status":"COMPLETED"`. _Log_ `account` mencatat dua RPC, yaitu _access log_ gRPC yang ditulis oleh _interceptor_ `Logging`:

#perintah[```
level=INFO msg="account mutated" number=1111111111 type=DEBIT amount=100000 reference=...
level=INFO msg="grpc request" method=/account.v1.AccountService/Debit code=OK duration_ms=3
level=INFO msg="account mutated" number=2222222222 type=CREDIT amount=100000 reference=...
level=INFO msg="grpc request" method=/account.v1.AccountService/Credit code=OK duration_ms=2
```]

Nilai `duration_ms` dan `reference` (ID transfer) berbeda di setiap laptop.

=== Penolakan Bisnis

Transfer dengan nominal melebihi saldo:

#perintah[```bash
curl -sS -i -X POST localhost:28082/transfers \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"999999999"}'
```]

Hasilnya `HTTP/1.1 422 Unprocessable Entity` dengan `"status":"FAILED"` dan `failure_reason` berisi `insufficient funds`. _Log_ `account` mencatat `code=FailedPrecondition` pada level `INFO`, dan `transfer` tidak mencatat `retrying account call`. Penolakan bisnis tidak di-_retry_ dan tidak dihitung oleh _circuit breaker_:

#perintah[```bash
make breaker
# {"account":"closed"}
```]

=== Endpoint REST _Debit_ Sudah Tidak Ada

#perintah[```bash
curl -sS -i -X POST localhost:28081/accounts/1111111111/debit \
  -d '{"amount":"1","reference":"X"}'
```]

Hasilnya `HTTP/1.1 404 Not Found`.

=== _Retry_ dan _Circuit Breaker_ dengan `fault-error`

Buat semua panggilan ke `account` gagal:

#perintah[```bash
make fault-error RATE=1
```]

Kirim transfer pertama (perintah `curl` yang sama dengan transfer berhasil). _Log_ `transfer` mencatat tiga kali `retrying account call` dengan `cause` berisi `code = Unavailable desc = injected fault`. Di _log_ `account` tercatat empat baris `grpc request method=/account.v1.AccountService/Debit code=Unavailable` pada level `WARN`. Jawaban HTTP-nya `502 Bad Gateway` dengan `"status":"FAILED"` dan `failure_reason` seperti berikut:

#perintah[```
debit failed: debit 1111111111: rpc error: code = Unavailable desc = injected fault
```]

Keempat percobaan tersebut dihitung sebagai empat kegagalan oleh _circuit breaker_. Kirim transfer kedua. Percobaan pertamanya menjadi kegagalan kelima, dan _log_ `transfer` mencatat:

#perintah[```
level=WARN msg="circuit breaker state changed" target=account from=closed to=open
```]

Sejak saat itu, transfer berikutnya dijawab seketika dengan `503 Service Unavailable`, `failure_reason` berisi `account service unavailable`, dan tidak ada baris `grpc request` baru di _log_ `account`.

#perintah[```bash
make breaker
# {"account":"open"}
```]

=== Pemulihan melalui _Half-Open_

Hapus gangguan, lalu tunggu lebih dari 10 detik (jeda _circuit breaker_):

#perintah[```bash
make fault-clear
```]

Kirim dua transfer. Setiap transfer terdiri dari dua RPC (_debit_ dan _credit_), sehingga dua transfer menghasilkan empat panggilan sukses, lebih dari tiga panggilan uji yang dibutuhkan untuk menutup _circuit breaker_. _Log_ `transfer` mencatat perpindahan `from=open to=half-open` lalu `from=half-open to=closed`, dan `make breaker` kembali menampilkan `{"account":"closed"}`.

=== _Timeout_ Tidak Di-_retry_ dengan `fault-slow`

#perintah[```bash
make fault-slow
time curl -sS -X POST localhost:28082/transfers \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

Transfer gagal setelah sekitar 2,0 detik, yaitu batas _timeout_ satu percobaan, dengan `failure_reason` berikut:

#perintah[```
debit failed: debit 1111111111: timeout exceeded
```]

_Log_ `transfer` tidak memuat `retrying account call`. Di _log_ `account` tercatat:

#perintah[```
level=WARN msg="grpc request" method=/account.v1.AccountService/Debit code=Canceled duration_ms=2000
```]

Kode `Canceled` muncul karena `transfer` membatalkan RPC setelah 2 detik. _Fault injector_ di `account` melihat _context_ yang sudah berakhir, sehingga _handler_ tidak dijalankan dan saldo tidak berubah. Ulangi transfer hingga lima kali: _circuit breaker_ terbuka, dan transfer berikutnya langsung dijawab 503. Kembalikan `account` ke kondisi normal sebelum melanjutkan:

#perintah[```bash
make fault-clear
```]

=== `account` Mati

Hentikan `account` dengan Ctrl+C, lalu kirim satu transfer. `transfer` mencoba empat kali (1 percobaan + 3 _retry_), karena koneksi yang ditolak juga dilaporkan sebagai `Unavailable`. Jawabannya 502 dengan `failure_reason` yang memuat teks _error_ gRPC lengkap, misalnya `... dial tcp 127.0.0.1:29091: connect: connection refused`.

#note[`failure_reason` saat ini memuat teks _error_ gRPC apa adanya, termasuk alamat internal `account`. Informasi tersebut tidak layak diterima aplikasi _channel_. Lab 7 mengganti `failure_reason` menjadi pesan umum, dan rinciannya hanya disimpan di _log_.]

Jalankan `account` kembali dengan `make -C account run`. Setelah _circuit breaker_ (bila sempat terbuka) melewati jeda 10 detik dan koneksi gRPC tersambung ulang, transfer kembali berhasil.

== Masalah Umum

*`protoc-gen-go: program not found or is not executable`.* _Plugin_ belum terpasang atau folder `$(go env GOPATH)/bin` tidak ada di `PATH`. Target `generate` di `proto/Makefile` sudah menambahkan folder tersebut ke `PATH`. Bila `protoc` dijalankan langsung tanpa `make`, jalankan `export PATH="$PATH:$(go env GOPATH)/bin"` lebih dahulu. Bila _plugin_ memang belum ada, pasang dengan `go install` seperti di bagian Titik Awal.

*`missing required environment variables: GRPC_ADDR` atau `ACCOUNT_GRPC_ADDR`.* _Service_ dijalankan dengan perintah lama atau _environment variable_ dari Lab 3. Jalankan melalui `make -C account run` dan `make -C transfer run`, yang sudah mengisi variabel baru. `ACCOUNT_SERVICE_URL` tidak dibaca lagi oleh `transfer`.

*`listen on GRPC_ADDR :29091: bind: address already in use`.* Proses `account` lain masih berjalan, biasanya di terminal lain. Hentikan proses tersebut terlebih dahulu.

*`cannot find module providing package .../studi-kasus/proto/gen/account/v1` atau `go mod tidy` mencoba mengunduh modul `proto` dari GitHub.* Direktif `replace` belum ada di `go.mod` milik `account` atau `transfer`, atau `./proto` belum terdaftar di `go.work`. Periksa kembali langkah dependensi di kedua _service_.

*Transfer masih gagal beberapa detik setelah `account` dijalankan ulang.* Ada dua penyebab yang dapat terjadi bersamaan. Pertama, _circuit breaker_ yang sempat terbuka baru masuk _half-open_ setelah 10 detik. Kedua, gRPC menunggu sebelum mencoba tersambung kembali, dengan jeda maksimal 5 detik sesuai `WithConnectParams`. Tunggu beberapa detik, lalu kirim transfer lagi.

*`curl` ke `/accounts/{number}/debit` menghasilkan 404.* Perilaku ini memang diharapkan. Sejak lab ini, perubahan saldo hanya melalui gRPC, dan dari sisi pengguna hanya melalui `POST /transfers`.

*`git diff lab-04` menampilkan perbedaan di baris versi `protoc` pada file hasil _generate_.* Versi `protoc` di laptop berbeda dari versi yang digunakan saat _checkpoint_ dibuat. Perbedaan tersebut hanya pada komentar dan tidak memengaruhi kode.

*Tidak ada `grpcurl` untuk mencoba RPC secara langsung.* Panduan persiapan tidak menyertakan `grpcurl`. Seluruh verifikasi di atas berjalan melalui `transfer` dan _log_ `account`. _Health service_ dan _reflection_ dapat dicoba dengan program Go kecil (lihat Eksplorasi Mandiri), atau dengan `grpcurl` maupun Postman bila tersedia.

== Eksplorasi Mandiri

+ *Program pemeriksa _health_.* Tulis program Go kecil di dalam modul `account`, misalnya `account/cmd/grpchealth/main.go`, yang tersambung ke `localhost:29091` dengan `grpc.NewClient` dan `insecure.NewCredentials()`, lalu memanggil `grpc_health_v1.NewHealthClient(conn).Check` dengan `Service: "account.v1.AccountService"`. Jalankan dengan `go run ./cmd/grpchealth` dari folder `account`. Status yang diharapkan adalah `SERVING`. Hentikan `account` dengan Ctrl+C sambil menjalankan program tersebut berulang-ulang, lalu amati kapan statusnya berubah atau koneksinya ditolak. Pastikan juga bahwa `make fault-error RATE=1` tidak memengaruhi hasil pemeriksaan _health_.
+ *Evolusi kontrak.* Tambahkan _field_ `string currency = 5;` pada _message_ `Account`, jalankan `make proto`, lalu isi _field_ tersebut di `toProto`. Jalankan `transfer` yang belum di-_build_ ulang terhadap `account` yang baru. Jelaskan mengapa `transfer` tetap berjalan, lalu coba hal sebaliknya: apa yang terjadi bila nomor _field_ `balance` diubah dari `3` menjadi `6`?
+ *Urutan _interceptor_.* Tukar urutan `interceptor.Logging` dan `faults.UnaryServerInterceptor` di `grpc.ChainUnaryInterceptor`, lalu ulangi `make fault-error RATE=1` dan `make fault-slow`. Bandingkan baris `grpc request` di _log_ `account` sebelum dan sesudah penukaran, terutama nilai `code` dan `duration_ms`, dan jelaskan perbedaannya.
+ *_Breaker_ untuk kode `InvalidArgument`.* Tambahkan uji di `client_test.go` yang memastikan sepuluh kali `InvalidArgument` tidak membuka _circuit breaker_, mengikuti pola `TestBusinessRejectionsDoNotOpenBreaker`. Kemudian pertimbangkan: apakah `ResourceExhausted` (misalnya _rate limit_ di server) sebaiknya dihitung sebagai kegagalan, dan apakah boleh di-_retry_?

== Checkpoint

Kondisi kode di akhir lab ini tersedia di tag `lab-04`. Untuk membandingkan hasil kerja sendiri dengan _checkpoint_:

#perintah[```bash
git diff lab-04 -- studi-kasus
```]

Untuk melanjutkan ke Lab 5 dari _checkpoint_:

#perintah[```bash
git switch -c kerja-lab-05 lab-04
```]
