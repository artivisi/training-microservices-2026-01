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

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/notification/internal/notification"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
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

	store, err := notification.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           notification.NewHandler(store, log).Routes(),
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
