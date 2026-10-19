package notification

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// The consumer span continues the transfer's trace from the traceparent header
// the outbox relay wrote, and the metric counts sent and duplicate events.
func TestConsumerContinuesTraceAndCounts(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder)))
	otel.SetTextMapPropagator(propagation.TraceContext{})

	const traceID, parentSpanID = "4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"
	m := event(1, "TransferCompleted", eventID1)
	m.Topic = "transfer-events"
	m.Headers = append(m.Headers,
		kafka.Header{Key: "traceparent", Value: []byte("00-" + traceID + "-" + parentSpanID + "-01")},
		kafka.Header{Key: "correlation_id", Value: []byte("req-1")})

	sent := testutil.ToFloat64(processed.WithLabelValues("sent"))
	duplicate := testutil.ToFloat64(processed.WithLabelValues("duplicate"))
	runConsumer(t, &fakeStore{}, m, m) // the same event twice: sent, then duplicate

	if got := testutil.ToFloat64(processed.WithLabelValues("sent")); got != sent+1 {
		t.Fatalf("sent = %v, want %v", got, sent+1)
	}
	if got := testutil.ToFloat64(processed.WithLabelValues("duplicate")); got != duplicate+1 {
		t.Fatalf("duplicate = %v, want %v", got, duplicate+1)
	}

	spans := recorder.Ended()
	if len(spans) != 2 {
		t.Fatalf("spans = %d, want 2", len(spans))
	}
	for _, s := range spans {
		if s.Name() != "process transfer-events" || s.SpanKind() != trace.SpanKindConsumer {
			t.Fatalf("span = %s (%s)", s.Name(), s.SpanKind())
		}
		if s.SpanContext().TraceID().String() != traceID || s.Parent().SpanID().String() != parentSpanID {
			t.Fatalf("span %s is not in the producer's trace: parent %s", s.SpanContext().TraceID(), s.Parent().SpanID())
		}
	}
}
