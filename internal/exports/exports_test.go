package exports

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/store"
)

type fakeSource struct {
	events []store.Event
	err    error
	limit  int
}

func (f *fakeSource) Recent(_ context.Context, limit int) ([]store.Event, error) {
	f.limit = limit
	return f.events, f.err
}

func fixedNow() time.Time { return time.Date(2026, 10, 1, 12, 0, 0, 5, time.UTC) }

func TestCreateWritesCSVAndChecksum(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "exports")
	src := &fakeSource{events: []store.Event{
		{Seq: 1, CreatedAt: time.Date(2026, 10, 1, 11, 0, 0, 0, time.UTC), Writer: "a"},
		{Seq: 2, CreatedAt: time.Date(2026, 10, 1, 11, 0, 1, 0, time.UTC), Writer: "a"},
	}}
	e := &Exporter{Dir: dir, Src: src, Limit: 50, Now: fixedNow}

	f, err := e.Create(context.Background())
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if src.limit != 50 {
		t.Fatalf("limit = %d", src.limit)
	}
	if f.Name != "export-20261001T120000.000000005Z.csv" || f.Rows != 2 {
		t.Fatalf("unexpected file: %+v", f)
	}

	data, err := os.ReadFile(filepath.Join(dir, f.Name))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	want := "seq,created_at,writer\n1,2026-10-01T11:00:00Z,a\n2,2026-10-01T11:00:01Z,a\n"
	if string(data) != want {
		t.Fatalf("csv = %q", data)
	}
	sum := sha256.Sum256(data)
	if f.SHA256 != hex.EncodeToString(sum[:]) || f.Size != int64(len(data)) {
		t.Fatalf("checksum/size mismatch: %+v", f)
	}

	// No temporary files are left behind.
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("expected exactly one file, got %d", len(entries))
	}
}

func TestListRecomputesChecksums(t *testing.T) {
	dir := t.TempDir()
	e := &Exporter{Dir: dir, Src: &fakeSource{}, Limit: 1, Now: fixedNow}
	created, err := e.Create(context.Background())
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	// Files that are not exports are ignored.
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "export-dir.csv"), 0o750); err != nil {
		t.Fatal(err)
	}

	files, err := e.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(files) != 1 || files[0].SHA256 != created.SHA256 || files[0].Name != created.Name {
		t.Fatalf("unexpected list: %+v (created %+v)", files, created)
	}

	// Corruption on disk changes the reported checksum.
	if err := os.WriteFile(filepath.Join(dir, created.Name), []byte("tampered"), 0o600); err != nil {
		t.Fatal(err)
	}
	files, err = e.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if files[0].SHA256 == created.SHA256 {
		t.Fatal("checksum did not change after tampering")
	}
}

func TestListMissingDirIsEmpty(t *testing.T) {
	e := &Exporter{Dir: filepath.Join(t.TempDir(), "absent")}
	files, err := e.List()
	if err != nil || len(files) != 0 {
		t.Fatalf("files=%v err=%v", files, err)
	}
}

func TestListFailsOnUnreadableDir(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows reports ENOTDIR as not-exist")
	}
	file := filepath.Join(t.TempDir(), "plain-file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	e := &Exporter{Dir: file}
	if _, err := e.List(); err == nil {
		t.Fatal("expected error when Dir is a file")
	}
}

func TestCreatePropagatesSourceError(t *testing.T) {
	e := &Exporter{Dir: t.TempDir(), Src: &fakeSource{err: errors.New("db down")}, Limit: 1, Now: fixedNow}
	if _, err := e.Create(context.Background()); err == nil || !strings.Contains(err.Error(), "db down") {
		t.Fatalf("err = %v", err)
	}
}

func TestCreateFailsWhenDirIsAFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), "plain-file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	e := &Exporter{Dir: file, Src: &fakeSource{}, Limit: 1, Now: fixedNow}
	if _, err := e.Create(context.Background()); err == nil {
		t.Fatal("expected error")
	}
}
