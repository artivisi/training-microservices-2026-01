package account

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"
)

type Handler struct {
	store Store
	log   *slog.Logger
}

func NewHandler(store Store, log *slog.Logger) *Handler {
	return &Handler{store: store, log: log}
}

// Routes uses the Go 1.22+ ServeMux patterns: method + path, with {wildcards}.
func (h *Handler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /accounts", h.create)
	mux.HandleFunc("GET /accounts", h.list)
	mux.HandleFunc("GET /accounts/{number}", h.get)
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	return mux
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req CreateRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return
	}
	if err := req.Validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "fields": err})
		return
	}
	a, err := h.store.Create(r.Context(), req)
	switch {
	case errors.Is(err, ErrAlreadyExists):
		writeError(w, http.StatusConflict, err.Error())
	case err != nil:
		h.internalError(w, r, err)
	default:
		w.Header().Set("Location", "/accounts/"+a.Number)
		writeJSON(w, http.StatusCreated, a)
	}
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	a, err := h.store.Get(r.Context(), r.PathValue("number"))
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case err != nil:
		h.internalError(w, r, err)
	default:
		writeJSON(w, http.StatusOK, a)
	}
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	accounts, err := h.store.List(r.Context())
	if err != nil {
		h.internalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, accounts)
}

// healthz (liveness): the process is up and serving HTTP. No dependency checks here,
// otherwise a database outage makes Kubernetes restart every healthy pod.
func (h *Handler) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
}

// readyz (readiness): the service can do useful work, i.e. the database answers.
func (h *Handler) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.store.Ping(ctx); err != nil {
		// Connection details stay in the log; callers only learn that the database is down.
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

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
