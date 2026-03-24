# ============================================================================
# sv-verify — Public Verification Portal
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
    -o /app/sv-verify ./cmd/sv-verify/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svverify
COPY --from=builder /app/sv-verify /usr/local/bin/sv-verify
USER svverify
WORKDIR /app
EXPOSE 8443
ENTRYPOINT ["sv-verify"]
CMD ["--config=/app/configs/verify.toml"]
