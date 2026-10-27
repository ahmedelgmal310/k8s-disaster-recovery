package writer

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/store"
)

type fakeStore struct {
	mu         sync.Mutex
	migrateErr error
	insertErr  error
	seq        int64
	migrations int
}

func (f *fakeStore) Migrate(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.migrations++
	return f.migrateErr
}

func (f *fakeStore) Insert(_ context.Context, w string) (store.Event, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.insertErr != nil {
		return store.Event{}, f.insertErr
	}
	f.seq++
	return store.Event{Seq: f.seq, CreatedAt: time.Unix(1700000000, f.seq), Writer: w}, nil
}

func (f *fakeStore) set(migrateErr, insertErr error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.migrateErr, f.insertErr = migrateErr, insertErr
}

func newTest(s Store) (*Writer, *prometheus.Registry) {
	reg := prometheus.NewRegistry()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return New(s, "pod-a", time.Millisecond, log, reg), reg
}

func TestTickRecordsAcknowledgedWrite(t *testing.T) {
	fs := &fakeStore{}
	w, _ := newTest(fs)

	if seq, at := w.Last(); seq != 0 || !at.IsZero() {
		t.Fatalf("expected no writes yet, got %d %v", seq, at)
	}
	w.Tick(context.Background())
	w.Tick(context.Background())

	seq, at := w.Last()
	if seq != 2 {
		t.Fatalf("seq = %d, want 2", seq)
	}
	if !at.Equal(time.Unix(1700000000, 2)) {
		t.Fatalf("at = %v", at)
	}
	if !w.Ready() {
		t.Fatal("writer should be ready")
	}
	if got := testutil.ToFloat64(w.writes.WithLabelValues("ok")); got != 2 {
		t.Fatalf("ok writes = %v", got)
	}
	if fs.migrations != 1 {
		t.Fatalf("migrations = %d, want 1 (schema is created once)", fs.migrations)
	}
}

func TestMigrationRetriedUntilDatabaseIsBack(t *testing.T) {
	fs := &fakeStore{}
	fs.set(errors.New("connection refused"), nil)
	w, _ := newTest(fs)

	w.Tick(context.Background())
	w.Tick(context.Background())
	if w.Ready() {
		t.Fatal("writer must not be ready before migration")
	}
	if got := testutil.ToFloat64(w.writes.WithLabelValues("error")); got != 2 {
		t.Fatalf("error writes = %v", got)
	}

	fs.set(nil, nil)
	w.Tick(context.Background())
	if !w.Ready() {
		t.Fatal("writer should be ready after the database returns")
	}
	if seq, _ := w.Last(); seq != 1 {
		t.Fatalf("seq = %d", seq)
	}
}

func TestInsertFailureMakesWriterUnready(t *testing.T) {
	fs := &fakeStore{}
	w, _ := newTest(fs)
	w.Tick(context.Background())

	fs.set(nil, errors.New("read-only transaction"))
	w.Tick(context.Background())
	if w.Ready() {
		t.Fatal("failing writer should not be ready")
	}
	if seq, _ := w.Last(); seq != 1 {
		t.Fatalf("last acknowledged write must survive failures, got %d", seq)
	}

	fs.set(nil, nil)
	w.Tick(context.Background())
	if !w.Ready() {
		t.Fatal("writer should recover")
	}
}

func TestRunStopsOnCancel(t *testing.T) {
	fs := &fakeStore{}
	w, _ := newTest(fs)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		w.Run(ctx)
		close(done)
	}()

	deadline := time.After(2 * time.Second)
	for {
		if seq, _ := w.Last(); seq >= 3 {
			break
		}
		select {
		case <-deadline:
			t.Fatal("writer did not write")
		case <-time.After(time.Millisecond):
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
}
