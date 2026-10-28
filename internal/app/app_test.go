package app

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/server"
)

func discard() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestFromEnvDefaults(t *testing.T) {
	c, err := FromEnv(env(map[string]string{"HOSTNAME": "ledger-api-7d9"}))
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != ":8080" || c.WriteInterval != 100*time.Millisecond || c.DataDir != "/data" ||
		c.WriterName != "ledger-api-7d9" || c.ExportRows != 1000 || c.DatabaseURL != "" {
		t.Fatalf("unexpected defaults: %+v", c)
	}
}

func TestFromEnvOverrides(t *testing.T) {
	c, err := FromEnv(env(map[string]string{
		"LISTEN_ADDR": ":9090", "WRITE_INTERVAL": "250ms", "DATA_DIR": "/tmp/x",
		"WRITER_NAME": "w1", "EXPORT_ROWS": "5", "DATABASE_URL": "postgres://x",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != ":9090" || c.WriteInterval != 250*time.Millisecond || c.DataDir != "/tmp/x" ||
		c.WriterName != "w1" || c.ExportRows != 5 || c.DatabaseURL != "postgres://x" {
		t.Fatalf("unexpected config: %+v", c)
	}
}

func TestFromEnvRejectsBadValues(t *testing.T) {
	for _, m := range []map[string]string{
		{"WRITE_INTERVAL": "soon"},
		{"WRITE_INTERVAL": "1ms"},
		{"EXPORT_ROWS": "0"},
		{"EXPORT_ROWS": "many"},
	} {
		if _, err := FromEnv(env(m)); err == nil {
			t.Fatalf("expected error for %v", m)
		}
	}
}

func TestNewRejectsBadDSN(t *testing.T) {
	if _, err := New(context.Background(), Config{DatabaseURL: "postgres://%zz"}, discard()); err == nil {
		t.Fatal("expected error")
	}
}

func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	return addr
}

// The service must start and serve liveness while the database is down,
// which is exactly the situation during a restore.
func TestRunServesWhileDatabaseIsDown(t *testing.T) {
	addr := freeAddr(t)
	cfg := Config{
		ListenAddr: addr, DatabaseURL: "postgres://u:p@127.0.0.1:1/db?connect_timeout=1",
		WriteInterval: 20 * time.Millisecond, DataDir: t.TempDir(), WriterName: "t", ExportRows: 10,
	}
	a, err := New(context.Background(), cfg, discard())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Run(ctx) }()

	client := &http.Client{Timeout: 2 * time.Second}
	var lastErr error
	for i := 0; i < 100; i++ {
		req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://"+addr+"/healthz", http.NoBody)
		resp, err := client.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				lastErr = nil
				break
			}
		}
		lastErr = err
		time.Sleep(20 * time.Millisecond)
	}
	if lastErr != nil {
		t.Fatalf("healthz never answered: %v", lastErr)
	}
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://"+addr+"/readyz", http.NoBody)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("readyz = %d with database down", resp.StatusCode)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not stop")
	}
}

func TestRunFailsOnBusyPort(t *testing.T) {
	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	a, err := New(context.Background(), Config{ListenAddr: ln.Addr().String(), WriteInterval: time.Second, DataDir: t.TempDir()}, discard())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "listen") {
		t.Fatalf("err = %v", err)
	}
}

// End to end against a real PostgreSQL (CI service container).
func TestEndToEndWithDatabase(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set")
	}
	cfg := Config{DatabaseURL: dsn, WriteInterval: 10 * time.Millisecond, DataDir: t.TempDir(), WriterName: "e2e", ExportRows: 5}
	a, err := New(context.Background(), cfg, discard())
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go a.Writer().Run(ctx)

	deadline := time.Now().Add(10 * time.Second)
	for {
		if seq, _ := a.Writer().Last(); seq > 0 && a.Writer().Ready() {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("writer never committed a row")
		}
		time.Sleep(10 * time.Millisecond)
	}

	get := func(method, path string) *http.Response {
		req, _ := http.NewRequestWithContext(context.Background(), method, ts.URL+path, http.NoBody)
		resp, err := ts.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}

	resp := get(http.MethodGet, "/readyz")
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("readyz = %d", resp.StatusCode)
	}

	resp = get(http.MethodGet, "/api/stats")
	var st server.StatsResponse
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if st.Rows == 0 || st.MaxSeq == 0 || st.LastAt == nil || st.LastAckAt == nil {
		t.Fatalf("unexpected stats: %+v", st)
	}

	resp = get(http.MethodPost, "/api/exports")
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("export = %d", resp.StatusCode)
	}
	resp = get(http.MethodGet, "/api/exports")
	var files []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&files); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if len(files) != 1 {
		t.Fatalf("exports = %v", files)
	}
}
