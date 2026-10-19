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
// hour after. A failed fetch is logged, not fatal: the service starts even
// while the authorization server is down, and only token checks fail until the
// keys arrive. A token signed with an unknown key ID (the
// authorization server rotated its keys, or restarted with in-memory storage)
// triggers a fresh download, at most once per 5 s so that garbage tokens
// cannot turn this service into a load generator against the JWKS endpoint.
// Hydra creates its access token key on the first token request, so right
// after startup this is the normal way the key arrives. ctx ends the
// background refresh.
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
			// Only the algorithm the authorization server uses. Accepting whatever
			// the token header says is how "alg: none" and RS/HS confusion attacks
			// get in.
			jwt.WithValidMethods([]string{"RS256"}),
			// Exact match, trailing slash included: a token from another
			// authorization server (or another environment) is not ours.
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
// audience per resource server and check it here, so a token meant for one
// service cannot be replayed against another.
func (v *Verifier) Verify(token string) (Claims, error) {
	var c Claims
	if _, err := v.parser.ParseWithClaims(token, &c, v.keys.Keyfunc); err != nil {
		return Claims{}, fmt.Errorf("%w: %w", ErrInvalidToken, err)
	}
	return c, nil
}
