package main

import (
	"strings"
	"testing"
)

func TestCheckEndpointURL(t *testing.T) {
	for _, v := range []string{"http://localhost:14317", "https://collector.example:4317"} {
		if err := checkEndpointURL("OTEL_EXPORTER_OTLP_ENDPOINT", v); err != nil {
			t.Errorf("%q: %v", v, err)
		}
	}
	// No scheme, no host, no port: each would make the exporter send somewhere
	// else than intended.
	for _, v := range []string{"localhost:14317", "http://", "http://localhost", "https://collector.example", "ftp://localhost:14317"} {
		err := checkEndpointURL("OTEL_EXPORTER_OTLP_ENDPOINT", v)
		if err == nil || !strings.Contains(err.Error(), "OTEL_EXPORTER_OTLP_ENDPOINT") {
			t.Errorf("%q: err = %v, want an error naming OTEL_EXPORTER_OTLP_ENDPOINT", v, err)
		}
	}
}
