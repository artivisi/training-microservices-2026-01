package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/account"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/fault"
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/interceptor"
	accountv1 "github.com/artivisi/training-microservices-2026-01/studi-kasus/proto/gen/account/v1"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("account service stopped", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}

	// ctx is cancelled on Ctrl+C (SIGINT) or on SIGTERM from Docker/Kubernetes.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	store, err := account.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	// Faults apply to the account API only; probes and the admin endpoints stay fast.
	faults := fault.NewInjector(log)
	api := account.NewHandler(store, log).Routes()
	mux := http.NewServeMux()
	mux.Handle("/accounts", faults.Wrap(api))
	mux.Handle("/accounts/", faults.Wrap(api))
	mux.Handle("/", api)
	faults.Register(mux)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// gRPC: the internal API (GetAccount, Debit, Credit) for other services.
	// Interceptors run in the order given: logging sees the code that the fault
	// injector produced, so injected failures show up in the log like real ones.
	// Health and reflection are excluded from faults, like the HTTP probes.
	grpcSrv := grpc.NewServer(grpc.ChainUnaryInterceptor(
		interceptor.Logging(log),
		faults.UnaryServerInterceptor(func(method string) bool {
			return !strings.HasPrefix(method, "/"+accountv1.AccountService_ServiceDesc.ServiceName+"/")
		}),
	))
	accountv1.RegisterAccountServiceServer(grpcSrv, account.NewGRPCServer(store, log))
	// Standard health protocol (grpc.health.v1): grpcurl and grpc-health-probe
	// understand it without custom code. It is NOT tied to the database: the
	// status is SERVING from startup until shutdown, so it only says "this process
	// accepts gRPC calls". Pod readiness is the HTTP /readyz, which pings the
	// database; do not replace it with a gRPC readinessProbe, which would report
	// ready while the database is down.
	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(grpcSrv, healthSrv)
	healthSrv.SetServingStatus(accountv1.AccountService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	// Reflection lets grpcurl / Postman list services and methods without the
	// .proto file. Handy in the lab; many teams switch it off in production.
	reflection.Register(grpcSrv)

	lis, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		return fmt.Errorf("listen on GRPC_ADDR %s: %w", cfg.GRPCAddr, err)
	}

	errCh := make(chan error, 2)
	go func() {
		log.Info("account service listening", "protocol", "http", "addr", cfg.HTTPAddr)
		errCh <- srv.ListenAndServe()
	}()
	go func() {
		log.Info("account service listening", "protocol", "grpc", "addr", cfg.GRPCAddr)
		errCh <- grpcSrv.Serve(lis)
	}()

	select {
	case err := <-errCh:
		srv.Close()
		grpcSrv.Stop()
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		// NOT_SERVING first, so health checkers stop routing new calls here
		// while in-flight ones finish.
		healthSrv.Shutdown()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		grpcDone := make(chan struct{})
		go func() {
			grpcSrv.GracefulStop()
			close(grpcDone)
		}()
		httpErr := srv.Shutdown(shutdownCtx)
		select {
		case <-grpcDone:
		case <-shutdownCtx.Done():
			// Same 10 s budget as HTTP: calls still running now are cut off.
			grpcSrv.Stop()
		}
		if httpErr != nil && !errors.Is(httpErr, http.ErrServerClosed) {
			return httpErr
		}
		return nil
	}
}
