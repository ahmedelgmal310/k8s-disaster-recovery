// Package store persists the ledger's timestamped events in PostgreSQL.
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Event is one row of the events table.
type Event struct {
	Seq       int64     `json:"seq"`
	CreatedAt time.Time `json:"created_at"`
	Writer    string    `json:"writer"`
}

// Stats summarises the events table.
type Stats struct {
	Rows    int64      `json:"rows"`
	MaxSeq  int64      `json:"max_seq"`
	FirstAt *time.Time `json:"first_at"`
	LastAt  *time.Time `json:"last_at"`
}

// Schema creates the events table. created_at uses clock_timestamp() so each
// row carries the time it was written, not the start of its transaction.
const Schema = `CREATE TABLE IF NOT EXISTS events (
	seq        bigserial   PRIMARY KEY,
	created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
	writer     text        NOT NULL
);
CREATE INDEX IF NOT EXISTS events_created_at_idx ON events (created_at);`

// Postgres is a Store backed by a pgx connection pool.
type Postgres struct {
	pool *pgxpool.Pool
}

// Open creates a lazy connection pool. An empty dsn falls back to the libpq
// environment variables (PGHOST, PGUSER, PGPASSWORD, PGDATABASE, PGSSLMODE).
// Open does not contact the server, so the service can start while the
// database is still being restored.
func Open(ctx context.Context, dsn string) (*Postgres, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}
	cfg.MaxConns = 4
	cfg.MaxConnIdleTime = 30 * time.Second
	cfg.HealthCheckPeriod = 5 * time.Second
	cfg.ConnConfig.ConnectTimeout = 3 * time.Second
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

// Close releases all connections.
func (p *Postgres) Close() { p.pool.Close() }

// Migrate creates the schema if it does not exist.
func (p *Postgres) Migrate(ctx context.Context) error {
	if _, err := p.pool.Exec(ctx, Schema); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

// Ping checks that the database answers queries.
func (p *Postgres) Ping(ctx context.Context) error {
	var one int
	if err := p.pool.QueryRow(ctx, "SELECT 1").Scan(&one); err != nil {
		return fmt.Errorf("ping: %w", err)
	}
	return nil
}

// Insert writes one event and returns it as committed.
func (p *Postgres) Insert(ctx context.Context, writer string) (Event, error) {
	ev := Event{Writer: writer}
	err := p.pool.QueryRow(ctx,
		"INSERT INTO events (writer) VALUES ($1) RETURNING seq, created_at", writer,
	).Scan(&ev.Seq, &ev.CreatedAt)
	if err != nil {
		return Event{}, fmt.Errorf("insert: %w", err)
	}
	return ev, nil
}

// Stats returns the row count, the highest sequence number and the time range.
func (p *Postgres) Stats(ctx context.Context) (Stats, error) {
	var s Stats
	err := p.pool.QueryRow(ctx,
		"SELECT count(*), coalesce(max(seq), 0), min(created_at), max(created_at) FROM events",
	).Scan(&s.Rows, &s.MaxSeq, &s.FirstAt, &s.LastAt)
	if err != nil {
		return Stats{}, fmt.Errorf("stats: %w", err)
	}
	return s, nil
}

// Recent returns up to limit of the newest events, oldest first.
func (p *Postgres) Recent(ctx context.Context, limit int) ([]Event, error) {
	if limit <= 0 {
		return nil, errors.New("limit must be positive")
	}
	rows, err := p.pool.Query(ctx,
		`SELECT seq, created_at, writer FROM
		   (SELECT seq, created_at, writer FROM events ORDER BY seq DESC LIMIT $1) t
		 ORDER BY seq`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent: %w", err)
	}
	events, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Event, error) {
		var ev Event
		err := r.Scan(&ev.Seq, &ev.CreatedAt, &ev.Writer)
		return ev, err
	})
	if err != nil {
		return nil, fmt.Errorf("recent: %w", err)
	}
	return events, nil
}
