# ============================================================================
# sv-tabulator — Air-Gapped Tabulation Service (CLI)
# ============================================================================
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata
WORKDIR /build
COPY src/go.mod src/go.sum* ./
RUN go mod download 2>/dev/null || true
COPY src/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w" \
    -o /app/sv-tabulator ./cmd/sv-tabulator/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svtab
COPY --from=builder /app/sv-tabulator /usr/local/bin/sv-tabulator
USER svtab
WORKDIR /app
ENTRYPOINT ["sv-tabulator"]
