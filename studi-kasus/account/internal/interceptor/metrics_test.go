package interceptor

import (
	"context"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestMetricsRecordsMethodAndCode(t *testing.T) {
	info := &grpc.UnaryServerInfo{FullMethod: "/account.v1.AccountService/Debit"}
	_, _ = Metrics()(context.Background(), nil, info, func(context.Context, any) (any, error) {
		return nil, status.Error(codes.FailedPrecondition, "insufficient funds")
	})
	_, _ = Metrics()(context.Background(), nil, info, func(context.Context, any) (any, error) { return "ok", nil })

	// One series per method and code.
	if got := testutil.CollectAndCount(requestDuration); got != 2 {
		t.Fatalf("series = %d, want 2", got)
	}
}
