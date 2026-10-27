// Package server exposes the ledger API: health, statistics the DR drills
// read, volume exports, and Prometheus metrics.
package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/exports"
	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/store"
)

// StatsReader reads table statistics.
type StatsReader interface {
	Ping(ctx context.Context) error
	Stats(ctx context.Context) (store.Stats, error)
}

// Exporter creates and lists export files on the data volume.
type Exporter interface {
	Create(ctx context.Context) (exports.File, error)
	List() ([]exports.File, error)
}

// Writer reports the state of the background writer.
type Writer interface {
	Ready() bool
	Last() (int64, time.Time)
}

// Server holds the HTTP dependencies.
type Server struct {
	DB       StatsReader
	Exports  Exporter
	Writer   Writer
	Gatherer prometheus.Gatherer
	Log      *slog.Logger
	Timeout  time.Duration
}

// StatsResponse is the body of GET /api/stats.
type StatsResponse struct {
	store.Stats
	LastAckSeq int64      `json:"last_ack_seq"`
	LastAckAt  *time.Time `json:"last_ack_at"`
	ServerTime time.Time  `json:"server_time"`
}

// Handler returns the routed HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("GET /api/stats", s.stats)
	mux.HandleFunc("GET /api/exports", s.listExports)
	mux.HandleFunc("POST /api/exports", s.createExport)
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.Gatherer, promhttp.HandlerOpts{}))
	return mux
}

// healthz is liveness: the process is up. It never touches the database, so a
// database outage or restore does not get the pod restarted in a loop.
func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz is readiness: the database answers and the writer is committing rows.
func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.Timeout)
	defer cancel()
	if err := s.DB.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "database unavailable", "error": err.Error()})
		return
	}
	if !s.Writer.Ready() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "writer not ready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) stats(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.Timeout)
	defer cancel()
	st, err := s.DB.Stats(ctx)
	if err != nil {
		s.Log.Warn("stats failed", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error()})
		return
	}
	resp := StatsResponse{Stats: st, ServerTime: time.Now().UTC()}
	seq, at := s.Writer.Last()
	resp.LastAckSeq = seq
	if !at.IsZero() {
		resp.LastAckAt = &at
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) listExports(w http.ResponseWriter, _ *http.Request) {
	files, err := s.Exports.List()
	if err != nil {
		s.Log.Warn("list exports failed", "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, files)
}

func (s *Server) createExport(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.Timeout)
	defer cancel()
	f, err := s.Exports.Create(ctx)
	if err != nil {
		s.Log.Warn("create export failed", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusCreated, f)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
