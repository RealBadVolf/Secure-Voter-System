# SecureVote Makefile
#
# Reproducible builds are critical for election security. Anyone must be
# able to compile this source and produce a bit-for-bit identical binary
# to what is deployed on voting machines. The build flags below ensure this.

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Reproducible build flags:
#   -trimpath     removes filesystem paths from the binary
#   -buildvcs=false  removes VCS metadata (we inject it via ldflags instead)
#   -ldflags="-s -w" strips symbol table and debug info for smaller binary
GO_BUILD_FLAGS := -trimpath -buildvcs=false
GO_LDFLAGS := -s -w \
	-X main.version=$(VERSION) \
	-X main.commitSHA=$(COMMIT) \
	-X main.buildTime=$(BUILD_TIME)

# Output directory
BUILD_DIR := ./build

# Target architectures for voting machines
MACHINE_GOOS := linux
MACHINE_GOARCH := arm64

.PHONY: all clean build test lint vet fmt check \
        build-machine build-tabulator build-admin build-verify \
        cross-machine sbom verify-build

# --- Default target ---
all: check build

# --- Build all binaries (native architecture) ---
build: build-machine build-tabulator build-admin build-verify
	@echo "All binaries built in $(BUILD_DIR)/"

build-machine:
	@mkdir -p $(BUILD_DIR)
	go build $(GO_BUILD_FLAGS) -ldflags '$(GO_LDFLAGS)' -o $(BUILD_DIR)/sv-machine ./cmd/sv-machine/

build-tabulator:
	@mkdir -p $(BUILD_DIR)
	go build $(GO_BUILD_FLAGS) -ldflags '$(GO_LDFLAGS)' -o $(BUILD_DIR)/sv-tabulator ./cmd/sv-tabulator/

build-admin:
	@mkdir -p $(BUILD_DIR)
	go build $(GO_BUILD_FLAGS) -ldflags '$(GO_LDFLAGS)' -o $(BUILD_DIR)/sv-admin ./cmd/sv-admin/

build-verify:
	@mkdir -p $(BUILD_DIR)
	go build $(GO_BUILD_FLAGS) -ldflags '$(GO_LDFLAGS)' -o $(BUILD_DIR)/sv-verify ./cmd/sv-verify/

# --- Cross-compile voting machine binary for ARM64 ---
cross-machine:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=$(MACHINE_GOOS) GOARCH=$(MACHINE_GOARCH) \
		go build $(GO_BUILD_FLAGS) -ldflags '$(GO_LDFLAGS)' \
		-o $(BUILD_DIR)/sv-machine-$(MACHINE_GOOS)-$(MACHINE_GOARCH) \
		./cmd/sv-machine/
	@echo "Cross-compiled: $(BUILD_DIR)/sv-machine-$(MACHINE_GOOS)-$(MACHINE_GOARCH)"

# --- Testing ---
test:
	go test -race -count=1 ./...

test-coverage:
	go test -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report: coverage.html"

test-crypto:
	@echo "Running crypto package tests (must be 100% coverage)..."
	go test -race -coverprofile=crypto_coverage.out ./internal/crypto/
	@COVERAGE=$$(go tool cover -func=crypto_coverage.out | grep total | awk '{print $$3}'); \
	echo "Crypto coverage: $$COVERAGE"; \
	if [ "$$(echo $$COVERAGE | tr -d '%')" != "100.0" ]; then \
		echo "FAIL: crypto package must have 100% test coverage"; \
		exit 1; \
	fi

# Fuzz testing (run for a duration)
fuzz:
	go test -fuzz=FuzzBuildTree -fuzztime=60s ./internal/merkle/
	go test -fuzz=FuzzVerifyProof -fuzztime=60s ./internal/merkle/
	go test -fuzz=FuzzHashPassword -fuzztime=60s ./internal/crypto/
	go test -fuzz=FuzzParseBDF -fuzztime=60s ./internal/ballot/

# --- Code quality ---
fmt:
	gofmt -w .

vet:
	go vet ./...

lint:
	@which golangci-lint > /dev/null 2>&1 || (echo "Install golangci-lint: https://golangci-lint.run/usage/install/" && exit 1)
	golangci-lint run ./...

check: fmt vet lint test

# --- Generate Software Bill of Materials ---
sbom:
	@mkdir -p $(BUILD_DIR)
	go version -m $(BUILD_DIR)/sv-machine > $(BUILD_DIR)/sv-machine.sbom.txt 2>/dev/null || true
	go list -m -json all > $(BUILD_DIR)/modules.json
	@echo "SBOM generated: $(BUILD_DIR)/sv-machine.sbom.txt and $(BUILD_DIR)/modules.json"

# --- Verify reproducible build ---
# Builds the binary twice and compares checksums
verify-build: clean
	@echo "Build 1..."
	@$(MAKE) build-machine
	@sha256sum $(BUILD_DIR)/sv-machine > /tmp/sv-build1.sha256
	@cp $(BUILD_DIR)/sv-machine /tmp/sv-machine-build1

	@echo "Build 2..."
	@rm $(BUILD_DIR)/sv-machine
	@$(MAKE) build-machine
	@sha256sum $(BUILD_DIR)/sv-machine > /tmp/sv-build2.sha256

	@echo "Comparing builds..."
	@BUILD1=$$(cat /tmp/sv-build1.sha256 | awk '{print $$1}'); \
	 BUILD2=$$(cat /tmp/sv-build2.sha256 | awk '{print $$1}'); \
	 if [ "$$BUILD1" = "$$BUILD2" ]; then \
	   echo "PASS: Builds are identical ($$BUILD1)"; \
	 else \
	   echo "FAIL: Builds differ!"; \
	   echo "  Build 1: $$BUILD1"; \
	   echo "  Build 2: $$BUILD2"; \
	   exit 1; \
	 fi
	@rm -f /tmp/sv-build1.sha256 /tmp/sv-build2.sha256 /tmp/sv-machine-build1

# --- Compute binary hashes for publication ---
hashes:
	@echo "Binary hashes for publication:"
	@for f in $(BUILD_DIR)/sv-*; do \
		echo "  $$(sha256sum $$f)"; \
	done

# --- Clean ---
clean:
	rm -rf $(BUILD_DIR)
	rm -f coverage.out coverage.html crypto_coverage.out

# --- Development helpers ---
run-machine:
	go run ./cmd/sv-machine/ --config=configs/machine.example.toml

run-verify:
	go run ./cmd/sv-verify/ --config=configs/verify.example.toml

# --- Docker (for integration tests) ---
docker-test-dbs:
	docker compose -f docker-compose.test.yml up -d
	@echo "Waiting for databases..."
	@sleep 5
	@echo "Test databases ready."

docker-test-dbs-down:
	docker compose -f docker-compose.test.yml down -v
