#!/usr/bin/env bash
# Quick check: ml-model → host port-forward → otelcol-gateway (gRPC OTLP on 4317).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_PORT="${BENCH_PORT:-18456}"
GATEWAY_POD="${GATEWAY_POD:-}"

if [[ -z "$GATEWAY_POD" ]]; then
  GATEWAY_POD="$(kubectl -n otel-collector get pods -l app.kubernetes.io/name=otelcol-gateway -o jsonpath='{.items[0].metadata.name}')"
fi

echo "==> Gateway pod: $GATEWAY_POD"
echo "==> Expect kubectl port-forward --address 0.0.0.0 -n otel-collector svc/otelcol-gateway 4317:4317"

kubectl -n otel-collector port-forward "pod/${GATEWAY_POD}" 18888:8888 >/tmp/verify-otlp-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 2

read_counter() {
  curl -sf http://127.0.0.1:18888/metrics | rg 'otelcol_receiver_accepted_spans\{.*transport="grpc"' | awk '{print $2}'
}

BEFORE="$(read_counter || echo 0)"
echo "==> gateway otlp/grpc accepted_spans (before): $BEFORE"

echo "==> Sending 10 /predict requests to :${BENCH_PORT}..."
for _ in $(seq 1 10); do
  curl -sf -X POST "http://127.0.0.1:${BENCH_PORT}/predict" \
    -H "Content-Type: application/json" -H "X-API-Key: benchmark-key" \
    -d '{"city":"AMM","key":"verify-otlp","origin_lat":28,"origin_lng":52,"destination_lat":30.1,"destination_lng":54.1,"created_at":"2024-01-01 00:00:00"}' \
    >/dev/null
done
sleep 5

AFTER="$(read_counter || echo 0)"
echo "==> gateway otlp/grpc accepted_spans (after):  $AFTER"

if awk -v b="$BEFORE" -v a="$AFTER" 'BEGIN { exit (a > b) ? 0 : 1 }'; then
  echo "OK: gateway received OTLP/gRPC (counter increased)."
  echo "    Query traces with: service.name=ml-model-go (resource deployment.environment=staging)"
else
  echo "FAIL: gateway counter did not increase." >&2
  echo "  - Is port-forward to 4317 running (--address 0.0.0.0)?" >&2
  echo "  - Is bench container up with BENCH_OTLP=1? grep OTEL_ benchmark/.bench.ml-model.env" >&2
  echo "  - docker logs <ml-model-container> | head -5  (expect auto-export initialized)" >&2
  exit 1
fi
