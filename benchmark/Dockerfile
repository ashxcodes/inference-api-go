# Load-test image: slim runtime with curl for healthcheck (production image stays distroless).
FROM golang:1.25-bookworm AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=benchmark
RUN go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/server ./cmd/server

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /out/server /server
ENV MODEL_DIR=/models PORT=8456
EXPOSE 8456
HEALTHCHECK --interval=5s --timeout=3s --start-period=120s --retries=30 \
  CMD curl -sf "http://127.0.0.1:8456/health-check-AMM" | grep -q '"status":"ok"'
ENTRYPOINT ["/server"]
