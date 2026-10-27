// Package exports writes CSV snapshots of recent events to the service's
// persistent volume. The files are the volume data that Velero's file-system
// backup protects, and their SHA-256 proves a restore brought them back intact.
package exports

import (
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ahmedelgmal310/k8s-disaster-recovery/internal/store"
)

// Source returns the newest events.
type Source interface {
	Recent(ctx context.Context, limit int) ([]store.Event, error)
}

// File describes one export on disk.
type File struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
	Rows   int    `json:"rows,omitempty"`
}

// Exporter writes and lists export files in Dir.
type Exporter struct {
	Dir   string
	Src   Source
	Limit int
	Now   func() time.Time
}

const suffix = ".csv"

// Create writes a CSV of the newest events and returns its checksum. The file
// is written to a temporary name and renamed, so a crash never leaves a
// half-written export behind.
func (e *Exporter) Create(ctx context.Context) (File, error) {
	events, err := e.Src.Recent(ctx, e.Limit)
	if err != nil {
		return File{}, err
	}
	if err := os.MkdirAll(e.Dir, 0o750); err != nil {
		return File{}, fmt.Errorf("create export dir: %w", err)
	}
	name := "export-" + e.Now().UTC().Format("20060102T150405.000000000Z") + suffix
	tmp, err := os.CreateTemp(e.Dir, ".tmp-export-*")
	if err != nil {
		return File{}, fmt.Errorf("create temp file: %w", err)
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename

	h := sha256.New()
	cw := csv.NewWriter(io.MultiWriter(tmp, h))
	if err := cw.Write([]string{"seq", "created_at", "writer"}); err != nil {
		_ = tmp.Close()
		return File{}, fmt.Errorf("write header: %w", err)
	}
	for _, ev := range events {
		rec := []string{strconv.FormatInt(ev.Seq, 10), ev.CreatedAt.UTC().Format(time.RFC3339Nano), ev.Writer}
		if err := cw.Write(rec); err != nil {
			_ = tmp.Close()
			return File{}, fmt.Errorf("write row: %w", err)
		}
	}
	cw.Flush()
	if err := cw.Error(); err != nil {
		_ = tmp.Close()
		return File{}, fmt.Errorf("flush: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return File{}, fmt.Errorf("sync: %w", err)
	}
	info, err := tmp.Stat()
	if err != nil {
		_ = tmp.Close()
		return File{}, fmt.Errorf("stat: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return File{}, fmt.Errorf("close: %w", err)
	}
	if err := os.Rename(tmp.Name(), filepath.Join(e.Dir, name)); err != nil {
		return File{}, fmt.Errorf("rename: %w", err)
	}
	return File{Name: name, Size: info.Size(), SHA256: hex.EncodeToString(h.Sum(nil)), Rows: len(events)}, nil
}

// List returns every export with a freshly computed checksum, sorted by name.
func (e *Exporter) List() ([]File, error) {
	entries, err := os.ReadDir(e.Dir)
	if errors.Is(err, os.ErrNotExist) {
		return []File{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read export dir: %w", err)
	}
	files := make([]File, 0, len(entries))
	for _, ent := range entries {
		if ent.IsDir() || !strings.HasPrefix(ent.Name(), "export-") || !strings.HasSuffix(ent.Name(), suffix) {
			continue
		}
		f, err := checksum(filepath.Join(e.Dir, ent.Name()))
		if err != nil {
			return nil, err
		}
		files = append(files, f)
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	return files, nil
}

func checksum(path string) (File, error) {
	f, err := os.Open(path) // #nosec G304 -- path is built from a directory listing of Dir
	if err != nil {
		return File{}, fmt.Errorf("open export: %w", err)
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return File{}, fmt.Errorf("hash export: %w", err)
	}
	return File{Name: filepath.Base(path), Size: n, SHA256: hex.EncodeToString(h.Sum(nil))}, nil
}
