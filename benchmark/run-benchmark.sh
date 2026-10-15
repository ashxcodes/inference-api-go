#!/usr/bin/env bash
# Load-test ml-model-go in Docker (K8s-like CPU/RAM limits).
#
# Examples:
#   BENCH_CPU=0.7 ./benchmark/run-benchmark.sh concurrent 25 2m
#   BENCH_OTLP=1 BENCH_CPU=0.7 ./benchmark/run-benchmark.sh concurrent 25 2m
#     (OTLP: ../.env — grpc :4317; kubectl port-forward --address 0.0.0.0 ... 4317:4317)
#   ./benchmark/run-benchmark.sh sustained 100 3m
#   ./benchmark/run-benchmark.sh suite
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/benchmark"

PROFILE="${1:-concurrent}"
ARG_RPS="${2:-}"
ARG_DURATION="${3:-}"

MODEL_TXT="${MODEL_TXT:-${ROOT}/testdata/parity/AMM.txt}"
BENCH_PORT="${BENCH_PORT:-18456}"
BENCH_CPU="${BENCH_CPU:-0.7}"
PREDICT_CONCURRENCY="${PREDICT_CONCURRENCY:-0}"
BENCH_OTLP="${BENCH_OTLP:-0}"
BENCH_OTEL_ENV_FILE="${BENCH_OTEL_ENV_FILE:-${ROOT}/.env}"

compose_files=(-f docker-compose.yml)
if [[ "$BENCH_OTLP" == "1" ]]; then
  compose_files+=(-f docker-compose.otel.yml)
  export BENCH_OTEL_ENV_FILE
fi

if [[ ! -f "$MODEL_TXT" ]]; then
  echo "Model not found: $MODEL_TXT (set MODEL_TXT=... or export from tools/export_model.py)" >&2
  exit 1
fi

mkdir -p k6/results

# Single env file for ml-model (no compose environment: overrides).
write_ml_model_env_file() {
  local otel_disabled="true"
  if [[ "$BENCH_OTLP" == "1" ]]; then
    otel_disabled="false"
    if [[ ! -f "$BENCH_OTEL_ENV_FILE" ]]; then
      echo "OTLP env file not found: $BENCH_OTEL_ENV_FILE" >&2
      exit 1
    fi
  fi
  {
    if [[ "$BENCH_OTLP" == "1" ]]; then
      grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$BENCH_OTEL_ENV_FILE" || true
    fi
    cat <<EOF
MODEL_API_KEY=benchmark-key
MODEL_DIR=/models
PORT=8456
PREDICT_CONCURRENCY=${PREDICT_CONCURRENCY}
OTEL_SDK_DISABLED=${otel_disabled}
OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=grpc
OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=grpc
OTEL_TRACES_SAMPLER=always_on
EOF
  } > .bench.ml-model.env
}

write_env_file() {
  local scenario="$1" target_rps="$2" duration="$3" vus="$4" summary_file="$5"
  write_ml_model_env_file
  cat > .bench.env <<EOF
MODEL_TXT=${MODEL_TXT}
BENCH_PORT=${BENCH_PORT}
BENCH_CPU=${BENCH_CPU}
PREDICT_CONCURRENCY=${PREDICT_CONCURRENCY}
BENCH_OTLP=${BENCH_OTLP}
BENCH_OTEL_ENV_FILE=${BENCH_OTEL_ENV_FILE}
EOF
  cat > .bench.k6.env <<EOF
BENCH_SCENARIO=${scenario}
BENCH_TARGET_RPS=${target_rps}
BENCH_DURATION=${duration}
BENCH_VUS=${vus}
EOF
  export MODEL_TXT BENCH_PORT BENCH_CPU PREDICT_CONCURRENCY
  K6_EXPORT=(
    -e "BASE_URL=http://ml-model:8456"
    -e "API_KEY=benchmark-key"
    -e "BENCH_SCENARIO=${scenario}"
    -e "BENCH_TARGET_RPS=${target_rps}"
    -e "BENCH_DURATION=${duration}"
    -e "BENCH_VUS=${vus}"
    -e "K6_SUMMARY_FILE=/scripts/results/${summary_file}"
  )
}

