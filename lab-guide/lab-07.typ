#import "../_template/panduan.typ": note, perintah

= Lab 7: Mengamankan Service dengan OAuth2 dan JWT

== Tujuan

Setelah menyelesaikan lab ini, peserta mampu:

- menjelaskan peran _authorization server_, _resource server_, dan _client_ pada OAuth2 _client credentials grant_;
- memverifikasi JWT _access token_ di dalam service Go: tanda tangan dengan _public key_ dari JWKS, _issuer_, masa berlaku, dan _scope_;
- menulis _middleware_ REST yang menjawab 401 atau 403 sesuai jenis penolakan;
- menulis gRPC _unary server interceptor_ yang menjawab `Unauthenticated` atau `PermissionDenied`;
- membuat service `transfer` mengambil _token_ sendiri dari _authorization server_ dan mengirimkannya di setiap panggilan gRPC ke `account`;
- menyembunyikan detail error internal dari respons API tanpa kehilangan detail tersebut di log.

== Gambaran

Hingga Lab 6, siapa pun yang dapat menjangkau port 8082 bisa membuat transfer, dan siapa pun yang dapat menjangkau port 9091 bisa mendebit rekening. Lab ini menambahkan pemeriksaan identitas pemanggil di kedua pintu masuk tersebut.

Identitas pemanggil dibuktikan dengan _access token_ berformat JWT (_JSON Web Token_). _Token_ diterbitkan oleh Ory Hydra, sebuah _authorization server_ OAuth2. Karena pemanggilnya adalah aplikasi (bukan manusia yang _login_), alur yang digunakan adalah _client credentials grant_: aplikasi mengirim _client ID_ dan _secret_ miliknya ke Hydra, lalu Hydra mengembalikan _token_ yang berlaku selama satu jam.

```text
              (1) POST /oauth2/token                  (3) POST /oauth2/token
              client channel-app                      client transfer-service
   curl  ------------------------------>  Hydra  <------------------------------+
    |                                     :4444                                  |
    |                                       |                                    |
    |                       (2) JWKS: public key untuk memeriksa tanda tangan    |
    |                           +-----------+------------------+                 |
    |                           v                              v                 |
    |   Authorization:     +----------+   gRPC + metadata  +----------+          |
    +--------------------> | transfer | -----------------> | account  |          |
        Bearer <token>     |  :8082   |   authorization:   |  :9091   |          |
                           +----------+   Bearer <token>   +----------+          |
                                |                                                |
                                +------------------------------------------------+
```

Ada tiga peran dalam gambar di atas:

#table(
  columns: (auto, 1fr, 2fr),
  [Peran OAuth2], [Komponen], [Tugas di Lab 7],
  [_Authorization server_], [Hydra], [Menerbitkan dan menandatangani _token_; menerbitkan _public key_ di JWKS. Konfigurasinya sudah disediakan.],
  [_Resource server_], [`account` (gRPC), `transfer` (REST)], [Memeriksa _token_ di setiap permintaan: tanda tangan, _issuer_, masa berlaku, dan _scope_.],
  [_Client_], [`curl` sebagai aplikasi _channel_, `transfer` saat memanggil `account`], [Meminta _token_ ke Hydra dan mengirimkannya di _header_ `Authorization`.],
)

Service `transfer` memegang dua peran sekaligus: _resource server_ bagi aplikasi _channel_ dan _client_ bagi `account`.

Pemeriksaan _token_ berlangsung di dalam service tanpa bertanya ke Hydra untuk setiap permintaan. Hydra menandatangani _token_ dengan _private key_ RSA, sedangkan service memeriksa tanda tangan itu dengan _public key_ yang diunduh dari JWKS (_JSON Web Key Set_). Service cukup mengunduh JWKS sekali, lalu menyimpannya di memori. Akibatnya, setiap transfer tidak perlu menunggu jawaban Hydra.

_Scope_ membatasi apa yang boleh dilakukan pemegang _token_. Lab ini menggunakan empat _scope_:

#table(
  columns: (auto, auto, 1fr),
  [Service], [Operasi], [_Scope_ yang Diperlukan],
  [`account` gRPC], [`GetAccount`], [`account:read`],
  [`account` gRPC], [`Debit`, `Credit`], [`account:write`],
  [`transfer` REST], [`POST /transfers`], [`transfer:write`],
  [`transfer` REST], [`GET /transfers/{id}`], [`transfer:read`],
)

Beberapa _endpoint_ tetap terbuka tanpa _token_: `/healthz`, `/readyz`, `/debug/circuit-breaker`, gRPC _health_ dan _reflection_, `/admin/fault`, serta REST `account` (`/accounts`). _Probe_ dipanggil oleh Kubernetes dan _load balancer_ yang tidak membawa _token_. REST `account` dibiarkan terbuka agar langkah pembuatan rekening di lab tetap singkat; di _production_, REST `account` mendapat _middleware_ yang sama dengan REST `transfer`.

Hasil pemeriksaan dibedakan menjadi dua jenis penolakan:

#table(
  columns: (1fr, auto, auto),
  [Kondisi], [REST `transfer`], [gRPC `account`],
  [Tanpa _token_, atau _header_ bukan `Bearer`], [401], [`Unauthenticated`],
  [_Token_ rusak, kedaluwarsa, _issuer_ lain, tanda tangan tidak cocok], [401], [`Unauthenticated`],
  [_Token_ valid, tetapi _scope_ tidak mencukupi], [403], [`PermissionDenied`],
)

401 berarti "identitas pemanggil tidak dikenali", sedangkan 403 berarti "pemanggil dikenali, tetapi tidak berhak". Perbedaan ini penting bagi pemanggil: 401 diselesaikan dengan meminta _token_ baru, sedangkan 403 tidak akan selesai hanya dengan mengulang permintaan.

#note[
  *Pembagian kerja di lab ini.* Konfigurasi Hydra beserta pendaftaran _client_ sudah disediakan di `compose.yaml` dan `Makefile`. Peserta tidak mengonfigurasi Hydra. Yang ditulis peserta adalah sisi service: _interceptor_ gRPC di `account`, _middleware_ REST di `transfer`, dan pengiriman _token_ dari `transfer` ke `account`.
]

== Titik Awal

Lab ini dimulai dari kondisi akhir Lab 6. Peserta yang menyelesaikan Lab 6 dapat melanjutkan dari kode sendiri. Peserta yang tertinggal mengambil _checkpoint_ Lab 6 dan membuat _branch_ kerja:

#perintah[```bash
git switch -c lab-07-kerja lab-06
cd studi-kasus
```]

Semua perintah di bab ini dijalankan dari folder `studi-kasus`, kecuali disebutkan lain. Database dari Lab 6 tidak perlu di-_reset_: lab ini tidak mengubah skema.

Pastikan service lama sudah berhenti. Hentikan `account`, `transfer`, dan `notification` dengan Ctrl+C di terminal masing-masing.

== Langkah

=== Menjalankan Hydra

Konfigurasi Hydra tersedia di _checkpoint_ `lab-07`. Ambil dua _file_ infrastruktur dari _checkpoint_ tersebut tanpa mengubah kode service:

#perintah[```bash
git checkout lab-07 -- compose.yaml Makefile
```]

Perubahan di `compose.yaml` hanya menambah dua service. Bagian yang perlu dipahami:

```yaml
  hydra:
    image: oryd/hydra:v26.2.0
    command: ["serve", "all", "--dev"]
    environment:
      DSN: memory
      URLS_SELF_ISSUER: http://localhost:4444/
      STRATEGIES_ACCESS_TOKEN: jwt
      SECRETS_SYSTEM: lab-only-system-secret-change-me
    ports:
      - "4444:4444"
      - "4445:4445"
