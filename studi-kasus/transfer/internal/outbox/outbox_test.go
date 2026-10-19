package outbox

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// The relay publishes long after the request ended, from its own goroutine.
// The trace must still continue: the stored trace context becomes the parent of
// the publish span, and the publish span's context goes into the headers.
func TestMessageContinuesTheRequestTrace(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder)))
	otel.SetTextMapPropagator(propagation.TraceContext{})

	// What Insert stored while handling POST /transfers.
	reqCtx, reqSpan := otel.Tracer("test").Start(context.Background(), "POST /transfers")
	stored := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(reqCtx, stored)
	reqSpan.End()

	r := NewRelay(nil, nil, "transfer-events", slog.New(slog.NewTextHandler(io.Discard, nil)))
	msg, span := r.message(context.Background(), Message{
		ID: "e1", AggregateID: "t1", EventType: "TransferCompleted", Payload: []byte(`{}`),
		CorrelationID: "req-1", TraceContext: stored,
	})
	span.End()

	headers := map[string]string{}
	for _, h := range msg.Headers {
		headers[h.Key] = string(h.Value)
	}
	if headers["event_type"] != "TransferCompleted" || headers["event_id"] != "e1" || headers["correlation_id"] != "req-1" {
		t.Fatalf("headers = %v", headers)
	}

	spans := recorder.Ended()
	publish := spans[len(spans)-1]
	if publish.Name() != "publish transfer-events" || publish.SpanKind() != trace.SpanKindProducer {
		t.Fatalf("span = %s (%s)", publish.Name(), publish.SpanKind())
	}
	if publish.Parent().SpanID() != reqSpan.SpanContext().SpanID() {
		t.Fatal("publish span is not a child of the request span")
	}
	// traceparent = 00-<trace id>-<span id>-<flags>: same trace, publish span as parent.
	want := "00-" + reqSpan.SpanContext().TraceID().String() + "-" + publish.SpanContext().SpanID().String()
	if !strings.HasPrefix(headers["traceparent"], want) {
		t.Fatalf("traceparent = %q, want prefix %q", headers["traceparent"], want)
	}
}
