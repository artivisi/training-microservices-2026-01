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

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/accountclient"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/outbox"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

// shutdownGrace is how long the HTTP server waits on SIGTERM for transfers in
// flight. A saga cut mid-way leaves a PENDING or DEBITED row that nothing
// resumes (see README), so the wait covers the worst case of one saga under
// accountclient.ProductionSettings:
//
//	debit    4 attempts x 2 s + 3 backoffs x 1.25 s  = 11.75 s
//	credit   same                                    = 11.75 s
//	reversal 30 s retry window + one last 2 s attempt = 32 s
//	                                                    55.5 s
//
// plus a few seconds for the database writes in between. TestShutdownGrace
// fails when the policies grow past it. The platform must give the process at
// least this long before SIGKILL (Kubernetes: terminationGracePeriodSeconds).
const shutdownGrace = 60 * time.Second

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("transfer service stopped", "error", err)
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

	store, err := transfer.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	accounts, err := accountclient.New(cfg.AccountGRPCAddr, accountclient.ProductionSettings, log)
	if err != nil {
		return err
	}
	defer accounts.Close()
	svc := transfer.NewService(store, accounts, log)
	mux := transfer.NewHandler(svc, log).Routes()
	mux.HandleFunc("GET /debug/circuit-breaker", accounts.ServeCircuitBreaker)
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// The relay connects lazily too: the service starts and accepts transfers
	// while Kafka is down; events wait in the outbox until it is back.
	writer := outbox.NewKafkaWriter(cfg.KafkaBrokers, cfg.KafkaTopic)
	defer writer.Close()
	relayCtx, stopRelay := context.WithCancel(context.Background())
	relayDone := make(chan struct{})
	go func() {
		outbox.NewRelay(store.Pool(), writer, log).Run(relayCtx)
		close(relayDone)
	}()
	// Runs before the deferred store.Close: the relay must stop using the pool first.
	defer func() {
		stopRelay()
		<-relayDone
	}()

	errCh := make(chan error, 1)
	go func() {
		log.Info("transfer service listening", "addr", cfg.HTTPAddr, "account_grpc", cfg.AccountGRPCAddr,
			"kafka_brokers", cfg.KafkaBrokers, "kafka_topic", cfg.KafkaTopic)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()
		// HTTP first: transfers in flight finish and write their outbox rows; the
		// deferred relay stop comes after, and anything left is published by the
		// next start.
		if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