```

- `--dev` mengizinkan HTTP tanpa TLS. Opsi ini hanya untuk laptop.
- `DSN: memory` menyimpan seluruh data Hydra di memori. Setelah Hydra di-_restart_, _client_ dan _signing key_ hilang. Sifat ini dimanfaatkan di bagian Eksplorasi Mandiri untuk mensimulasikan rotasi _key_.
- `URLS_SELF_ISSUER` menjadi isi _claim_ `iss` di setiap _token_. Perhatikan garis miring di akhir alamat.
- `STRATEGIES_ACCESS_TOKEN: jwt` membuat Hydra menerbitkan JWT. Tanpa opsi ini, Hydra menerbitkan _opaque token_ yang hanya bisa diperiksa dengan bertanya ke Hydra.
- Port 4444 adalah _public endpoint_ (_token_ dan JWKS). Port 4445 adalah _admin endpoint_ untuk mengelola _client_ dan tidak boleh dibuka ke luar di _production_.

Service kedua, `hydra-init`, berjalan sekali untuk mendaftarkan dua _client_ dengan ID dan _secret_ tetap:

#table(
  columns: (auto, auto, auto, 1fr),
  [_Client ID_], [_Secret_], [_Scope_ yang Boleh Diminta], [Digunakan oleh],
  [`transfer-service`], [`transfer-service-secret`], [`account:read`, `account:write`], [`transfer` saat memanggil gRPC `account`],
  [`channel-app`], [`channel-app-secret`], [`transfer:read`, `transfer:write`], [Aplikasi _channel_; di lab ini diperankan oleh `curl`],
)

`Makefile` mendapat dua tambahan: `infra-up` sekarang juga menjalankan `hydra-init`, dan target baru `token` meminta _token_ `channel-app` ke Hydra. Jalankan infrastruktur:

#perintah[```bash
make infra-up
```]

Uji bahwa Hydra sudah menerbitkan _token_:

#perintah[```bash
TOKEN=$(make -s token)
echo "$TOKEN"
```]

Keluarannya berupa satu baris panjang yang terdiri atas tiga bagian dipisah titik (`header.payload.signature`). Bagian tengah berisi _claim_ dalam JSON berenkode base64url. Isinya dapat dibaca dengan:

#perintah[```bash
cut -d. -f2 <<<"$TOKEN" | base64 -d
```]

Perintah `base64` dapat menampilkan error soal _padding_ di akhir keluaran; JSON-nya tetap terbaca. _Claim_ yang diperiksa oleh service di lab ini:

#table(
  columns: (auto, 1fr),
  [_Claim_], [Isi],
  [`iss`], [Penerbit _token_: `http://localhost:4444/`],
  [`exp`], [Waktu kedaluwarsa (detik sejak 1 Januari 1970), satu jam setelah diterbitkan],
  [`client_id`], [_Client_ yang meminta _token_, misalnya `channel-app`],
  [`scp`], [_Scope_ yang diberikan, dalam bentuk _array_ JSON],
)

#note[
  *Format _scope_ berbeda antar _authorization server_.* Hydra menaruh _scope_ di _claim_ `scp` berupa _array_. Keycloak menaruhnya di _claim_ `scope` berupa satu _string_ yang dipisah spasi. Kode di lab ini khusus untuk format Hydra. Saat pindah ke _authorization server_ lain, bagian yang berubah hanya _struct_ `Claims`.
]

Hydra baru membuat _signing key_ untuk _access token_ saat menerima permintaan _token_ pertama. Perintah `make -s token` di atas sekaligus memastikan _key_ tersebut sudah ada.

=== Menambahkan _Dependency_

Tiga _library_ baru digunakan:

- `github.com/golang-jwt/jwt/v5`: mengurai JWT, memeriksa tanda tangan dan _claim_ standar;
- `github.com/MicahParks/keyfunc/v3`: mengunduh JWKS, menyimpannya di memori, dan mengunduh ulang saat menemukan _key ID_ (`kid`) yang belum dikenal;
- `golang.org/x/time/rate`: membatasi frekuensi unduh ulang JWKS.

`transfer` juga membutuhkan `golang.org/x/oauth2` untuk meminta _token_ ke Hydra.

#perintah[```bash
(cd account && go get github.com/golang-jwt/jwt/v5@v5.3.1 \
  github.com/MicahParks/keyfunc/v3@v3.8.2 golang.org/x/time@v0.15.0)
(cd transfer && go get github.com/golang-jwt/jwt/v5@v5.3.1 \
  github.com/MicahParks/keyfunc/v3@v3.8.2 golang.org/x/time@v0.15.0 \
  golang.org/x/oauth2@v0.37.0)
```]

Setelah semua kode di bab ini selesai ditulis, `go mod tidy` di setiap modul merapikan `go.mod`.

=== Konfigurasi OAuth2 di `account`

`account` membutuhkan dua nilai: _issuer_ yang diharapkan dan alamat JWKS. Sesuai aturan studi kasus, keduanya wajib diisi dan tidak punya nilai bawaan. Tambahkan dua _field_ ke `Config` di `account/config.go`:

```go
type Config struct {
	HTTPAddr    string
	GRPCAddr    string
	DatabaseURL string
	// OAuthIssuer must equal the "iss" claim of the tokens, character for
	// character (Hydra: http://localhost:4444/, trailing slash included).
	OAuthIssuer string
	// OAuthJWKSURL is where the authorization server publishes its public keys.
	OAuthJWKSURL string
}
```

Lalu isi kedua _field_ di `LoadConfig`, di dalam _literal_ `cfg := Config{...}`:

```go
		OAuthIssuer:  get("OAUTH_ISSUER"),
		OAuthJWKSURL: get("OAUTH_JWKS_URL"),
```

Fungsi `get` yang sudah ada sejak Lab 1 mencatat variabel yang kosong, sehingga `account` berhenti saat _startup_ bila salah satu variabel ini tidak diisi.

Tambahkan nilainya untuk laptop di target `run` pada `account/Makefile`, sebelum `go run .`:

```makefile
	OAUTH_ISSUER=http://localhost:4444/ \
	OAUTH_JWKS_URL=http://localhost:4444/.well-known/jwks.json \
```

=== Memeriksa JWT dengan `Verifier`

Pemeriksaan _token_ dipisahkan dari _transport_. Paket baru `account/internal/auth` berisi `Verifier` yang hanya tahu soal JWT, sedangkan _interceptor_ gRPC di langkah berikutnya hanya tahu soal _metadata_ gRPC. Pemisahan ini membuat `Verifier` yang sama dapat digunakan ulang di _middleware_ REST `transfer`.

Hal-hal yang diperiksa `Verifier`, beserta alasannya:

- *Algoritma tanda tangan dikunci ke RS256.* JWT membawa nama algoritmanya di _header_. Bila service menerima algoritma apa pun yang tertulis di _header_, penyerang dapat mengirim _token_ dengan `alg: none` (tanpa tanda tangan) atau menandatangani dengan HS256 menggunakan _public key_ sebagai _secret_.
- *_Issuer_ harus sama persis*, termasuk garis miring di akhir. _Token_ dari _authorization server_ lain, atau dari _environment_ lain, ditolak.
- *`exp` wajib ada.* _Token_ tanpa `exp` berlaku selamanya.
- *Toleransi jam 30 detik* (_leeway_) untuk selisih jam antar server.
- *_Audience_ (`aud`) tidak diperiksa* di lab ini, karena _token_ _client credentials_ dari Hydra tidak membawa `aud` kecuali diminta. Di _production_, setiap _resource server_ didaftarkan sebagai _audience_ tersendiri dan `aud` diperiksa, sehingga _token_ untuk satu service tidak dapat digunakan di service lain.

JWKS diunduh oleh `keyfunc` saat _startup_ dan diperbarui setiap jam. Bila _token_ datang dengan `kid` yang belum dikenal (Hydra baru dibuat ulang, atau _key_ dirotasi), `keyfunc` mengunduh ulang JWKS. Unduh ulang ini dibatasi paling sering sekali per 5 detik. Tanpa batas tersebut, penyerang yang mengirim _token_ sampah dengan `kid` acak akan membuat service membanjiri Hydra dengan permintaan JWKS.

Kegagalan mengunduh JWKS saat _startup_ hanya dicatat di log, tidak menghentikan service. `account` tetap berjalan ketika Hydra mati; hanya pemeriksaan _token_ yang gagal hingga _key_ berhasil diunduh.

Buat _file_ `account/internal/auth/verifier.go`:

```go
// Package auth checks the OAuth2 access tokens (JWT) that callers send. The
// account service is a resource server: it never issues tokens and never sees
// client secrets, it only verifies what the authorization server (Hydra) signed.
package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"time"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/time/rate"
)

