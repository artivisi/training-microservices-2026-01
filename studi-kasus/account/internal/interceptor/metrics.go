package interceptor

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
)

// requestDuration is the gRPC counterpart of http_server_request_duration_seconds
// (Lab 8). The account service does its real work over gRPC: without this, a
// slow Debit would not show up in any latency metric of the account service.
// method is the full method name: a fixed set, defined by the proto contract.
var requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
	Name:    "grpc_server_request_duration_seconds",
	Help:    "Duration of unary gRPC calls handled by this service.",
	Buckets: prometheus.DefBuckets, // 5 ms .. 10 s
}, []string{"method", "code"})

// Metrics observes every unary call with its status code. It runs before auth
// and the fault injector, so rejected calls and injected delays are measured
// like the caller experiences them.
func Metrics() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		requestDuration.WithLabelValues(info.FullMethod, status.Code(err).String()).Observe(time.Since(start).Seconds())
		return resp, err
	}
}
