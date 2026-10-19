package telemetry

import (
	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel/propagation"
)

// KafkaHeaders lets the OpenTelemetry propagator write the trace context
// (traceparent, tracestate) into Kafka message headers, the way otelhttp and
// otelgrpc write it into HTTP headers and gRPC metadata. kafka-go has no
// OpenTelemetry instrumentation of its own.
type KafkaHeaders struct {
	Headers *[]kafka.Header
}

var _ propagation.TextMapCarrier = KafkaHeaders{}

func (c KafkaHeaders) Get(key string) string {
	for _, h := range *c.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}

func (c KafkaHeaders) Set(key, value string) {
	for i, h := range *c.Headers {
		if h.Key == key {
			(*c.Headers)[i].Value = []byte(value)
			return
		}
	}
	*c.Headers = append(*c.Headers, kafka.Header{Key: key, Value: []byte(value)})
}

func (c KafkaHeaders) Keys() []string {
	keys := make([]string, len(*c.Headers))
	for i, h := range *c.Headers {
		keys[i] = h.Key
	}
	return keys
}
