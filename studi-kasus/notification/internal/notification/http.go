package notification

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type Handler struct {
	store Store
	log   *slog.Logger
}

func NewHandler(store Store, log *slog.Logger) *Handler {
	return &Handler{store: store, log: log}
}

func (h *Handler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /notifications", h.list)
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	return mux
}

// list answers GET /notifications?transfer_id=... The filter is required: an
// unfiltered list of every customer's notifications is not something a channel
// should be able to ask for.
func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	transferID := r.URL.Query().Get("transfer_id")
	if _, err := uuid.Parse(transferID); err != nil {
		writeError(w, http.StatusBadRequest, "query parameter transfer_id must be a transfer ID (UUID)")
		return
	}
	ns, err := h.store.ListByTransfer(r.Context(), transferID)
	if err != nil {
		h.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if ns == nil {
		ns = []Notification{} // [] in JSON, not null
	}
	writeJSON(w, http.StatusOK, ns)
}

func (h *Handler) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
}

// readyz checks the database only. Kafka is not checked: while it is down the
// consumer simply waits, and the HTTP API can still answer from the database.
func (h *Handler) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.store.Ping(ctx); err != nil {
		h.log.Warn("readiness check failed", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "DOWN", "database": "DOWN"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP", "database": "UP"})
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