// Claims are the token fields this service reads. Hydra puts the granted
// scopes into "scp" as a JSON array; other servers (e.g. Keycloak) use a
// space-separated "scope" string, so this struct is specific to Hydra.
type Claims struct {
	jwt.RegisteredClaims
	ClientID string   `json:"client_id"`
	Scopes   []string `json:"scp"`
}

func (c Claims) HasScope(scope string) bool { return slices.Contains(c.Scopes, scope) }

var (
	// ErrNoToken: the request carries no bearer token at all.
	ErrNoToken = errors.New("missing bearer token")
	// ErrInvalidToken: bad signature, wrong issuer, expired, or not a JWT.
	ErrInvalidToken = errors.New("invalid token")
)

type Verifier struct {
	keys   keyfunc.Keyfunc
	parser *jwt.Parser
}

// NewVerifier fetches the signing keys from jwksURL once at startup and every
// hour after. A failed fetch is logged, not fatal. A token signed with an
// unknown key ID triggers a fresh download, at most once per 5 s.
// ctx ends the background refresh.
func NewVerifier(ctx context.Context, issuer, jwksURL string, log *slog.Logger) (*Verifier, error) {
	keys, err := keyfunc.NewDefaultOverrideCtx(ctx, []string{jwksURL}, keyfunc.Override{
		RefreshUnknownKID: rate.NewLimiter(rate.Every(5*time.Second), 1),
		// Bounds both the wait for the rate limiter and the download itself: a
		// request with an unknown key ID waits at most 5 s, then gets 401.
		RateLimitWaitMax: 5 * time.Second,
		HTTPTimeout:      5 * time.Second,
		RefreshErrorHandlerFunc: func(u string) func(context.Context, error) {
			return func(ctx context.Context, err error) {
				log.ErrorContext(ctx, "fetching signing keys failed", "jwks_url", u, "error", err)
			}
		},
	})
	if err != nil {
		return nil, fmt.Errorf("JWKS from %s: %w", jwksURL, err)
	}
	return &Verifier{
		keys: keys,
		parser: jwt.NewParser(
			// Only the algorithm the authorization server uses: blocks "alg: none"
			// and RS/HS confusion.
			jwt.WithValidMethods([]string{"RS256"}),
			// Exact match, trailing slash included.
			jwt.WithIssuer(issuer),
			// A token without exp would be valid forever.
			jwt.WithExpirationRequired(),
			// Tolerates small clock differences between the servers.
			jwt.WithLeeway(30*time.Second),
		),
	}, nil
}

// Verify checks signature, issuer and expiry, and returns the claims. Scope is
// the caller's business: each endpoint needs a different one.
//
// The audience is not checked: client credentials tokens from Hydra carry an
// empty "aud" unless the client asks for one. Production setups register an
// audience per resource server and check it here.
func (v *Verifier) Verify(token string) (Claims, error) {
	var c Claims
	if _, err := v.parser.ParseWithClaims(token, &c, v.keys.Keyfunc); err != nil {
		return Claims{}, fmt.Errorf("%w: %w", ErrInvalidToken, err)
	}
	return c, nil
}
```

`Verify` membungkus error asli dengan `ErrInvalidToken`. Pemanggil dapat menulis error lengkap ke log (misalnya `token is expired`) dan hanya mengirim `invalid token` ke _client_.

=== _Interceptor_ gRPC di `account`

_Interceptor_ membaca _token_ dari _metadata_ gRPC. _Metadata_ gRPC berjalan sebagai _header_ HTTP/2, sehingga nama _key_-nya selalu huruf kecil: `authorization`, bukan `Authorization`.

Urutan pemeriksaan di _interceptor_:

+ Metode publik (gRPC _health_ dan _reflection_) langsung diteruskan tanpa _token_.
+ Metode yang tidak terdaftar di peta _scope_ ditolak dengan `PermissionDenied`. Dengan begitu, RPC _unary_ baru yang ditambahkan ke `AccountService` tanpa _scope_ otomatis tertutup, bukan terbuka.
+ _Token_ tidak ada atau tidak valid: `Unauthenticated`.
+ _Token_ valid tetapi _scope_ kurang: `PermissionDenied`.
+ Lolos semua pemeriksaan: _claim_ disimpan di `context` agar _handler_ dapat membaca `client_id` pemanggil.

Sifat "otomatis tertutup" ini hanya berlaku untuk panggilan yang melewati _interceptor_ dan tidak termasuk metode publik. Ada dua celah yang perlu diingat. Pertama, _interceptor_ ini hanya untuk RPC _unary_. RPC _streaming_ tidak pernah melewatinya, dan service ini tidak memasang _stream interceptor_, sehingga metode _streaming_ akan terbuka. Kedua, `account/main.go` menganggap semua metode di luar `AccountService` sebagai metode publik. Service gRPC lain yang kelak didaftarkan di server yang sama otomatis terbuka. Sebelum menambah service seperti itu, persempit fungsi penentu metode publik agar hanya meloloskan _health_ dan _reflection_.

Detail penolakan (kedaluwarsa, _issuer_ salah, tanda tangan tidak cocok) hanya ditulis ke log `grpc call rejected`. Pemanggil hanya menerima `invalid token`. Informasi seperti "_issuer_ yang diharapkan adalah X" membantu penyerang, bukan pemanggil yang sah.

Buat _file_ `account/internal/auth/grpc.go`:

```go
package auth

import (
	"context"
	"log/slog"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type claimsKey struct{}

// ClaimsFrom returns the verified claims of the current call, if any.
func ClaimsFrom(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey{}).(Claims)
	return c, ok
}

// UnaryServerInterceptor requires a valid bearer token in the "authorization"
// metadata and the scope that scopes lists for the method:
//   - no token or an invalid one: Unauthenticated ("who are you?")
//   - valid token without the scope: PermissionDenied ("I know you, but no")
//
// public names full methods that need no token, e.g. the health service, which
// probes call without credentials. Every other method must be in scopes; one
// that is missing is denied, so a new unary RPC added to a protected service
// without a scope is closed, not open.
//
// Fail closed covers only what reaches this interceptor and is not public:
//   - It is a unary interceptor. A streaming RPC never passes through it, and
//     no stream interceptor is installed, so a streaming method would be open.
//   - The account service passes "not AccountService" as public, so any other
//     service registered on the same server later is open by default. Narrow
//     public to the health and reflection services before adding one.
func UnaryServerInterceptor(v *Verifier, scopes map[string]string, public func(fullMethod string) bool, log *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if public(info.FullMethod) {
			return handler(ctx, req)
		}
		scope, ok := scopes[info.FullMethod]
		if !ok {
			log.Error("no scope configured for gRPC method, denied", "method", info.FullMethod)
			return nil, status.Error(codes.PermissionDenied, "method not allowed")
		}

		token, err := bearerFromMetadata(ctx)
		if err != nil {
			log.Warn("grpc call rejected", "method", info.FullMethod, "error", err)
			return nil, status.Error(codes.Unauthenticated, err.Error())
		}
		claims, err := v.Verify(token)
		if err != nil {
			// The detail (expired, wrong issuer, bad signature) goes to our log only;
			// the caller learns that the token was not accepted.
			log.Warn("grpc call rejected", "method", info.FullMethod, "error", err)
			return nil, status.Error(codes.Unauthenticated, ErrInvalidToken.Error())
		}
		if !claims.HasScope(scope) {
			log.Warn("grpc call rejected", "method", info.FullMethod, "client_id", claims.ClientID,
				"required_scope", scope, "token_scopes", claims.Scopes)
			return nil, status.Errorf(codes.PermissionDenied, "scope %s required", scope)
		}
		return handler(context.WithValue(ctx, claimsKey{}, claims), req)
	}
}

