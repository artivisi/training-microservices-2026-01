package main

import (
	"fmt"
	"net/url"
	"os"
	"strings"
)

// Config comes from environment variables only (12-factor). Every variable is
// required: a missing value stops the service at startup instead of running
// with a guessed default.
type Config struct {
	HTTPAddr    string
	DatabaseURL string
	// KafkaBrokers is a comma-separated list of host:port.
	KafkaBrokers []string
	KafkaTopic   string
	// KafkaGroupID is the consumer group. Kafka keeps the committed offsets per
	// group; every instance of this service uses the same group, so each event is
	// handled by one of them.
	KafkaGroupID string
	// Lab 8: the OpenTelemetry collector's OTLP gRPC endpoint as a URL
	// (http://localhost:14317) and the name the traces and logs carry. Both use
	// the standard OpenTelemetry variable names, so the same values work for
	// any OpenTelemetry SDK.
	OTelEndpoint    string
	OTelServiceName string
}

func LoadConfig() (Config, error) {
	var missing []string
	get := func(name string) string {
		v := os.Getenv(name)
		if v == "" {
			missing = append(missing, name)
		}
		return v
	}
	cfg := Config{
		HTTPAddr:        get("HTTP_ADDR"),
		DatabaseURL:     get("DATABASE_URL"),
		KafkaBrokers:    strings.Split(get("KAFKA_BROKERS"), ","),
		KafkaTopic:      get("KAFKA_TOPIC"),
		KafkaGroupID:    get("KAFKA_GROUP_ID"),
		OTelEndpoint:    get("OTEL_EXPORTER_OTLP_ENDPOINT"),
		OTelServiceName: get("OTEL_SERVICE_NAME"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	if err := checkEndpointURL("OTEL_EXPORTER_OTLP_ENDPOINT", cfg.OTelEndpoint); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// checkEndpointURL rejects anything but scheme://host:port. The OTLP exporter
// would otherwise ignore a malformed value and silently send to its built-in
// default address. The port is required too: without it gRPC dials port 443,
// and http://localhost (no port) would fail on every export, not at startup.
func checkEndpointURL(name, v string) error {
	u, err := url.Parse(v)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
		return fmt.Errorf("%s must be a URL like http://localhost:14317, got %q", name, v)
	}
	if u.Port() == "" {
		return fmt.Errorf("%s must name the port explicitly, like http://localhost:14317, got %q", name, v)
	}
	return nil
}
