// sv-admin is the election administration service.
//
// It runs on a restricted network accessible only to authorized election
// administrators. It manages election setup, BDF creation and signing,
// machine provisioning, worker management, and PIN generation.
//
// All requests require mTLS client certificates.
//
// Usage:
//
//	sv-admin --config=/etc/securevote/admin.toml
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

var (
	version   = "dev"
	commitSHA = "unknown"
	buildTime = "unknown"
)

func main() {
	configPath := flag.String("config", "/etc/securevote/admin.toml", "Path to config file")
	addr := flag.String("addr", ":9443", "Listen address (mTLS)")
	showVersion := flag.Bool("version", false, "Print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("sv-admin %s (commit: %s, built: %s)\n", version, commitSHA, buildTime)
		os.Exit(0)
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	slog.Info("sv-admin starting",
		"version", version,
		"addr", *addr,
		"config", *configPath,
	)

	// TODO: load config, connect to securevote_election (RW) and
	// securevote_registration (RW), configure mTLS

	mux := http.NewServeMux()

	// Election management
	mux.HandleFunc("POST /api/v1/elections", handleNotImplemented)
	mux.HandleFunc("GET /api/v1/elections/{id}", handleNotImplemented)
	mux.HandleFunc("PUT /api/v1/elections/{id}/status", handleNotImplemented)

	// BDF management
	mux.HandleFunc("POST /api/v1/elections/{id}/bdf", handleNotImplemented)
	mux.HandleFunc("POST /api/v1/elections/{id}/bdf/sign", handleNotImplemented)
	mux.HandleFunc("GET /api/v1/elections/{id}/bdf/status", handleNotImplemented)

	// Machine management
	mux.HandleFunc("POST /api/v1/machines/provision", handleNotImplemented)
	mux.HandleFunc("PUT /api/v1/machines/{id}/assign", handleNotImplemented)
	mux.HandleFunc("PUT /api/v1/machines/{id}/status", handleNotImplemented)
	mux.HandleFunc("GET /api/v1/machines/{id}/attestation", handleNotImplemented)

	// Worker management
	mux.HandleFunc("POST /api/v1/workers", handleNotImplemented)
	mux.HandleFunc("GET /api/v1/workers/{id}", handleNotImplemented)
	mux.HandleFunc("PUT /api/v1/workers/{id}/certify", handleNotImplemented)

	// PIN management
	mux.HandleFunc("POST /api/v1/pins/generate", handleNotImplemented)
	mux.HandleFunc("POST /api/v1/pins/mail", handleNotImplemented)

	// Readiness checks
	mux.HandleFunc("GET /api/v1/precincts/{id}/readiness", handleNotImplemented)

	// Health
	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"healthy","version":"` + version + `"}`))
	})

	server := &http.Server{
		Addr:         *addr,
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
		// TODO: configure TLSConfig with mTLS (RequireAndVerifyClientCert)
	}

	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan
		slog.Info("shutting down server")
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	slog.Info("listening (mTLS required)", "addr", *addr)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		slog.Error("server error", "error", err)
		os.Exit(1)
	}

	slog.Info("sv-admin shutdown complete")
}

func handleNotImplemented(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotImplemented)
	_, _ = w.Write([]byte(`{"status":"not_implemented","message":"endpoint scaffolded — implementation pending"}`))
}