// bearerFromMetadata reads "authorization: Bearer <token>". gRPC metadata keys
// are lower case: it travels as an HTTP/2 header.
func bearerFromMetadata(ctx context.Context) (string, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	values := md.Get("authorization")
	if len(values) == 0 {
		return "", ErrNoToken
	}
	scheme, token, ok := strings.Cut(values[0], " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") || token == "" {
		return "", ErrNoToken
	}
	return token, nil
}
```

Kunci `claimsKey` sengaja berupa tipe privat. Paket lain tidak dapat membuat kunci yang sama, sehingga tidak ada kode lain yang bisa menimpa _claim_ di `context`.

=== Peta _Scope_ dan Log Pemanggil

Peta _scope_ diletakkan di paket `account`, di samping `GRPCServer`, karena paket tersebut yang tahu arti setiap RPC. Tambahkan di `account/internal/account/grpc.go`, tepat sebelum deklarasi `type GRPCServer struct`:

```go
// GRPCScopes is the OAuth2 scope each RPC requires (Lab 7). Reading and moving
// money are separate scopes, so a client that only displays balances cannot
// debit. The auth interceptor denies any AccountService method missing here.
var GRPCScopes = map[string]string{
	accountv1.AccountService_GetAccount_FullMethodName: "account:read",
	accountv1.AccountService_Debit_FullMethodName:      "account:write",
	accountv1.AccountService_Credit_FullMethodName:     "account:write",
}
```

Konstanta `..._FullMethodName` dihasilkan oleh `protoc-gen-go-grpc` di Lab 4. Menggunakan konstanta ini lebih aman dibandingkan menulis _string_ `"/account.v1.AccountService/Debit"` secara manual: salah ketik langsung menjadi error kompilasi.

Tambahkan juga _import_ paket `auth` di _file_ yang sama:

```go
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/auth"
```

Sekarang setiap mutasi saldo dapat dicatat beserta _client_ yang memintanya. Di fungsi `mutate`, tepat setelah pemanggilan `s.store.Mutate` beserta blok `if err != nil` miliknya, ambil _claim_ dan tambahkan `client_id` ke kedua baris log:

```go
	// client_id from the verified token (Lab 7): who moved the money, for the audit trail.
	caller, _ := auth.ClaimsFrom(ctx)
	if !applied {
		s.log.Info("mutation already applied, not repeated", "number", a.Number, "type", t, "reference", req.Reference,
			"client_id", caller.ClientID)
		return a, nil
	}
	s.log.Info("account mutated", "number", a.Number, "type", t, "amount", req.Amount, "reference", req.Reference,
		"client_id", caller.ClientID)
	return a, nil
```

=== Memasang _Interceptor_ di `account/main.go`

Tambahkan _import_ `.../account/internal/auth`, lalu buat `Verifier` sebelum `grpc.NewServer`. Fungsi penentu metode publik yang sebelumnya ditulis _inline_ untuk _fault injector_ kini digunakan bersama oleh dua _interceptor_, jadi fungsi tersebut diberi nama. Ganti blok pembuatan `grpcSrv` menjadi:

```go
	// Lab 7: every AccountService call needs a JWT from the authorization
	// server. The account REST API on HTTP_ADDR stays open in this lab to keep
	// the setup steps (creating accounts) short; in production it gets the same
	// kind of middleware as the transfer REST API.
	verifier, err := auth.NewVerifier(ctx, cfg.OAuthIssuer, cfg.OAuthJWKSURL, log)
	if err != nil {
		return err
	}
	// Health and reflection are not AccountService: no token, no faults, like
	// the HTTP probes. Note the predicate opens every non-AccountService method,
	// not only those two, and auth is a unary interceptor only: see
	// auth.UnaryServerInterceptor before registering another service or a
	// streaming RPC.
	notAccountService := func(method string) bool {
		return !strings.HasPrefix(method, "/"+accountv1.AccountService_ServiceDesc.ServiceName+"/")
	}

	// Interceptors run in the order given: logging sees the code that auth or the
	// fault injector produced. Auth comes before faults: a caller without a valid
	// token is turned away before any work, simulated or real, is done.
	grpcSrv := grpc.NewServer(grpc.ChainUnaryInterceptor(
		interceptor.Logging(log),
		auth.UnaryServerInterceptor(verifier, account.GRPCScopes, notAccountService, log),
		faults.UnaryServerInterceptor(notAccountService),
	))
```

Urutan _interceptor_ di `ChainUnaryInterceptor` menentukan urutan eksekusi: yang pertama membungkus yang berikutnya.

- *Logging di posisi pertama* agar log `grpc request` mencatat kode hasil akhir, termasuk `Unauthenticated` dari _auth_ dan `Unavailable` dari _fault injector_.
- *_Auth_ sebelum _fault injector_* agar pemanggil tanpa _token_ valid ditolak sebelum menerima _delay_ simulasi. Di sistem sungguhan, prinsipnya sama: permintaan yang tidak sah tidak boleh menghabiskan sumber daya.

=== _Resource Server_ di `transfer`

`transfer` membutuhkan `Verifier` yang sama. Salin _file_-nya:

#perintah[```bash
mkdir -p transfer/internal/auth
cp account/internal/auth/verifier.go transfer/internal/auth/verifier.go
```]

Ubah komentar paket di baris pertama agar menyebut `transfer`. Setiap service memiliki salinannya sendiri, bukan modul _library_ bersama. Modul bersama mengikat jadwal rilis semua service: perubahan kecil di _library_ memaksa semua service ikut di-_build_ ulang dan di-_deploy_. Tim yang memilih _library_ bersama perlu memberinya versi seperti _dependency_ eksternal lainnya.

==== _Middleware_ REST

_Middleware_ ini padanan _interceptor_ gRPC di `account` untuk REST: penolakan dinyatakan dengan status HTTP dan _header_. RFC 6750 mengatur cara _resource server_ memberi tahu alasan penolakan melalui _header_ `WWW-Authenticate`:

- tanpa _token_: `Bearer`;
- _token_ tidak valid: `Bearer error="invalid_token"`;
- _scope_ kurang: `Bearer error="insufficient_scope", scope="..."`.

Buat _file_ `transfer/internal/auth/http.go`:

```go
package auth

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
)

type claimsKey struct{}

// ClaimsFrom returns the verified claims of the current request, if any.
func ClaimsFrom(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey{}).(Claims)
	return c, ok
}

// Middleware builds the per-route guard for the REST API.
type Middleware struct {
	v   *Verifier
	log *slog.Logger
}

func NewMiddleware(v *Verifier, log *slog.Logger) *Middleware {
	return &Middleware{v: v, log: log}
}

// Require lets a request through only with a valid bearer token that carries
// scope:
//   - no token or an invalid one: 401 with WWW-Authenticate (RFC 6750)
//   - valid token without the scope: 403 insufficient_scope
//
// The routes that are not wrapped (probes, /debug) stay open.
func (m *Middleware) Require(scope string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearer(r.Header.Get("Authorization"))
		if !ok {
			m.log.Warn("request rejected", "method", r.Method, "path", r.URL.Path, "error", ErrNoToken)
			w.Header().Set("WWW-Authenticate", `Bearer`)
			writeError(w, http.StatusUnauthorized, ErrNoToken.Error())
			return
		}
		claims, err := m.v.Verify(token)
		if err != nil {
			// Detail (expired, wrong issuer, bad signature) only in our log.
			m.log.Warn("request rejected", "method", r.Method, "path", r.URL.Path, "error", err)
			w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
			writeError(w, http.StatusUnauthorized, ErrInvalidToken.Error())
			return
		}
		if !claims.HasScope(scope) {
			m.log.Warn("request rejected", "method", r.Method, "path", r.URL.Path, "client_id", claims.ClientID,
				"required_scope", scope, "token_scopes", claims.Scopes)
			w.Header().Set("WWW-Authenticate", `Bearer error="insufficient_scope", scope="`+scope+`"`)
			writeError(w, http.StatusForbidden, "scope "+scope+" required")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), claimsKey{}, claims)))
	})
}

