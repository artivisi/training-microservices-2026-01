package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/notification/internal/notification"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/notification/internal/telemetry"
)

func main() {
	// Until the configuration is read there is no collector address: startup
	// errors go to stdout only, as JSON like every later log line.
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("notification service stopped", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Lab 8: from here on, log lines also go to the collector (OTLP) and carry
	// correlation_id / trace_id when logged with a request or event context.
	tel, err := telemetry.Setup(ctx, cfg.OTelServiceName, cfg.OTelEndpoint)
	if err != nil {
		return err
	}
	// Deferred first, so it runs last: spans and logs of the shutdown itself
	// are flushed too.
	defer func(boot *slog.Logger) {
		flushCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tel.Shutdown(flushCtx); err != nil {
			boot.Warn("flushing telemetry failed", "error", err)
		}
	}(log)
	log = tel.Logger

	store, err := notification.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	mux := notification.NewHandler(store, log).Routes()
	// Lab 8: Prometheus pulls the metrics from here. Open like the probes;
	// production restricts it to the monitoring network.
	mux.Handle("GET /metrics", promhttp.Handler())
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           telemetry.HTTPHandler(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Close leaves the consumer group, so Kafka hands this instance's partitions
	// to the remaining members right away instead of after a session timeout.
	reader := notification.NewKafkaReader(cfg.KafkaBrokers, cfg.KafkaTopic, cfg.KafkaGroupID)
	defer reader.Close()
	consumerCtx, stopConsumer := context.WithCancel(context.Background())
	defer stopConsumer()

	errCh := make(chan error, 1)
	go func() {
		log.Info("notification service listening", "addr", cfg.HTTPAddr)
		errCh <- srv.ListenAndServe()
	}()
	consumerDone := make(chan struct{})
	go func() {
		defer close(consumerDone)
		log.Info("consuming events", "kafka_brokers", cfg.KafkaBrokers, "topic", cfg.KafkaTopic, "group", cfg.KafkaGroupID)
		notification.NewConsumer(reader, store, log).Run(consumerCtx)
	}()

	select {
	case err := <-errCh:
		stopConsumer()
		<-consumerDone
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		// The event in progress is cut off before its offset commit, so it comes
		// again on the next start: never lost, and skipped as a duplicate if its
		// insert went through.
		stopConsumer()
		<-consumerDone
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
