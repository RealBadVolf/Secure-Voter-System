# ============================================================================
# sv-machine-sim — Voting Machine Simulator (Demo/Dev)
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
    -o /app/sv-machine-sim ./cmd/sv-machine/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svmachine
COPY --from=builder /app/sv-machine-sim /usr/local/bin/sv-machine-sim
USER svmachine
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["sv-machine-sim"]
CMD ["--config=/app/configs/machine.toml"]
