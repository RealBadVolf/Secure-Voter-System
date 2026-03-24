// sv-verify is the public verification portal.
//
// It serves a read-only REST API that allows voters to confirm their
// vote was included in the final tally. It connects to securevote_votes
// with a restricted read-only account that can only access vote existence
// checks and Merkle proofs — never raw vote selections.
//
// This is the ONLY SecureVote service exposed to the public internet.
// It is stateless, rate-limited, and hardened for hostile traffic.
//
// Usage:
//
//	sv-verify --config=/etc/securevote/verify.toml
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
	configPath := flag.String("config", "/etc/securevote/verify.toml", "Path to config file")
	addr := flag.String("addr", ":8443", "Listen address (TLS)")
	showVersion := flag.Bool("version", false, "Print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("sv-verify %s (commit: %s, built: %s)\n", version, commitSHA, buildTime)
		os.Exit(0)
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	slog.Info("sv-verify starting",
		"version", version,
		"addr", *addr,
		"config", *configPath,
	)

	// TODO: load config, connect to securevote_votes (read-only), set up rate limiter

	mux := http.NewServeMux()

	// Health check (no auth required)
	mux.HandleFunc("GET /api/v1/health", handleHealth)

	// Vote verification (rate-limited, PIN-authenticated)
	mux.HandleFunc("POST /api/v1/verify", handleVerify)

	// Published Merkle roots (public, no auth)
	mux.HandleFunc("GET /api/v1/election/{id}/merkle-root", handleMerkleRoot)

	// Published BDF hash (public, no auth)
	mux.HandleFunc("GET /api/v1/election/{id}/bdf-hash", handleBDFHash)

	server := &http.Server{
		Addr:         *addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan

		slog.Info("shutting down server")
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	slog.Info("listening", "addr", *addr)
	// TODO: use server.ListenAndServeTLS with proper cert paths
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		slog.Error("server error", "error", err)
		os.Exit(1)
	}

	slog.Info("sv-verify shutdown complete")
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"healthy","version":"` + version + `"}`))
}

func handleVerify(w http.ResponseWriter, r *http.Request) {
	// TODO: parse request, validate rate limit, verify PIN, lookup vote, return Merkle proof
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotImplemented)
	_, _ = w.Write([]byte(`{"status":"not_implemented"}`))
}

func handleMerkleRoot(w http.ResponseWriter, r *http.Request) {
	// TODO: lookup and return the published Merkle root for the election
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotImplemented)
	_, _ = w.Write([]byte(`{"status":"not_implemented"}`))
}

func handleBDFHash(w http.ResponseWriter, r *http.Request) {
	// TODO: lookup and return the published BDF hash for the election
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotImplemented)
	_, _ = w.Write([]byte(`{"status":"not_implemented"}`))
}
