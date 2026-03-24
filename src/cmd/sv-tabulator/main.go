// sv-tabulator is the air-gapped tabulation service.
//
// It runs as a CLI on a dedicated, air-gapped machine at the tabulation center.
// Input arrives via encrypted USB drives from polling places.
// Output (Merkle roots, results) is exported to encrypted USB for transport.
//
// This binary has NO network interface. It is never connected to any network.
//
// Commands:
//   sv-tabulator ingest        Ingest vote data from encrypted USB
//   sv-tabulator verify-canaries  Verify canary test votes for all machines
//   sv-tabulator merkle-build  Build Merkle trees for each precinct
//   sv-tabulator tabulate      Count votes and produce results
//   sv-tabulator reconcile     Verify token counts match vote counts
//   sv-tabulator export        Export results to encrypted USB
//   sv-tabulator audit-tree    Independently verify a Merkle tree
package main

import (
	"fmt"
	"log/slog"
	"os"
)

var (
	version   = "dev"
	commitSHA = "unknown"
	buildTime = "unknown"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	command := os.Args[1]

	slog.Info("sv-tabulator starting",
		"version", version,
		"command", command,
	)

	switch command {
	case "ingest":
		// TODO: decrypt USB, validate data integrity, load into securevote_votes
		slog.Info("ingesting vote data from encrypted media")
	case "verify-canaries":
		// TODO: check all canary votes against expected values
		slog.Info("verifying canary test votes")
	case "merkle-build":
		// TODO: build precinct-level Merkle trees from vote_casts
		slog.Info("building Merkle trees")
	case "tabulate":
		// TODO: count votes per race per candidate, produce results
		slog.Info("tabulating votes")
	case "reconcile":
		// TODO: verify token issuance count matches valid vote count
		slog.Info("reconciling token counts vs vote counts")
	case "export":
		// TODO: export results, Merkle roots, and proofs to encrypted USB
		slog.Info("exporting results to encrypted media")
	case "audit-tree":
		// TODO: independently recompute and verify a Merkle tree
		slog.Info("auditing Merkle tree integrity")
	case "version":
		fmt.Printf("sv-tabulator %s (commit: %s, built: %s)\n", version, commitSHA, buildTime)
	default:
		slog.Error("unknown command", "command", command)
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `Usage: sv-tabulator <command> [options]

Commands:
  ingest           Ingest vote data from encrypted USB
  verify-canaries  Verify canary test votes
  merkle-build     Build Merkle trees for each precinct
  tabulate         Count votes and produce results
  reconcile        Verify token counts match vote counts
  export           Export results to encrypted USB
  audit-tree       Independently verify a Merkle tree
  version          Print version information
`)
}
