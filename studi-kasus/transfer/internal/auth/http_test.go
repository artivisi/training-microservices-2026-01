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
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
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
			Subject:   "channel-app",
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
		},
		ClientID: "channel-app",
		Scopes:   []string{"transfer:read", "transfer:write"},
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

func TestRequire(t *testing.T) {
	v, key := newTestVerifier(t)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	m := NewMiddleware(v, slog.New(slog.NewTextHandler(io.Discard, nil)))
	h := m.Require("transfer:write", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, _ := ClaimsFrom(r.Context())
		_, _ = io.WriteString(w, c.ClientID)
	}))

	tests := []struct {
		name          string
		authorization string
		wantStatus    int
		wantBody      string
		wantChallenge string
	}{
		{"valid", "Bearer " + sign(t, key, nil), http.StatusOK, "channel-app", ""},
		{"no token", "", http.StatusUnauthorized, "missing bearer token", "Bearer"},
		{"basic auth", "Basic dXNlcjpwYXNz", http.StatusUnauthorized, "missing bearer token", "Bearer"},
		{"expired", "Bearer " + sign(t, key, func(c *Claims) {
			c.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Hour))
		}), http.StatusUnauthorized, "invalid token", `error="invalid_token"`},
		{"wrong issuer", "Bearer " + sign(t, key, func(c *Claims) { c.Issuer = "http://evil.test/" }),
			http.StatusUnauthorized, "invalid token", `error="invalid_token"`},
		{"signed by another key", "Bearer " + sign(t, other, nil),
			http.StatusUnauthorized, "invalid token", `error="invalid_token"`},
		{"wrong scope", "Bearer " + sign(t, key, func(c *Claims) { c.Scopes = []string{"transfer:read"} }),
			http.StatusForbidden, "scope transfer:write required", `error="insufficient_scope"`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/transfers", nil)
			if tc.authorization != "" {
				req.Header.Set("Authorization", tc.authorization)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus || !strings.Contains(rec.Body.String(), tc.wantBody) {
				t.Fatalf("%d %s, want %d containing %q", rec.Code, rec.Body, tc.wantStatus, tc.wantBody)
			}
			if got := rec.Header().Get("WWW-Authenticate"); !strings.Contains(got, tc.wantChallenge) {
				t.Fatalf("WWW-Authenticate = %q, want %q", got, tc.wantChallenge)
			}
			if tc.wantStatus != http.StatusOK && rec.Header().Get("Content-Type") != "application/json" {
				t.Fatalf("error body is not JSON")
			}
		})
	}
}
