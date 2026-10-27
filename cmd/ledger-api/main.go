// Command ledger-api is the stateful demo service: it writes one timestamped
// row per interval to PostgreSQL and exposes the statistics the DR drills use
// to measure recovery point and recovery time.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/app"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := app.FromEnv(os.Getenv)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	a, err := app.New(ctx, cfg, log)
	if err != nil {
		return err
	}
	return a.Run(ctx)
}
