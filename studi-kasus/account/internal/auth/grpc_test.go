package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	testIssuer = "http://issuer.test/"
	testKID    = "test-key"
)

// newTestVerifier serves the public half of a fresh RSA key as a JWKS on
// httptest, the same way Hydra serves /.well-known/jwks.json, and returns a
// Verifier wired to it plus the private key for signing test tokens.
func newTestVerifier(t *testing.T) (*Verifier, *rsa.PrivateKey) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	jwks, _ := json.Marshal(map[string]any{"keys": []map[string]string{{
		"kty": "RSA", "use": "sig", "alg": "RS256", "kid": testKID,
		"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
		"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
	}}})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(jwks)
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	v, err := NewVerifier(ctx, testIssuer, srv.URL, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return v, key
}

// sign builds a token like Hydra's client credentials token; edit adjusts claims.
func sign(t *testing.T, key *rsa.PrivateKey, edit func(*Claims)) string {
	t.Helper()
	now := time.Now()
	c := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    testIssuer,
			Subject:   "transfer-service",
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
		},
		ClientID: "transfer-service",
		Scopes:   []string{"account:read", "account:write"},
	}
	if edit != nil {
		edit(&c)
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, c)
	tok.Header["kid"] = testKID
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestUnaryServerInterceptor(t *testing.T) {
	v, key := newTestVerifier(t)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	scopes := map[string]string{"/svc/Read": "account:read", "/svc/Write": "account:write"}
	public := func(m string) bool { return m == "/grpc.health.v1.Health/Check" }
	icpt := UnaryServerInterceptor(v, scopes, public, slog.New(slog.NewTextHandler(io.Discard, nil)))

	call := func(method, authorization string) (string, error) {
		ctx := context.Background()
		if authorization != "" {
			ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("authorization", authorization))
		}
		resp, err := icpt(ctx, nil, &grpc.UnaryServerInfo{FullMethod: method}, func(ctx context.Context, _ any) (any, error) {
			c, _ := ClaimsFrom(ctx)
			return c.ClientID, nil
		})
		s, _ := resp.(string)
		return s, err
	}

	readOnly := sign(t, key, func(c *Claims) { c.Scopes = []string{"account:read"} })
	tests := []struct {
		name          string
		method        string
		authorization string
		want          codes.Code
	}{
		{"valid token and scope", "/svc/Write", "Bearer " + sign(t, key, nil), codes.OK},
		{"lower-case scheme", "/svc/Read", "bearer " + sign(t, key, nil), codes.OK},
		{"no token", "/svc/Read", "", codes.Unauthenticated},
		{"not a bearer token", "/svc/Read", "Basic dXNlcjpwYXNz", codes.Unauthenticated},
		{"garbage", "/svc/Read", "Bearer not-a-jwt", codes.Unauthenticated},
		{"expired", "/svc/Read", "Bearer " + sign(t, key, func(c *Claims) {
			c.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Hour))
		}), codes.Unauthenticated},
		{"no expiry", "/svc/Read", "Bearer " + sign(t, key, func(c *Claims) { c.ExpiresAt = nil }), codes.Unauthenticated},
		{"wrong issuer", "/svc/Read", "Bearer " + sign(t, key, func(c *Claims) { c.Issuer = "http://evil.test/" }), codes.Unauthenticated},
		{"signed by another key", "/svc/Read", "Bearer " + sign(t, other, nil), codes.Unauthenticated},
		{"wrong scope", "/svc/Write", "Bearer " + readOnly, codes.PermissionDenied},
		{"right scope", "/svc/Read", "Bearer " + readOnly, codes.OK},
		{"method without scope is closed", "/svc/New", "Bearer " + sign(t, key, nil), codes.PermissionDenied},
		{"public method needs no token", "/grpc.health.v1.Health/Check", "", codes.OK},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			client, err := call(tc.method, tc.authorization)
			if got := status.Code(err); got != tc.want {
				t.Fatalf("code = %s (%v), want %s", got, err, tc.want)
			}
			if tc.want == codes.OK && tc.method != "/grpc.health.v1.Health/Check" && client != "transfer-service" {
				t.Fatalf("claims in handler context: client_id = %q", client)
			}
		})
	}
}

func TestSigningAlgorithmIsPinned(t *testing.T) {
	v, _ := newTestVerifier(t)
	// HS256 signed with a guessable secret must not pass as RS256.
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, Claims{RegisteredClaims: jwt.RegisteredClaims{
		Issuer: testIssuer, ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}})
	tok.Header["kid"] = testKID
	s, _ := tok.SignedString([]byte("secret"))
	if _, err := v.Verify(s); err == nil {
		t.Fatal("HS256 token accepted")
	}
}
