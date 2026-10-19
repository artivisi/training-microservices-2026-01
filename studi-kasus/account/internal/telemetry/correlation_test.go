package telemetry

import (
	"context"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

func TestUnaryServerCorrelation(t *testing.T) {
	tests := []struct {
		name string
		md   metadata.MD
		want string // "" = a generated ID
	}{
		{"from the caller's metadata", metadata.Pairs(CorrelationMetadataKey, "req-42"), "req-42"},
		{"generated when absent", metadata.MD{}, ""},
		{"replaced when invalid", metadata.Pairs(CorrelationMetadataKey, "bad id with spaces"), ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ctx := metadata.NewIncomingContext(context.Background(), tc.md)
			var seen string
			_, err := UnaryServerCorrelation()(ctx, nil, &grpc.UnaryServerInfo{FullMethod: "/account.v1.AccountService/Debit"},
				func(ctx context.Context, _ any) (any, error) {
					seen = CorrelationID(ctx)
					return nil, nil
				})
			if err != nil {
				t.Fatal(err)
			}
			if seen == "" || (tc.want != "" && seen != tc.want) || (tc.want == "" && seen == "bad id with spaces") {
				t.Fatalf("correlation ID = %q, want %q", seen, tc.want)
			}
		})
	}
}
