# Shared multi-stage builder for all Go services
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /build
COPY src/go.mod src/go.sum ./
RUN go mod download

COPY src/ ./

ARG SERVICE_NAME
ARG BUILD_VERSION=dev
ARG BUILD_COMMIT=unknown
ARG BUILD_TIME=unknown

RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w -X main.version=${BUILD_VERSION} -X main.commitSHA=${BUILD_COMMIT} -X main.buildTime=${BUILD_TIME}" \
    -o /app/service ./cmd/${SERVICE_NAME}/
