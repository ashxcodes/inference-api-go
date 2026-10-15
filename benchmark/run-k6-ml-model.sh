#!/usr/bin/env bash
# In-cluster multi-city /predict load (same pattern as location-engine/benchmark/run-k6-location-engine.sh).
#
#   export NS=otel-collector
#   export BASE_URL='http://ml-model.ml-model.svc.cluster.local:8456'
#   export API_KEY='...'   # MODEL_API_KEY
#   export BENCH_PER_CITY_RPS=50
#   export BENCH_DURATION=5m
#   ./benchmark/run-k6-ml-model.sh
#
# Fixtures: benchmark/k6/fixtures/multicity/ or FIXTURES_DIR.
# First run: SKIP_DELETE=1 ./benchmark/run-k6-ml-model.sh
#
# App OTEL: OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol-gateway.otel-collector.svc.cluster.local:4317
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${BENCH}/.." && pwd)"
CITIES=(RUH JED AMM DMM MAD MEC OtherCities)

resolve_fixtures() {
  if [[ -n "${FIXTURES_DIR:-}" ]]; then
    echo "${FIXTURES_DIR}"
    return
  fi
  if [[ -f "${BENCH}/k6/fixtures/multicity/RUH.json" ]]; then
    echo "${BENCH}/k6/fixtures/multicity"
    return
  fi
  echo ""
}

FIXTURE_DIR="$(resolve_fixtures)"
if [[ -z "${FIXTURE_DIR}" ]]; then
  echo "Multicity fixtures not found. Set FIXTURES_DIR or generate under benchmark/k6/fixtures/multicity/." >&2
  exit 1
fi

NS="${NS:-otel-collector}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
K6_POD_NAME="${K6_POD_NAME:-k6-ml-model-go-multicity}"
CONFIGMAP_PREFIX="${CONFIGMAP_PREFIX:-ml-model-go-k6}"
WAIT_AFTER_CONFIGMAP_SEC="${WAIT_AFTER_CONFIGMAP_SEC:-5}"
WAIT_BEFORE_LOGS_SEC="${WAIT_BEFORE_LOGS_SEC:-5}"

ML_NS="${ML_MODEL_NAMESPACE:-ml-model}"
ML_SVC="${ML_MODEL_SERVICE:-ml-model}"
DEFAULT_BASE="http://${ML_SVC}.${ML_NS}.svc.cluster.local:8456"

BASE_URL="${BASE_URL:-${TARGET:-${DEFAULT_BASE}}}"
BASE_URL="${BASE_URL%/}"
API_KEY="${API_KEY:?Set API_KEY (MODEL_API_KEY)}"
BENCH_PER_CITY_RPS="${BENCH_PER_CITY_RPS:-50}"
BENCH_DURATION="${BENCH_DURATION:-5m}"
BENCH_STRICT="${BENCH_STRICT:-0}"

for city in "${CITIES[@]}"; do
  if [[ ! -f "${FIXTURE_DIR}/${city}.json" ]]; then
    echo "Missing ${FIXTURE_DIR}/${city}.json" >&2
    exit 1
  fi
done

if [[ "${SKIP_DELETE:-0}" != "1" ]]; then
  echo "==> Delete pod/${K6_POD_NAME} (namespace ${NS})"
  kubectl delete "pod/${K6_POD_NAME}" -n "${NS}" --ignore-not-found=true
else
  echo "==> SKIP_DELETE=1 — not deleting pod/${K6_POD_NAME}"
fi

SCRIPT_CM="${CONFIGMAP_PREFIX}-script"
echo "==> Apply ConfigMap ${SCRIPT_CM}"
kubectl create configmap "${SCRIPT_CM}" \
  -n "${NS}" \
  --from-file=predict-multicity.js="${BENCH}/k6/predict-multicity.js" \
  --dry-run=client -o yaml | kubectl apply -n "${NS}" -f -

for city in "${CITIES[@]}"; do
  cm="${CONFIGMAP_PREFIX}-fixture-${city}"
  echo "==> Apply ConfigMap ${cm}"
  kubectl create configmap "${cm}" \
    -n "${NS}" \
    --from-file="${city}.json=${FIXTURE_DIR}/${city}.json" \
    --dry-run=client -o yaml | kubectl apply -n "${NS}" -f -
done

echo "==> Wait ${WAIT_AFTER_CONFIGMAP_SEC}s after ConfigMap apply"
sleep "${WAIT_AFTER_CONFIGMAP_SEC}"

PROJECTED_JSON="$(python3 - "${CONFIGMAP_PREFIX}" <<'PY'
import json, sys
prefix = sys.argv[1]
cities = ["RUH", "JED", "AMM", "DMM", "MAD", "MEC", "OtherCities"]
sources = [
    {
        "configMap": {
            "name": f"{prefix}-script",
            "items": [{"key": "predict-multicity.js", "path": "predict-multicity.js"}],
        }
    }
]
for city in cities:
    sources.append(
        {
            "configMap": {
                "name": f"{prefix}-fixture-{city}",
                "items": [{"key": f"{city}.json", "path": f"fixtures/multicity/{city}.json"}],
            }
        }
    )
print(json.dumps(sources))
PY
)"

TOTAL_RPS=$((BENCH_PER_CITY_RPS * 7))
echo "==> Fixtures: ${FIXTURE_DIR}"
echo "==> Start k6 pod (${BENCH_PER_CITY_RPS} RPS × 7 = ${TOTAL_RPS} total, ${BENCH_DURATION}) -> ${BASE_URL}"

kubectl run "${K6_POD_NAME}" -n "${NS}" --restart=Never \
  --image="${K6_IMAGE}" \
  --overrides="$(cat <<EOF
{
  "spec": {
    "containers": [{
      "name": "k6",
      "image": "${K6_IMAGE}",
      "command": [
        "k6", "run", "--no-thresholds", "--insecure-skip-tls-verify",
        "/scripts/predict-multicity.js"
      ],
      "env": [
        {"name": "BASE_URL", "value": "${BASE_URL}"},
        {"name": "API_KEY", "value": "${API_KEY}"},
        {"name": "BENCH_PER_CITY_RPS", "value": "${BENCH_PER_CITY_RPS}"},
        {"name": "BENCH_DURATION", "value": "${BENCH_DURATION}"},
        {"name": "BENCH_STRICT", "value": "${BENCH_STRICT}"},
        {"name": "FIXTURE_DIR", "value": "/scripts/fixtures/multicity"}
      ],
      "resources": {
        "requests": {"cpu": "2", "memory": "2Gi"},
        "limits": {"cpu": "8", "memory": "8Gi"}
      },
      "volumeMounts": [
        {"name": "scripts", "mountPath": "/scripts"}
      ]
    }],
    "volumes": [{
      "name": "scripts",
      "projected": {
        "sources": ${PROJECTED_JSON}
      }
    }]
  }
}
EOF
)"

echo "==> Wait ${WAIT_BEFORE_LOGS_SEC}s for pod to start"
sleep "${WAIT_BEFORE_LOGS_SEC}"

echo "==> Stream logs: pod/${K6_POD_NAME}"
kubectl logs -n "${NS}" -f "pod/${K6_POD_NAME}"
