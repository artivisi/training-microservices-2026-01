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
