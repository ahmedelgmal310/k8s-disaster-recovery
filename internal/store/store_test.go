package store

import (
	"context"
	"os"
	"testing"
	"time"
)

// These tests need a real PostgreSQL. CI provides one through DATABASE_URL;
// locally they are skipped when it is unset.
func openTest(t *testing.T) *Postgres {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	p, err := Open(ctx, dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if _, err := p.pool.Exec(ctx, "TRUNCATE events RESTART IDENTITY"); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	return p
}

func TestOpenRejectsBadDSN(t *testing.T) {
	if _, err := Open(context.Background(), "postgres://%zz"); err == nil {
		t.Fatal("expected parse error")
	}
}

func TestPingFailsWithoutServer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	p, err := Open(ctx, "postgres://u:p@127.0.0.1:1/db?connect_timeout=1")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer p.Close()
	if err := p.Ping(ctx); err == nil {
		t.Fatal("expected ping to fail")
	}
	if _, err := p.Insert(ctx, "w"); err == nil {
		t.Fatal("expected insert to fail")
	}
	if _, err := p.Stats(ctx); err == nil {
		t.Fatal("expected stats to fail")
	}
	if _, err := p.Recent(ctx, 1); err == nil {
		t.Fatal("expected recent to fail")
	}
	if err := p.Migrate(ctx); err == nil {
		t.Fatal("expected migrate to fail")
	}
}

func TestRecentRejectsNonPositiveLimit(t *testing.T) {
	p := &Postgres{}
	if _, err := p.Recent(context.Background(), 0); err == nil {
		t.Fatal("expected error")
	}
}

func TestInsertStatsRecent(t *testing.T) {
	p := openTest(t)
	ctx := context.Background()

	empty, err := p.Stats(ctx)
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	if empty.Rows != 0 || empty.MaxSeq != 0 || empty.LastAt != nil {
		t.Fatalf("unexpected empty stats: %+v", empty)
	}

	var last Event
	for i := 0; i < 5; i++ {
		last, err = p.Insert(ctx, "test")
		if err != nil {
			t.Fatalf("insert: %v", err)
		}
	}
	if last.Seq != 5 {
		t.Fatalf("seq = %d, want 5", last.Seq)
	}
	if err := p.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}

	s, err := p.Stats(ctx)
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	if s.Rows != 5 || s.MaxSeq != 5 || s.LastAt == nil || s.FirstAt == nil {
		t.Fatalf("unexpected stats: %+v", s)
	}
	if !s.LastAt.Equal(last.CreatedAt) {
		t.Fatalf("last_at %v != last insert %v", s.LastAt, last.CreatedAt)
	}

	recent, err := p.Recent(ctx, 3)
	if err != nil {
		t.Fatalf("recent: %v", err)
	}
	if len(recent) != 3 || recent[0].Seq != 3 || recent[2].Seq != 5 {
		t.Fatalf("unexpected recent: %+v", recent)
	}
	if recent[2].Writer != "test" {
		t.Fatalf("writer = %q", recent[2].Writer)
	}
}
