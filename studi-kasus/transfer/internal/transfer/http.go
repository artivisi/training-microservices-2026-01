package transfer

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"
)

type Handler struct {
	svc *Service
	log *slog.Logger
}

func NewHandler(svc *Service, log *slog.Logger) *Handler {
	return &Handler{svc: svc, log: log}
}

// OAuth2 scopes of the transfer REST API (Lab 7). The channel app that only
// shows transfer status gets read; moving money needs write.
const (
	ScopeRead  = "transfer:read"
	ScopeWrite = "transfer:write"
)

// RequireScope wraps next so it runs only for a caller whose token carries
// scope. The transfer package defines the shape; main plugs in the JWT
// middleware, tests plug in a pass-through.
type RequireScope func(scope string, next http.Handler) http.Handler

// Routes registers the API behind requireScope. Probes stay open: the kubelet
// and load balancers call them without a token.
func (h *Handler) Routes(requireScope RequireScope) *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("POST /transfers", requireScope(ScopeWrite, http.HandlerFunc(h.create)))
	mux.Handle("GET /transfers/{id}", requireScope(ScopeRead, http.HandlerFunc(h.get)))
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	return mux
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req CreateRequest
	if !decode(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "fields": err})
		return
	}
	// Optional here so the requests of Labs 2-5 keep working. A channel-facing
	// payment API in production makes it required: without it, a client that
	// retries after a lost response cannot tell whether it pays twice.
	key := r.Header.Get("Idempotency-Key")
	if key != "" {
		if err := ValidateIdempotencyKey(key); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "fields": err})
			return
		}
	}
	// WithoutCancel: a client that disconnects must not abort a transfer halfway,
	// e.g. between the debit and the credit.
	t, replayed, err := h.svc.Execute(context.WithoutCancel(r.Context()), req, key)
	switch {
	case errors.Is(err, ErrIdempotencyKeyReused):
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	case t.ID == "":
		h.internalError(w, r, err)
		return
	}
	if replayed {
		// A replay answers with the status code the original request got for the
		// stored state, so a client whose first response was lost decides the same
		// way. The header tells it nothing was executed this time.
		w.Header().Set("Idempotent-Replayed", "true")
	}
	status := createStatus(err)
	if status == http.StatusCreated || status == http.StatusAccepted {
		w.Header().Set("Location", "/transfers/"+t.ID)
	}
	writeJSON(w, status, t)
}

// createStatus maps the outcome of a recorded transfer to the HTTP status of
// POST /transfers, for a first request and a replay alike.
func createStatus(err error) int {
	switch {
	case err == nil:
		return http.StatusCreated
	case errors.Is(err, ErrInProgress):
		// Replay only: the original request is still running (or was cut off by a
		// crash, see Service.Execute).
		return http.StatusAccepted
	case errors.Is(err, ErrReversalFailed):
		// Checked first: the source account is debited and the reversal did not go
		// through (COMPENSATION_FAILED, also when that state itself could not be
		// stored). Money is stuck on our side, whatever the account service
		// answered: this is our failure, not the caller's, and never a 503 or 422
		// that would invite a retry.
		return http.StatusInternalServerError
	case errors.Is(err, ErrAccountNotFound), errors.Is(err, ErrInsufficientFunds):
		// Includes COMPENSATED when the destination account does not exist.
		return http.StatusUnprocessableEntity
	case errors.Is(err, ErrAccountUnavailable):
		// The open breaker refused the debit (FAILED), or refused the credit and the
		// debit was reversed (COMPENSATED). Either way no money moved: 503 tells the
		// caller it is safe to come back later.
		return http.StatusServiceUnavailable
	default:
		// Recorded but not completed because a dependency failed (FAILED or
		// COMPENSATED).
		return http.StatusBadGateway
	}
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	t, err := h.svc.Get(r.Context(), r.PathValue("id"))
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case err != nil:
		h.internalError(w, r, err)
	default:
		writeJSON(w, http.StatusOK, t)
	}
}

func (h *Handler) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
}

// readyz checks only this service's own database. The account service is a
// dependency with its own probes; failing here when it is down would take the
// transfer service out of rotation for an outage it cannot fix.
func (h *Handler) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.svc.Ping(ctx); err != nil {
		h.log.Warn("readiness check failed", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "DOWN", "database": "DOWN"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP", "database": "UP"})
}

func (h *Handler) internalError(w http.ResponseWriter, r *http.Request, err error) {
	h.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}

// decode reads a JSON body into dst and answers 400 itself when the body is invalid.
func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	return true
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
