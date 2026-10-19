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