func bearer(header string) (string, bool) {
	scheme, token, ok := strings.Cut(header, " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") || token == "" {
		return "", false
	}
	return token, true
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
```

==== Memasang _Middleware_ per _Route_

_Scope_ ditentukan per _route_, jadi _middleware_ dipasang per _route_, bukan membungkus seluruh `ServeMux`. Agar paket `transfer` tidak bergantung pada paket `auth`, `Routes` menerima sebuah fungsi dengan bentuk yang didefinisikan paket `transfer` sendiri. `main.go` mengisinya dengan _middleware_ JWT, sedangkan _unit test_ mengisinya dengan fungsi yang meloloskan semua permintaan.

Di `transfer/internal/transfer/http.go`, ganti fungsi `Routes` menjadi:

```go
// OAuth2 scopes of the transfer REST API (Lab 7). The channel app that only
// shows transfer status gets read; moving money needs write.
const (
	ScopeRead  = "transfer:read"
	ScopeWrite = "transfer:write"
)

// RequireScope wraps next so it runs only for a caller whose token carries
// scope. The transfer package defines the shape; main plugs in the JWT
// middleware, tests plug in a pass-through.
type RequireScope func(scope string, next http.Handler) http.Handler

// Routes registers the API behind requireScope. Probes stay open: the kubelet
// and load balancers call them without a token.
func (h *Handler) Routes(requireScope RequireScope) *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("POST /transfers", requireScope(ScopeWrite, http.HandlerFunc(h.create)))
	mux.Handle("GET /transfers/{id}", requireScope(ScopeRead, http.HandlerFunc(h.get)))
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	return mux
}
```

Method `(*Middleware).Require` memiliki _signature_ yang sama dengan `RequireScope`, sehingga `Require` dapat langsung dioper sebagai nilai fungsi.

=== `transfer` sebagai _Client_ OAuth2

Sekarang sisi pemanggil. Setiap panggilan gRPC dari `transfer` ke `account` harus membawa _token_ `transfer-service`.

==== Konfigurasi

Tambahkan lima _field_ ke `Config` di `transfer/config.go`, setelah `KafkaTopic`:

```go
	// Lab 7, as resource server (the REST API): OAuthIssuer must equal the "iss"
	// claim of the tokens character for character; OAuthJWKSURL serves the
	// authorization server's public keys.
	OAuthIssuer  string
	OAuthJWKSURL string
	// Lab 7, as OAuth2 client (calling account over gRPC): client credentials
	// grant against OAuthTokenURL. The secret belongs in a Kubernetes Secret or
	// a vault, never in the image or the repository (Lab 9).
	OAuthClientID     string
	OAuthClientSecret string
	OAuthTokenURL     string
```

Isi di `LoadConfig`, di dalam _literal_ `cfg := Config{...}`:

```go
		OAuthIssuer:       get("OAUTH_ISSUER"),
		OAuthJWKSURL:      get("OAUTH_JWKS_URL"),
		OAuthClientID:     get("OAUTH_CLIENT_ID"),
		OAuthClientSecret: get("OAUTH_CLIENT_SECRET"),
		OAuthTokenURL:     get("OAUTH_TOKEN_URL"),
```

Tambahkan nilainya di target `run` pada `transfer/Makefile`, sebelum `go run .`:

```makefile
	OAUTH_ISSUER=http://localhost:4444/ \
	OAUTH_JWKS_URL=http://localhost:4444/.well-known/jwks.json \
	OAUTH_CLIENT_ID=transfer-service \
	OAUTH_CLIENT_SECRET=transfer-service-secret \
	OAUTH_TOKEN_URL=http://localhost:4444/oauth2/token \
```

==== `PerRPCCredentials`

gRPC menyediakan antarmuka `credentials.PerRPCCredentials` untuk menempelkan _metadata_ ke setiap panggilan. gRPC memanggil `GetRequestMetadata` sebelum setiap percobaan, termasuk percobaan ulang oleh _retry_ failsafe-go, sehingga setiap percobaan membawa _token_.

grpc-go sudah menyediakan implementasi siap pakai di paket `credentials/oauth`. Implementasi tersebut tidak digunakan di sini karena menolak mengirim _token_ lewat koneksi tanpa TLS, sedangkan koneksi gRPC di lab berjalan tanpa TLS. Penolakan itu benar untuk _production_: _bearer token_ yang terkirim tanpa enkripsi dapat disalin dan digunakan ulang oleh siapa pun yang melihat lalu lintas jaringan. Implementasi di lab ini mengembalikan `false` dari `RequireTransportSecurity`, dan komentar di kode mencatat bahwa _production_ wajib menggunakan TLS.

Tiga keputusan desain di dalam `tokenCredentials`:

- *_Token_ disimpan dan digunakan ulang* hingga 10 detik sebelum kedaluwarsa (`oauth2.Token.Valid()`). Hydra menerima satu permintaan per masa berlaku _token_, bukan satu permintaan per transfer.
- *Gagal mengambil _token_ menghasilkan `Unauthenticated`*, bukan `Unavailable`. Kebijakan _retry_ dari Lab 4 hanya mengulang `Unavailable` (dan `DeadlineExceeded` sejak Lab 5), dan _circuit breaker_ hanya menghitung error infrastruktur. Hydra yang mati tidak berarti `account` bermasalah, jadi _circuit breaker_ ke `account` tidak boleh terbuka karenanya. Error ini dibuat sebagai tipe tersendiri, `tokenFetchError`, agar dapat dibedakan dari `Unauthenticated` yang dikirim oleh `account`. Panggilan tersebut tidak pernah keluar dari `transfer`, dan transfer berakhir `FAILED` dengan kode HTTP 502.
- *_Token_ yang ditolak `account` diganti sekali.* _Token_ bisa ditolak sebelum kedaluwarsa, misalnya karena Hydra merotasi _signing key_. Hydra di lab mendapat _key_ baru setiap kali di-_restart_. Tanpa mekanisme ini, setiap panggilan gagal hingga _token_ lama kedaluwarsa, paling lama satu jam. Penggantian hanya dilakukan bila penolakan datang dari `account`. Bila yang gagal adalah pengambilan _token_ itu sendiri, percobaan kedua hanya akan menghubungi Hydra lagi dalam panggilan yang sama. Mengulang `Debit` atau `Credit` aman karena keduanya sudah _idempotent_ berdasarkan `reference` sejak Lab 5.

Buat _file_ `transfer/internal/accountclient/credentials.go`:

```go
package accountclient

