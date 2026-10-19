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
	"github.com/artivisi/training-microservices-2026-01/studi-kasus/account/internal/auth"
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

	// Lab 7: every AccountService call needs a JWT from the authorization
	// server. The account REST API on HTTP_ADDR stays open in this lab to keep
	// the setup steps (creating accounts) short; in production it gets the same
	// kind of middleware as the transfer REST API.
	verifier, err := auth.NewVerifier(ctx, cfg.OAuthIssuer, cfg.OAuthJWKSURL, log)
	if err != nil {
		return err
	}
	// Health and reflection are not AccountService: no token, no faults, like
	// the HTTP probes. Note the predicate opens every non-AccountService method,
	// not only those two, and auth is a unary interceptor only: see
	// auth.UnaryServerInterceptor before registering another service or a
	// streaming RPC.
	notAccountService := func(method string) bool {
		return !strings.HasPrefix(method, "/"+accountv1.AccountService_ServiceDesc.ServiceName+"/")
	}

	// gRPC: the internal API (GetAccount, Debit, Credit) for other services.
	// Interceptors run in the order given: logging sees the code that auth or the
	// fault injector produced, so rejections and injected failures show up in
	// the log like real ones. Auth comes before faults: a caller without a valid
	// token is turned away before any work, simulated or real, is done.
	grpcSrv := grpc.NewServer(grpc.ChainUnaryInterceptor(
		interceptor.Logging(log),
		auth.UnaryServerInterceptor(verifier, account.GRPCScopes, notAccountService, log),
		faults.UnaryServerInterceptor(notAccountService),
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
