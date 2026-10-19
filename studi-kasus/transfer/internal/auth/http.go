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
			m.log.WarnContext(r.Context(), "request rejected", "method", r.Method, "path", r.URL.Path, "error", ErrNoToken)
			w.Header().Set("WWW-Authenticate", `Bearer`)
			writeError(w, http.StatusUnauthorized, ErrNoToken.Error())
			return
		}
		claims, err := m.v.Verify(token)
		if err != nil {
			// Detail (expired, wrong issuer, bad signature) only in our log.
			m.log.WarnContext(r.Context(), "request rejected", "method", r.Method, "path", r.URL.Path, "error", err)
			w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
			writeError(w, http.StatusUnauthorized, ErrInvalidToken.Error())
			return
		}
		if !claims.HasScope(scope) {
			m.log.WarnContext(r.Context(), "request rejected", "method", r.Method, "path", r.URL.Path, "client_id", claims.ClientID,
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