import (
	"context"
	"errors"
	"sync"

	"golang.org/x/oauth2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

// FetchToken gets a new access token from the authorization server, e.g.
// (*clientcredentials.Config).Token.
type FetchToken func(ctx context.Context) (*oauth2.Token, error)

// tokenCredentials attaches "authorization: Bearer <token>" to every call
// (Lab 7). It reuses a token until shortly before it expires, so the
// authorization server sees one request per token lifetime, not one per gRPC
// call.
//
// grpc-go ships credentials/oauth for this, but it refuses to send a token
// over a connection without TLS, and the lab runs plaintext. Production runs
// TLS (or mTLS through a service mesh): a bearer token in clear text can be
// replayed by anyone who sees the traffic.
type tokenCredentials struct {
	fetch FetchToken
	mu    sync.Mutex
	tok   *oauth2.Token
}

var _ credentials.PerRPCCredentials = (*tokenCredentials)(nil)

func (c *tokenCredentials) GetRequestMetadata(ctx context.Context, _ ...string) (map[string]string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	// Valid() is false for a token that expires within the next 10 s, so a
	// token never runs out while the call is on its way.
	if !c.tok.Valid() {
		tok, err := c.fetch(ctx)
		if err != nil {
			return nil, &tokenFetchError{err: err}
		}
		c.tok = tok
	}
	return map[string]string{"authorization": c.tok.Type() + " " + c.tok.AccessToken}, nil
}

// tokenFetchError: no token, so the call never left the transfer service.
//
// Its gRPC code is Unauthenticated, not Unavailable: the account service is
// fine, our side has no token. The resiliency policies neither retry this nor
// count it against the account breaker. grpc-go passes an error with a
// GRPCStatus method through unchanged, so refreshOnUnauthenticated can tell it
// apart from an Unauthenticated sent by the account service.
type tokenFetchError struct{ err error }

func (e *tokenFetchError) Error() string { return "get access token: " + e.err.Error() }
func (e *tokenFetchError) Unwrap() error { return e.err }
func (e *tokenFetchError) GRPCStatus() *status.Status {
	return status.New(codes.Unauthenticated, e.Error())
}

// RequireTransportSecurity is false only because the lab has no TLS; see above.
func (*tokenCredentials) RequireTransportSecurity() bool { return false }

// refreshOnUnauthenticated drops the cached token when the account service
// rejects it, and repeats the call once with a new one. A token can stop being
// accepted before it expires: the authorization server rotated its signing keys
// (the lab's Hydra gets new keys on every restart) or the token was revoked.
// Without this, every call fails until the old token expires, up to an hour.
// Repeating Debit/Credit is safe: they are idempotent by reference (Lab 5).
//
// Only a rejection by the account service counts. When the token fetch itself
// failed, a second try would only hit the authorization server again within
// the same call.
func (c *tokenCredentials) refreshOnUnauthenticated(ctx context.Context, method string, req, reply any,
	cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
	err := invoker(ctx, method, req, reply, cc, opts...)
	var fetchErr *tokenFetchError
	if status.Code(err) != codes.Unauthenticated || errors.As(err, &fetchErr) {
		return err
	}
	c.mu.Lock()
	c.tok = nil
	c.mu.Unlock()
	return invoker(ctx, method, req, reply, cc, opts...)
}
```

`c.tok.Valid()` aman dipanggil walaupun `c.tok` masih `nil`: method `Valid` pada `*oauth2.Token` memeriksa `nil` terlebih dahulu dan mengembalikan `false`.

grpc-go meneruskan error yang memiliki method `GRPCStatus` apa adanya ke pemanggil. Karena itu, `refreshOnUnauthenticated` dapat memeriksa dua hal sekaligus: `status.Code(err)` tetap `Unauthenticated` bagi kebijakan _retry_ dan _circuit breaker_, sedangkan `errors.As` mengenali bahwa error tersebut berasal dari `tokenFetchError`, bukan dari `account`.

==== Memasang _Credentials_ di `accountclient.New`

Di `transfer/internal/accountclient/client.go`, tambahkan parameter `fetch` ke `New`:

```go
func New(target string, s Settings, fetch FetchToken, log *slog.Logger, opts ...grpc.DialOption) (*Client, error) {
```

Sejak Lab 5, `New` membuka dua koneksi melalui fungsi `dial`: koneksi utama dengan kebijakan `resilience` dan koneksi _reversal_ dengan kebijakan `reversalResilience`. Kedua koneksi memanggil service yang sama dengan identitas _client_ yang sama, sehingga cukup satu _cache_ _token_ untuk keduanya. Di `New`, ganti dua pemanggilan `dial` menjadi:

```go
	// One token cache for both connections: they talk to the same service with
	// the same client identity.
	tokens := &tokenCredentials{fetch: fetch}

	// An interceptor belongs to a connection, so the reversal gets a connection of
	// its own. The cost is one more TCP connection to the account service.
	conn, err := dial(target, tokens, resilience, opts)
	if err != nil {
		return nil, err
	}
	reversalConn, err := dial(target, tokens, reversalResilience, opts)
```

Lalu ubah _signature_ `dial`, dan ganti baris `grpc.WithUnaryInterceptor(interceptor),` di dalamnya dengan dua opsi baru. Opsi lain (koneksi tanpa TLS dan pengaturan _backoff_ koneksi) tidak berubah:

```go
func dial(target string, tokens *tokenCredentials, resilience grpc.UnaryClientInterceptor, extra []grpc.DialOption) (*grpc.ClientConn, error) {
	opts := append([]grpc.DialOption{
		// Plaintext: fine on a laptop, not in production. Service-to-service calls
		// there go over TLS (or mTLS through a service mesh).
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		// The token is added per attempt, after the interceptors, so a retried
		// attempt carries a valid token too.
		grpc.WithPerRPCCredentials(tokens),
		// First interceptor = outermost: a call repeated with a new token goes
		// through the resiliency policies again.
		grpc.WithChainUnaryInterceptor(tokens.refreshOnUnauthenticated, resilience),
```

Urutannya penting. `refreshOnUnauthenticated` berada di luar kebijakan _resiliency_, sehingga panggilan yang diulang dengan _token_ baru kembali melewati _timeout_, _retry_, dan _circuit breaker_ (atau _retry_ khusus _reversal_ di koneksi kedua).

#note[
  *Batasan yang belum ditangani.* Kebijakan _retry_ _reversal_ dari Lab 5 hanya mengulang error infrastruktur (`Unavailable`, `DeadlineExceeded`, `Internal`, `Unknown`). Kegagalan mengambil _token_ bernilai `Unauthenticated`, jadi tidak diulang. Bila Hydra mati tepat saat _reversal_ berjalan dan _token_ di _cache_ sudah kedaluwarsa, transfer langsung berakhir `COMPENSATION_FAILED` (HTTP 500) dan perlu koreksi manual.
]

==== Memasang _Verifier_ dan _Client_ OAuth2 di `transfer/main.go`

Tambahkan dua _import_:

```go
	"golang.org/x/oauth2/clientcredentials"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/auth"
```

Ganti pembuatan `accounts` dan `mux` menjadi:

```go
	// Lab 7: the transfer service is an OAuth2 client of its own. It asks only
	// for account:write (Debit, Credit), not everything its client registration
	// allows: least privilege per token. accountclient caches the token and
	// fetches a new one shortly before expiry.
	tokenCfg := clientcredentials.Config{
		ClientID:     cfg.OAuthClientID,
		ClientSecret: cfg.OAuthClientSecret,
		TokenURL:     cfg.OAuthTokenURL,
		Scopes:       []string{"account:write"},
	}
	// The fetch runs inside a gRPC attempt and is bounded by its 2 s timeout.
	accounts, err := accountclient.New(cfg.AccountGRPCAddr, accountclient.ProductionSettings, tokenCfg.Token, log)
	if err != nil {
		return err
	}
	defer accounts.Close()

	verifier, err := auth.NewVerifier(ctx, cfg.OAuthIssuer, cfg.OAuthJWKSURL, log)
	if err != nil {
		return err
	}
	svc := transfer.NewService(store, accounts, log)
	mux := transfer.NewHandler(svc, log).Routes(auth.NewMiddleware(verifier, log).Require)
	// Open on purpose, like the probes: an operator reads it during an incident.
	// Production keeps /debug on an internal port or behind the gateway.
	mux.HandleFunc("GET /debug/circuit-breaker", accounts.ServeCircuitBreaker)
```

Client `transfer-service` terdaftar dengan _scope_ `account:read` dan `account:write`, tetapi `transfer` hanya meminta `account:write` karena hanya memanggil `Debit` dan `Credit`. _Token_ yang bocor hanya membawa hak yang memang dibutuhkan (_least privilege_).

`tokenCfg.Token` adalah _method value_ bertipe `func(context.Context) (*oauth2.Token, error)`, sama dengan tipe `FetchToken`. _Token_ baru diambil saat panggilan gRPC pertama, bukan saat _startup_. `transfer` tetap bisa menyala dan lolos _readiness probe_ walaupun Hydra sedang mati.

Agar log _startup_ menunjukkan _issuer_ yang digunakan, tambahkan `"oauth_issuer", cfg.OAuthIssuer` ke baris log `transfer service listening`. Informasi ini membantu saat mencari penyebab semua permintaan ditolak (lihat Masalah Umum).

=== `failure_reason` yang Aman untuk Pemanggil

Hingga Lab 6, `failure_reason` berisi teks error apa adanya, misalnya:

```text
debit failed: rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp 127.0.0.1:9091: connect: connection refused"
```

Teks ini sekarang sampai ke aplikasi _channel_ yang memegang _token_ `transfer:read`, dan juga ikut terkirim di _event_ Kafka. Alamat IP, port, dan pesan error dari _library_ internal tidak berguna bagi pemanggil, tetapi berguna bagi penyerang yang memetakan jaringan. API hanya perlu menyebut hasil bisnis; detail teknisnya cukup ada di log.

Tambahkan fungsi berikut di `transfer/internal/transfer/service.go`, misalnya tepat sebelum `func (s *Service) Get`:

```go
// publicReason is the failure text stored in failure_reason, returned by the
// API and carried in the events (Lab 7). Business outcomes are named; any other
// error becomes one generic phrase, because its text can hold internal
// addresses, ports and library messages (e.g. "dial tcp 10.0.3.7:9091:
// connection refused") that the caller cannot act on and an attacker can
// use. The full error is in the log next to the transfer ID.
func publicReason(err error) string {
	switch {
	case errors.Is(err, ErrInsufficientFunds):
		return ErrInsufficientFunds.Error()
	case errors.Is(err, ErrAccountNotFound):
		return ErrAccountNotFound.Error()
	case errors.Is(err, ErrAccountUnavailable):
		return ErrAccountUnavailable.Error()
	default:
		return "account service error"
	}
}
```

Lalu ganti tiga tempat yang menyusun alasan dengan `fmt.Sprintf`:

```go
// di run(), cabang debit gagal
return s.finish(ctx, t, Pending, Failed, "debit failed: "+publicReason(err), EventFailed, err)

// di compensate(), baris pertama
reason := "credit failed: " + publicReason(cause)

// di compensate(), cabang reversal gagal
reason = reason + "; reversal failed: " + publicReason(err)
```

Cabang _reversal_ gagal tetap mengembalikan error yang membungkus `ErrReversalFailed` dari Lab 5, sehingga transfer `COMPENSATION_FAILED` tetap dijawab 500. Yang berubah hanya teks `reason`.

`publicReason` menaruh pesan _sentinel_ (misalnya `insufficient funds`) di akhir teks. Fungsi `replayOutcome` dari Lab 6 bergantung pada sifat ini: kode HTTP untuk _replay_ ditentukan dari akhiran `failure_reason`. Teks lama sebelum Lab 7 (`debit failed: debit 1111111111: insufficient funds`) juga berakhir dengan pesan yang sama, jadi _replay_ untuk transfer lama tetap menghasilkan kode yang sama. Perbarui komentar di atas `replayOutcome` agar menyebut kedua format tersebut.

Agar detail error tidak hilang, tambahkan `"error", cause` ke log `transfer not completed` di fungsi `finish`:

```go
		s.log.Warn("transfer not completed", "transfer_id", t.ID, "status", to, "reason", reason, "error", cause)
```

=== Memperbarui _Unit Test_

Dua _signature_ berubah: `accountclient.New` mendapat parameter `fetch`, dan `Handler.Routes` mendapat parameter `requireScope`. _Test_ lama tidak lagi bisa dikompilasi. Ambil versi yang sudah diperbarui dari _checkpoint_, sekaligus _test_ baru untuk kode Lab 7:

#perintah[```bash
git checkout lab-07 -- \
  account/internal/auth/grpc_test.go \
  transfer/internal/auth/http_test.go \
  transfer/internal/accountclient/client_test.go \
  transfer/internal/transfer/http_test.go \
  transfer/internal/transfer/service_test.go
(cd account && go mod tidy)
(cd transfer && go mod tidy)
make test
```]

Baca `account/internal/auth/grpc_test.go`. _File_ ini menunjukkan cara menguji validasi JWT tanpa Hydra:

+ `newTestVerifier` membuat _key_ RSA baru, lalu menyajikan _public key_-nya sebagai JWKS dari `httptest.Server`, dengan format yang sama seperti `/.well-known/jwks.json` milik Hydra.
+ `sign` membuat _token_ serupa _token_ Hydra, dan menerima fungsi untuk mengubah _claim_ tertentu.
+ _Table-driven test_ mencakup _token_ valid, _scheme_ huruf kecil, tanpa _token_, _token_ Basic, _token_ sampah, kedaluwarsa, tanpa `exp`, _issuer_ lain, ditandatangani _key_ lain, _scope_ kurang, metode tanpa _scope_, dan metode publik.
+ `TestSigningAlgorithmIsPinned` membuktikan _token_ HS256 tidak lolos sebagai RS256.

_Test_ di `accountclient` mencakup perilaku baru berikut. Fungsi bantu `serve` kini menerima parameter `fetch`, sehingga setiap _test_ dapat memasang sumber _token_ sendiri.

- `TestSendsBearerToken`: _token_ terkirim di _metadata_ `authorization`.
- `TestTokenFailureIsNotAnAccountFailure`: gagal mengambil _token_ tidak di-_retry_, tidak membuka _circuit breaker_, dan tidak memicu pengambilan _token_ kedua. Sepuluh panggilan menghasilkan tepat sepuluh kali pengambilan _token_.
- `TestRejectedTokenIsReplaced`: _token_ yang ditolak `account` diganti, lalu panggilan diulang dan berhasil.
- `TestRejectedTokenIsReplacedOnlyOnce`: bila _token_ pengganti juga ditolak, panggilan gagal dengan `Unauthenticated` setelah dua kali sampai di server dan dua kali pengambilan _token_, tanpa berulang terus.
 `TestFailureReasonIsGeneric` di `service_test.go` memastikan alamat internal tidak muncul di `failure_reason`.

== Verifikasi

=== Menjalankan Service

Jalankan ketiga service di terminal terpisah:

#perintah[```bash
make -C account run
make -C transfer run
make -C notification run
```]

Pastikan `account` dan `transfer` tidak berhenti dengan pesan `missing required environment variables`. Log _startup_ `transfer` memuat `oauth_issuer=http://localhost:4444/`.

=== Empat Skenario REST

Siapkan dua _token_: satu dengan kedua _scope_, satu lagi hanya-baca:

#perintah[```bash
TOKEN=$(make -s token)
RO=$(make -s token SCOPE=transfer:read)
```]

*Tanpa _token_: 401.*

#perintah[```bash
curl -i -X POST localhost:8082/transfers \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

```text
HTTP/1.1 401 Unauthorized
Content-Type: application/json
Www-Authenticate: Bearer
...
{"error":"missing bearer token"}
```

Go menulis nama _header_ dengan huruf besar di awal setiap kata (`Www-Authenticate`). Nama _header_ HTTP tidak membedakan huruf besar dan kecil.

*_Token_ hanya-baca untuk operasi tulis: 403.*

#perintah[```bash
curl -i -X POST localhost:8082/transfers -H "Authorization: Bearer $RO" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

```text
HTTP/1.1 403 Forbidden
Content-Type: application/json
Www-Authenticate: Bearer error="insufficient_scope", scope="transfer:write"
...
{"error":"scope transfer:write required"}
```

*_Token_ dengan `transfer:write`: 201.*

#perintah[```bash
curl -i -X POST localhost:8082/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

Respons berstatus `201 Created` dengan `"status":"COMPLETED"` dan _header_ `Location: /transfers/...`.

*_Token_ hanya-baca untuk operasi baca: 200.* Ganti `ID` dengan nilai `id` dari respons sebelumnya:

#perintah[```bash
curl -i -H "Authorization: Bearer $RO" localhost:8082/transfers/ID
```]

Respons berstatus `200 OK` dan berisi transfer yang sama.

_Endpoint_ yang terbuka tetap dapat diakses tanpa _token_:

#perintah[```bash
curl localhost:8082/readyz
curl localhost:8082/debug/circuit-breaker
```]

=== Log di Kedua Service

Di terminal `transfer`, permintaan yang ditolak menghasilkan log `request rejected`:

```text
time=... level=WARN msg="request rejected" method=POST path=/transfers error="missing bearer token"
time=... level=WARN msg="request rejected" method=POST path=/transfers client_id=channel-app required_scope=transfer:write token_scopes=[transfer:read]
```

Di terminal `account`, transfer yang berhasil mencatat _client_ pemanggil:

```text
time=... level=INFO msg="account mutated" number=1111111111 type=DEBIT amount=100000 reference=... client_id=transfer-service
time=... level=INFO msg="account mutated" number=2222222222 type=CREDIT amount=100000 reference=... client_id=transfer-service
```

`client_id=transfer-service` membuktikan bahwa `transfer` mengirim _token_ dan `account` memverifikasinya.

=== `failure_reason` Generik

Matikan `account` (Ctrl+C di terminalnya), lalu buat transfer:

#perintah[```bash
curl -i -X POST localhost:8082/transfers -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account":"1111111111","to_account":"2222222222","amount":"100000"}'
```]

Respons berstatus `502 Bad Gateway` dan berisi `"status":"FAILED"` serta `"failure_reason":"debit failed: account service error"`, tanpa alamat `127.0.0.1:9091`. Alamat tersebut tetap ada di log `transfer not completed` pada _field_ `error`. Bila percobaan diulang hingga _circuit breaker_ terbuka, respons berubah menjadi `503 Service Unavailable` dengan `failure_reason` `debit failed: account service unavailable`: tidak ada uang yang berpindah dan permintaan aman diulang. Jalankan lagi `make -C account run` setelah selesai.

Format baru hanya berlaku untuk transfer yang dibuat setelah kode Lab 7 berjalan. Transfer yang tersimpan sebelumnya tetap menampilkan `failure_reason` lama yang memuat pesan asli, misalnya `debit failed: debit 1111111111: rpc error: ...`. Untuk melihat format baru, selalu periksa transfer gagal yang baru dibuat. _Replay_ dengan `Idempotency-Key` milik transfer lama tetap menghasilkan kode HTTP yang sama seperti permintaan aslinya.

== Masalah Umum

*Semua permintaan dengan _token_ dijawab 401.* Periksa log `request rejected` di `transfer`. Bila error-nya menyebut _issuer_ (`token has invalid issuer`), nilai `OAUTH_ISSUER` tidak sama persis dengan _claim_ `iss`. Hydra menerbitkan `http://localhost:4444/` dengan garis miring di akhir; `http://localhost:4444` tanpa garis miring dianggap _issuer_ lain. Log _startup_ `transfer` menampilkan nilai `oauth_issuer` yang sedang digunakan.

*`make -s token` gagal dengan `invalid_client`.* Hydra menyimpan _client_ di memori. Setelah _container_ Hydra di-_restart_ (termasuk setelah Docker atau laptop di-_restart_), _client_ hilang. Jalankan `make infra-up` lagi; target ini menjalankan `hydra-init` yang menghapus lalu membuat ulang kedua _client_.

*_Token_ di variabel `TOKEN` tiba-tiba ditolak dengan `invalid token`.* Ada dua kemungkinan: _token_ sudah lebih dari satu jam (kedaluwarsa), atau Hydra sudah di-_restart_ sehingga _signing key_-nya berganti dan `transfer` sudah mengunduh JWKS yang baru. Ambil _token_ baru dengan `TOKEN=$(make -s token)`. Log `request rejected` menyebut penyebab persisnya.

*Permintaan pertama setelah Hydra di-_restart_ lambat, sekitar setengah detik.* Hydra yang baru menyala membuat _signing key_ baru saat permintaan _token_ pertama. Service yang sudah berjalan mengunduh ulang JWKS saat bertemu `kid` yang belum dikenal. Unduh ulang dibatasi sekali per 5 detik, dan permintaan yang menunggu batas tersebut paling lama menunggu 5 detik sebelum dijawab 401.

*Log `fetching signing keys failed` saat _startup_.* Hydra belum berjalan ketika service menyala. Service tetap berjalan, tetapi semua pemeriksaan _token_ gagal hingga Hydra tersedia. Jalankan `make infra-up`, lalu ulangi permintaan.

*Transfer dijawab 502, `FAILED` dengan alasan `debit failed: account service error`, padahal `account` berjalan.* Lihat log `transfer not completed` di `transfer`. Bila isinya `get access token`, `transfer` gagal mengambil _token_ dari Hydra: periksa `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_TOKEN_URL`, dan pastikan `hydra-init` sudah berjalan. Panggilan ini tidak pernah sampai ke `account`, tidak diulang, dan tidak membuka _circuit breaker_ ke `account`; `make breaker` tetap menunjukkan `closed`.

*Kompilasi gagal di _test_ dengan pesan `cannot use log (variable of type *slog.Logger) as FetchToken value in argument to New` atau `not enough arguments in call to ....Routes`.* _Test_ lama belum diganti. Jalankan perintah `git checkout lab-07 -- ...` di langkah Memperbarui _Unit Test_.

*Service lama masih menggunakan port 8081 atau 8082.* Hentikan berdasarkan port, misalnya `kill $(lsof -t -i :8081)`. Biner hasil `go run` di macOS berada di folder _cache_ Go, sehingga pencarian berdasarkan nama proses sering tidak menemukannya.

== Eksplorasi Mandiri

+ *Rotasi _signing key_.* Pastikan sudah ada satu transfer berhasil sejak `transfer` dijalankan, agar `transfer` menyimpan _token_ `transfer-service` di _cache_. Jalankan `docker compose restart hydra` lalu `docker compose run --rm hydra-init`; Hydra kini memiliki _signing key_ baru. Me-_restart_ Hydra saja belum memicu penolakan: `account` masih menyimpan _key_ lama di JWKS yang sudah diunduh (diperbarui setiap jam), sehingga _token_ lama di `transfer` tetap diterima. Karena itu, jalankan ulang `account` (Ctrl+C, lalu `make -C account run`) agar `account` hanya mengenal _key_ baru. Buat transfer dengan _token_ `channel-app` baru dari `make -s token`. Amati log `account`: muncul `grpc call rejected` dengan error `key not found` dan `grpc request` dengan `code=Unauthenticated`, lalu `Debit` yang diulang berhasil. Jelaskan komponen mana yang mengganti _token_ dan komponen mana yang mengunduh ulang JWKS. Mengapa mengulang `Debit` setelah `Unauthenticated` aman?
+ *_Issuer_ yang salah.* Hapus garis miring di akhir `OAUTH_ISSUER` pada `transfer/Makefile`, jalankan ulang `transfer`, lalu kirim permintaan dengan _token_ valid. Temukan baris log yang menjelaskan penolakan. Kembalikan dengan `git checkout -- transfer/Makefile` atau perbaiki secara manual.
+ *Hak minimal.* Ubah `Scopes` di `tokenCfg` menjadi `account:read` saja, jalankan ulang `transfer`, lalu buat transfer. Kode gRPC apa yang diterima `transfer`, apakah dihitung _circuit breaker_, dan apa isi `failure_reason`? Kembalikan ke `account:write` setelah selesai.
+ *Hydra mati.* Hentikan Hydra dengan `docker compose stop hydra`, jalankan ulang `transfer`, lalu periksa `/readyz` dan buat transfer dengan _token_ lama yang belum kedaluwarsa. Bandingkan perilaku `transfer` sebagai _resource server_ (JWKS sudah tersimpan atau belum) dengan perilakunya sebagai _client_ (perlu _token_ baru). Nyalakan kembali dengan `make infra-up`.

== Checkpoint

Kondisi kode di akhir lab ini tersimpan di tag `lab-07`. Bagian OAuth2 dan JWT di `studi-kasus/README.md` tersedia di tag tersebut: `git checkout lab-07 -- README.md`. Bandingkan hasil kerja dengan _checkpoint_:

#perintah[```bash
git diff lab-07 -- .
```]

Peserta yang ingin langsung melanjutkan ke Lab 8 dari kode referensi membuat _branch_ kerja baru dari tag tersebut:

#perintah[```bash
git switch -c lab-08-kerja lab-07
```]
