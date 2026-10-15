#!/usr/bin/env bash
# Start/stop a single benchmark container (K8s-like 0.7 CPU, 1000Mi, optional cpuset).
#
#   ./benchmark/server.sh build
#   ./benchmark/server.sh start bench-go-cpu07
#   ./benchmark/server.sh warm bench-go-cpu07
#   ./benchmark/server.sh stop bench-go-cpu07
#
# Env:
#   BENCH_CPU=0.7
#   SERVER_CPUSET=1,3,6,8   (empty to omit)
#   BENCH_HOST_PORT=18456:8456
#   PREDICT_CONCURRENCY=0
#   MODEL_TXT=.../testdata/parity/AMM.txt
#   BENCH_OTLP=1
#   BENCH_OTEL_ENV_FILE=.../.env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BENCH_CPU="${BENCH_CPU:-0.7}"
SERVER_CPUSET="${SERVER_CPUSET:-1,3,6,8}"
PREDICT_CONCURRENCY="${PREDICT_CONCURRENCY:-0}"
BENCH_HOST_PORT="${BENCH_HOST_PORT:-18456:8456}"
MODEL_TXT="${MODEL_TXT:-${ROOT}/testdata/parity/AMM.txt}"
BENCH_OTLP="${BENCH_OTLP:-0}"
BENCH_OTEL_ENV_FILE="${BENCH_OTEL_ENV_FILE:-${ROOT}/.env}"

WARM_BODY='{"city":"AMM","key":"warm","origin_lat":28,"origin_lng":52,"destination_lat":30.1,"destination_lng":54.1,"created_at":"2024-01-01 00:00:00"}'

cpuset_args=()
if [[ -n "$SERVER_CPUSET" ]]; then
  cpuset_args=(--cpuset-cpus "$SERVER_CPUSET")
fi

port_publish=()
if [[ -n "$BENCH_HOST_PORT" ]]; then
  port_publish=(-p "${BENCH_HOST_PORT}")
fi

cmd="${1:-}"

build() {
  docker build -t ml-model-go:benchmark -f "${ROOT}/benchmark/Dockerfile" "$ROOT"
}

start() {
  local name="$1"
  if [[ ! -f "$MODEL_TXT" ]]; then
    echo "Model not found: $MODEL_TXT (set MODEL_TXT=...)" >&2
    exit 1
  fi
  docker rm -f "$name" 2>/dev/null || true
  otel_run=()
  if [[ "$BENCH_OTLP" == "1" ]]; then
    if [[ ! -f "$BENCH_OTEL_ENV_FILE" ]]; then
      echo "OTLP env file not found: $BENCH_OTEL_ENV_FILE" >&2
      exit 1
    fi
    otel_run=(
      --add-host=host.docker.internal:host-gateway
      --env-file "$BENCH_OTEL_ENV_FILE"
      -e MODEL_API_KEY=benchmark-key
      -e OTEL_SDK_DISABLED=false
      -e OTEL_TRACES_EXPORTER=otlp
      -e OTEL_METRICS_EXPORTER=otlp
      -e OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=grpc
      -e OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=grpc
      -e OTEL_TRACES_SAMPLER=always_on
    )
  else
    otel_run=(
      -e MODEL_API_KEY=benchmark-key
      -e OTEL_SDK_DISABLED=true
    )
  fi
  docker run -d --name "$name" \
    --cpus="$BENCH_CPU" --memory=1000m --pids-limit=256 \
    "${cpuset_args[@]}" \
    "${port_publish[@]}" \
    "${otel_run[@]}" \
    -e PREDICT_CONCURRENCY="${PREDICT_CONCURRENCY}" \
    -v "${MODEL_TXT}:/models/AMM.txt:ro" \
    ml-model-go:benchmark
  if [[ "$BENCH_OTLP" == "1" ]]; then
    echo "==> OTLP enabled (env: $BENCH_OTEL_ENV_FILE)"
  fi
  if [[ -n "$BENCH_HOST_PORT" ]]; then
    echo "==> Started $name (http://127.0.0.1:${BENCH_HOST_PORT%%:*})"
  else
    echo "==> Started $name (port 8456 in container only)"
  fi
}

wait_healthy() {
  local name="$1"
  for i in $(seq 1 90); do
    if docker exec "$name" curl -sf "http://127.0.0.1:8456/health-check-AMM" | grep -q '"status":"ok"'; then
      return 0
    fi
    sleep 2
  done
  docker logs "$name" >&2 || true
  echo "Health check failed for $name" >&2
  exit 1
}

warm() {
  local name="$1"
  wait_healthy "$name"
  docker exec "$name" curl -sf -X POST "http://127.0.0.1:8456/predict" \
    -H "Content-Type: application/json" -H "X-API-Key: benchmark-key" \
    -d "$WARM_BODY" >/dev/null
  echo "==> Warmed $name"
}

stop() {
  local name="$1"
  docker rm -f "$name"
}

case "$cmd" in
  build) build ;;
  start)
    name="${2:-}"
    if [[ -z "$name" ]]; then
      echo "Usage: $0 start CONTAINER_NAME" >&2
      exit 1
    fi
    start "$name"
    ;;
  warm)
    name="${2:-}"
    if [[ -z "$name" ]]; then
      echo "Usage: $0 warm CONTAINER_NAME" >&2
      exit 1
    fi
    warm "$name"
    ;;
  stop)
    name="${2:-}"
    if [[ -z "$name" ]]; then
      echo "Usage: $0 stop CONTAINER_NAME" >&2
      exit 1
    fi
    stop "$name"
    ;;
  *)
    echo "Usage: $0 build|start|warm|stop ..." >&2
    exit 1
    ;;
esac
