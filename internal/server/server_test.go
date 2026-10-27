package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/exports"
	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/store"
)

type fakeDB struct {
	pingErr  error
	statsErr error
	stats    store.Stats
}

func (f *fakeDB) Ping(context.Context) error { return f.pingErr }
func (f *fakeDB) Stats(context.Context) (store.Stats, error) {
	return f.stats, f.statsErr
}

type fakeExports struct {
	files     []exports.File
	listErr   error
	createErr error
}

func (f *fakeExports) Create(context.Context) (exports.File, error) {
	if f.createErr != nil {
		return exports.File{}, f.createErr
	}
	return exports.File{Name: "export-1.csv", SHA256: "abc", Rows: 3}, nil
}
func (f *fakeExports) List() ([]exports.File, error) { return f.files, f.listErr }

type fakeWriter struct {
	ready bool
	seq   int64
	at    time.Time
}

func (f *fakeWriter) Ready() bool              { return f.ready }
func (f *fakeWriter) Last() (int64, time.Time) { return f.seq, f.at }

func newServer(db *fakeDB, ex *fakeExports, wr *fakeWriter) http.Handler {
	reg := prometheus.NewRegistry()
	reg.MustRegister(prometheus.NewCounter(prometheus.CounterOpts{Name: "test_total", Help: "t"}))
	s := &Server{
		DB: db, Exports: ex, Writer: wr, Gatherer: reg,
		Log:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		Timeout: time.Second,
	}
	return s.Handler()
}

func do(t *testing.T, h http.Handler, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequestWithContext(context.Background(), method, path, http.NoBody)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestHealthzIgnoresDatabase(t *testing.T) {
	h := newServer(&fakeDB{pingErr: errors.New("down")}, &fakeExports{}, &fakeWriter{})
	if rec := do(t, h, http.MethodGet, "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("healthz = %d", rec.Code)
	}
}

func TestReadyz(t *testing.T) {
	cases := []struct {
		name string
		db   *fakeDB
		wr   *fakeWriter
		want int
	}{
		{"ready", &fakeDB{}, &fakeWriter{ready: true}, http.StatusOK},
		{"database down", &fakeDB{pingErr: errors.New("refused")}, &fakeWriter{ready: true}, http.StatusServiceUnavailable},
		{"writer failing", &fakeDB{}, &fakeWriter{ready: false}, http.StatusServiceUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, newServer(tc.db, &fakeExports{}, tc.wr), http.MethodGet, "/readyz")
			if rec.Code != tc.want {
				t.Fatalf("code = %d, want %d (%s)", rec.Code, tc.want, rec.Body)
			}
		})
	}
}

func TestStats(t *testing.T) {
	last := time.Date(2026, 10, 1, 0, 0, 1, 0, time.UTC)
	db := &fakeDB{stats: store.Stats{Rows: 10, MaxSeq: 12, LastAt: &last}}
	wr := &fakeWriter{ready: true, seq: 12, at: last}
	rec := do(t, newServer(db, &fakeExports{}, wr), http.MethodGet, "/api/stats")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
	var got StatsResponse
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Rows != 10 || got.MaxSeq != 12 || got.LastAckSeq != 12 || got.LastAckAt == nil || !got.LastAckAt.Equal(last) {
		t.Fatalf("unexpected stats: %+v", got)
	}
	if got.ServerTime.IsZero() {
		t.Fatal("server_time missing")
	}
}

func TestStatsBeforeFirstWrite(t *testing.T) {
	rec := do(t, newServer(&fakeDB{}, &fakeExports{}, &fakeWriter{}), http.MethodGet, "/api/stats")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"last_ack_at":null`) {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body)
	}
}

func TestStatsDatabaseError(t *testing.T) {
	rec := do(t, newServer(&fakeDB{statsErr: errors.New("boom")}, &fakeExports{}, &fakeWriter{}), http.MethodGet, "/api/stats")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("code = %d", rec.Code)
	}
}

func TestExports(t *testing.T) {
	ex := &fakeExports{files: []exports.File{{Name: "export-1.csv", SHA256: "abc"}}}
	h := newServer(&fakeDB{}, ex, &fakeWriter{})

	rec := do(t, h, http.MethodPost, "/api/exports")
	if rec.Code != http.StatusCreated || !strings.Contains(rec.Body.String(), `"sha256":"abc"`) {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	rec = do(t, h, http.MethodGet, "/api/exports")
	var files []exports.File
	if err := json.NewDecoder(rec.Body).Decode(&files); err != nil || len(files) != 1 {
		t.Fatalf("list: %v %+v", err, files)
	}
}

func TestExportErrors(t *testing.T) {
	ex := &fakeExports{listErr: errors.New("io"), createErr: errors.New("db")}
	h := newServer(&fakeDB{}, ex, &fakeWriter{})
	if rec := do(t, h, http.MethodPost, "/api/exports"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("create code = %d", rec.Code)
	}
	if rec := do(t, h, http.MethodGet, "/api/exports"); rec.Code != http.StatusInternalServerError {
		t.Fatalf("list code = %d", rec.Code)
	}
}

func TestMetricsAndMethodRouting(t *testing.T) {
	h := newServer(&fakeDB{}, &fakeExports{}, &fakeWriter{})
	rec := do(t, h, http.MethodGet, "/metrics")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "test_total") {
		t.Fatalf("metrics: %d", rec.Code)
	}
	if rec := do(t, h, http.MethodDelete, "/api/exports"); rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("DELETE /api/exports = %d", rec.Code)
	}
}
