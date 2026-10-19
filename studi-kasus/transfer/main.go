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
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

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

	errCh := make(chan error, 1)
	go func() {
		log.Info("transfer service listening", "addr", cfg.HTTPAddr, "account_grpc", cfg.AccountGRPCAddr)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
