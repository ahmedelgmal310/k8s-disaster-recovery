package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/exports"
	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/server"
	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/store"
	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/writer"
)

// App is the assembled service.
type App struct {
	cfg    Config
	log    *slog.Logger
	db     *store.Postgres
	writer *writer.Writer
	srv    *server.Server
}

// New connects the pieces. It does not need the database to be up.
func New(ctx context.Context, cfg Config, log *slog.Logger) (*App, error) {
	db, err := store.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	w := writer.New(db, cfg.WriterName, cfg.WriteInterval, log, reg)
	srv := &server.Server{
		DB:       db,
		Exports:  &exports.Exporter{Dir: cfg.DataDir + "/exports", Src: db, Limit: cfg.ExportRows, Now: time.Now},
		Writer:   w,
		Gatherer: reg,
		Log:      log,
		Timeout:  3 * time.Second,
	}
	return &App{cfg: cfg, log: log, db: db, writer: w, srv: srv}, nil
}

// Handler exposes the HTTP API (used by tests).
func (a *App) Handler() http.Handler { return a.srv.Handler() }

// Writer exposes the background writer (used by tests).
func (a *App) Writer() *writer.Writer { return a.writer }

// Run serves HTTP and writes rows until ctx is cancelled, then shuts down
// gracefully.
func (a *App) Run(ctx context.Context) error {
	defer a.db.Close()

	ln, err := (&net.ListenConfig{}).Listen(ctx, "tcp", a.cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	httpSrv := &http.Server{
		Handler:           a.srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		BaseContext:       func(net.Listener) context.Context { return ctx },
	}

	writerCtx, stopWriter := context.WithCancel(ctx)
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		a.writer.Run(writerCtx)
	}()

	serveErr := make(chan error, 1)
	go func() { serveErr <- httpSrv.Serve(ln) }()
	a.log.Info("ledger-api started", "addr", ln.Addr().String(), "interval", a.cfg.WriteInterval.String(), "writer", a.cfg.WriterName)

	select {
	case <-ctx.Done():
	case err := <-serveErr:
		stopWriter()
		<-writerDone
		return fmt.Errorf("serve: %w", err)
	}

	stopWriter()
	<-writerDone
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("shutdown: %w", err)
	}
	a.log.Info("ledger-api stopped")
	return nil
}