start_service() {
  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    docker compose --env-file .bench.env "${compose_files[@]}" build ml-model
  fi
  docker compose --env-file .bench.env "${compose_files[@]}" up -d ml-model
  if [[ "$BENCH_OTLP" == "1" ]]; then
    echo "==> ml-model env file: .bench.ml-model.env"
    grep -E '^OTEL_' .bench.ml-model.env | sort || true
  fi
  echo "==> Waiting for health (port ${BENCH_PORT})..."
  for i in $(seq 1 90); do
    if curl -sf "http://127.0.0.1:${BENCH_PORT}/health-check-AMM" | grep -q '"status":"ok"'; then
      echo "==> Ready (warming model via /predict)..."
      curl -sf -X POST "http://127.0.0.1:${BENCH_PORT}/predict" \
        -H "Content-Type: application/json" -H "X-API-Key: benchmark-key" \
        -d '{"city":"AMM","key":"warm","origin_lat":28,"origin_lng":52,"destination_lat":30.1,"destination_lng":54.1,"created_at":"2024-01-01 00:00:00"}' \
        >/dev/null || true
      return 0
    fi
    if [[ "$i" -eq 90 ]]; then
      docker compose --env-file .bench.env "${compose_files[@]}" logs ml-model >&2
      exit 1
    fi
    sleep 2
  done
}

run_k6() {
  local summary_file="$1"
  echo "==> k6 → ${summary_file}"
  docker compose --env-file .bench.env "${compose_files[@]}" run --rm \
    "${K6_EXPORT[@]}" \
    k6 run /scripts/predict.js || true
  python3 summarize_results.py "k6/results/${summary_file}"
  docker stats --no-stream "$(docker compose --env-file .bench.env "${compose_files[@]}" ps -q ml-model)" 2>/dev/null || true
  echo
}

print_header() {
  echo "========================================"
  echo " CPU limit:     ${BENCH_CPU} cores"
  echo " Memory limit:  1000Mi"
  echo " Model:         $MODEL_TXT"
  if [[ "${PREDICT_CONCURRENCY}" == "0" ]]; then
    echo " Predict pool:  unlimited (semaphore off)"
  else
    echo " Predict pool:  ${PREDICT_CONCURRENCY} concurrent"
  fi
  echo " Profile:       $PROFILE"
  if [[ "$BENCH_OTLP" == "1" ]]; then
    echo " OTLP:          on (${BENCH_OTEL_ENV_FILE})"
  else
    echo " OTLP:          off (BENCH_OTLP=1 to enable)"
  fi
  echo "========================================"
}

docker compose --env-file /dev/null "${compose_files[@]}" down --remove-orphans 2>/dev/null || true

case "$PROFILE" in
  smoke)
    print_header
    write_env_file "smoke" 50 "30s" 5 "summary-smoke.json"
    start_service
    run_k6 "summary-smoke.json"
    ;;
  sustained)
    RPS="${ARG_RPS:-${K6_TARGET_RPS:-50}}"
    DUR="${ARG_DURATION:-${K6_DURATION:-3m}}"
    print_header
    echo " Target RPS:    $RPS for $DUR"
    write_env_file "sustained" "$RPS" "$DUR" 25 "summary-sustained-${RPS}rps.json"
    start_service
    run_k6 "summary-sustained-${RPS}rps.json"
    ;;
  concurrent)
    VUS="${ARG_RPS:-${K6_VUS:-25}}"
    DUR="${ARG_DURATION:-${K6_DURATION:-2m}}"
    print_header
    echo " VUs:           $VUS (max parallel clients) for $DUR"
    write_env_file "concurrent" 0 "$DUR" "$VUS" "summary-concurrent-${VUS}vu.json"
    start_service
    run_k6 "summary-concurrent-${VUS}vu.json"
    ;;
  single_vu)
    DUR="${ARG_DURATION:-${K6_DURATION:-3m}}"
    print_header
    echo " VUs:           1 for $DUR"
    write_env_file "single_vu" 0 "$DUR" 1 "summary-single-vu.json"
    start_service
    run_k6 "summary-single-vu.json"
    ;;
  ramp)
    print_header
    write_env_file "ramp" 0 "4m" 25 "summary-ramp.json"
    start_service
    run_k6 "summary-ramp.json"
    ;;
  cluster_peak)
    print_header
    write_env_file "cluster_peak" 833 "2m" 100 "summary-cluster-833rps.json"
    start_service
    run_k6 "summary-cluster-833rps.json"
    ;;
  suite)
    print_header
    write_env_file "smoke" 50 "30s" 5 "summary-smoke.json"
    start_service
    run_k6 "summary-smoke.json"
    for RPS in 50 100; do
      write_env_file "sustained" "$RPS" "2m" 25 "summary-sustained-${RPS}rps.json"
      run_k6 "summary-sustained-${RPS}rps.json"
    done
    write_env_file "concurrent" 0 "2m" 25 "summary-concurrent-25vu.json"
    run_k6 "summary-concurrent-25vu.json"
    echo "==> Suite complete. See benchmark/k6/results/"
    ;;
  *)
    echo "Unknown profile: $PROFILE" >&2
    exit 1
    ;;
esac

echo "==> Results in benchmark/k6/results/"
