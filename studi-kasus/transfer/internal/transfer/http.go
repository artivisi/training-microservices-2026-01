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

func (h *Handler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /transfers", h.create)
	mux.HandleFunc("GET /transfers/{id}", h.get)
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
	// WithoutCancel: a client that disconnects must not abort a transfer halfway,
	// e.g. between the debit and the credit.
	t, err := h.svc.Execute(context.WithoutCancel(r.Context()), req)
	switch {
	case err == nil:
		w.Header().Set("Location", "/transfers/"+t.ID)
		writeJSON(w, http.StatusCreated, t)
	case t.ID == "":
		h.internalError(w, r, err)
	case errors.Is(err, ErrCreditFailed):
		// Checked first: the debit was applied, so this must not look retryable
		// (503) or like a plain business rejection (422). A retried POST would
		// debit again. The service already logged it for manual reversal.
		writeJSON(w, http.StatusBadGateway, t)
	case errors.Is(err, ErrAccountNotFound), errors.Is(err, ErrInsufficientFunds):
		writeJSON(w, http.StatusUnprocessableEntity, t)
	case errors.Is(err, ErrAccountUnavailable):
		// The open breaker refused the debit, so nothing was applied: 503 tells the
		// caller it is safe to come back later.
		writeJSON(w, http.StatusServiceUnavailable, t)
	default:
		// Recorded but not completed because a dependency failed.
		writeJSON(w, http.StatusBadGateway, t)
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
