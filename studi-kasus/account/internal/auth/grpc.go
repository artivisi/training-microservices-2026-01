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
