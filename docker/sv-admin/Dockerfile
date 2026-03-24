# ============================================================================
# sv-admin — Election Administration Service
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
    -o /app/sv-admin ./cmd/sv-admin/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svadmin
COPY --from=builder /app/sv-admin /usr/local/bin/sv-admin
USER svadmin
WORKDIR /app
EXPOSE 9443
ENTRYPOINT ["sv-admin"]
CMD ["--config=/app/configs/admin.toml"]
