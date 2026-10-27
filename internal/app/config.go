// Package app wires the ledger service together and runs it.
package app

import (
	"errors"
	"fmt"
	"strconv"
	"time"
)

// Config is read from the environment.
type Config struct {
	ListenAddr    string
	DatabaseURL   string // empty: use PGHOST, PGUSER, PGPASSWORD, ...
	WriteInterval time.Duration
	DataDir       string
	WriterName    string
	ExportRows    int
}

// FromEnv builds a Config. getenv is os.Getenv in production.
func FromEnv(getenv func(string) string) (Config, error) {
	c := Config{
		ListenAddr:    or(getenv("LISTEN_ADDR"), ":8080"),
		DatabaseURL:   getenv("DATABASE_URL"),
		WriteInterval: 100 * time.Millisecond,
		DataDir:       or(getenv("DATA_DIR"), "/data"),
		WriterName:    or(getenv("WRITER_NAME"), or(getenv("HOSTNAME"), "ledger-api")),
		ExportRows:    1000,
	}
	if v := getenv("WRITE_INTERVAL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("WRITE_INTERVAL: %w", err)
		}
		if d < 10*time.Millisecond {
			return Config{}, errors.New("WRITE_INTERVAL must be at least 10ms")
		}
		c.WriteInterval = d
	}
	if v := getenv("EXPORT_ROWS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return Config{}, fmt.Errorf("EXPORT_ROWS must be a positive integer, got %q", v)
		}
		c.ExportRows = n
	}
	return c, nil
}

func or(v, def string) string {
	if v == "" {
		return def
	}
	return v
}
