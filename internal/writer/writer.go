// Package writer produces the steady stream of timestamped rows that the
// disaster-recovery drills measure data loss against.
package writer

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/store"
)

// Inserter writes one event.
type Inserter interface {
	Insert(ctx context.Context, writer string) (store.Event, error)
}

// Migrator prepares the schema. It is retried until it succeeds, so the
// writer can start before the database has been restored.
type Migrator interface {
	Migrate(ctx context.Context) error
}

// Store is what the writer needs from the database.
type Store interface {
	Inserter
	Migrator
}

// Writer inserts one row per interval and remembers the last acknowledged write.
type Writer struct {
	store    Store
	name     string
	interval time.Duration
	timeout  time.Duration
	log      *slog.Logger

	migrated atomic.Bool
	lastSeq  atomic.Int64
	lastAt   atomic.Int64 // unix nanoseconds of the last committed row
	failing  atomic.Bool

	writes   *prometheus.CounterVec
	lastSeen prometheus.Gauge
}

// New returns a Writer and registers its metrics on reg.
func New(s Store, name string, interval time.Duration, log *slog.Logger, reg prometheus.Registerer) *Writer {
	w := &Writer{
		store:    s,
		name:     name,
		interval: interval,
		timeout:  2 * time.Second,
		log:      log,
		writes: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "ledger_writes_total",
			Help: "Rows the writer tried to insert, by result.",
		}, []string{"result"}),
		lastSeen: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "ledger_last_write_timestamp_seconds",
			Help: "Commit time of the last row the database acknowledged.",
		}),
	}
	reg.MustRegister(w.writes, w.lastSeen)
	return w
}

// Run writes until ctx is cancelled.
func (w *Writer) Run(ctx context.Context) {
	t := time.NewTicker(w.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.Tick(ctx)
		}
	}
}

// Tick performs one write attempt. It is exported for tests.
func (w *Writer) Tick(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, w.timeout)
	defer cancel()

	if !w.migrated.Load() {
		if err := w.store.Migrate(ctx); err != nil {
			w.fail(err)
			return
		}
		w.migrated.Store(true)
	}

	ev, err := w.store.Insert(ctx, w.name)
	if err != nil {
		w.fail(err)
		return
	}
	w.writes.WithLabelValues("ok").Inc()
	w.lastSeq.Store(ev.Seq)
	w.lastAt.Store(ev.CreatedAt.UnixNano())
	w.lastSeen.Set(float64(ev.CreatedAt.UnixNano()) / 1e9)
	if w.failing.CompareAndSwap(true, false) {
		w.log.Info("writes recovered", "seq", ev.Seq)
	}
}

// fail records a failed write and logs only on the healthy-to-failing edge,
// so an outage produces one log line instead of ten per second.
func (w *Writer) fail(err error) {
	w.writes.WithLabelValues("error").Inc()
	if w.failing.CompareAndSwap(false, true) {
		w.log.Warn("writes failing", "err", err)
	}
}

// Ready reports whether the schema exists and the writer is not failing.
func (w *Writer) Ready() bool { return w.migrated.Load() && !w.failing.Load() }

// Last returns the last acknowledged sequence number and its commit time.
// The time is zero when nothing has been written yet.
func (w *Writer) Last() (int64, time.Time) {
	at := w.lastAt.Load()
	if at == 0 {
		return 0, time.Time{}
	}
	return w.lastSeq.Load(), time.Unix(0, at).UTC()
}
