#!/usr/bin/env bash
# In-cluster multi-city /predict load (same pattern as location-engine/benchmark/run-k6-location-engine.sh).
#
#   export NS=otel-collector
#   export BASE_URL='http://inference-api-go.otel-collector.svc.cluster.local:8456'
#   export API_KEY='...'
#   export BENCH_PER_CITY_RPS=20
#   export BENCH_DURATION=30s
#   ./benchmark/run-k6-inference-api-go.sh
#
# First run: SKIP_DELETE=1 ./benchmark/run-k6-inference-api-go.sh
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${BENCH}/.." && pwd)"
CITIES=(RUH JED AMM DMM MAD MEC OtherCities)

# ConfigMap names must be lowercase RFC 1123 (no "RUH" / "OtherCities" in the name).
city_cm_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

resolve_fixtures() {
  if [[ -n "${FIXTURES_DIR:-}" ]]; then
    echo "${FIXTURES_DIR}"
    return
  fi
  if [[ -f "${BENCH}/k6/fixtures/multicity/RUH.json" ]]; then
    echo "${BENCH}/k6/fixtures/multicity"
    return
  fi
  local jeeny="${JEENY_ML_MODEL_ROOT:-$(cd "${ROOT}/../jeeny-ml-model" 2>/dev/null && pwd || echo "")}"
  if [[ -n "${jeeny}" && -f "${jeeny}/benchmark/k6/fixtures/multicity/RUH.json" ]]; then
    echo "${jeeny}/benchmark/k6/fixtures/multicity"
    return
  fi
  echo ""
}

FIXTURE_DIR="$(resolve_fixtures)"
if [[ -z "${FIXTURE_DIR}" ]]; then
  echo "Multicity fixtures not found. Set FIXTURES_DIR or JEENY_ML_MODEL_ROOT." >&2
  exit 1
fi

NS="${NS:-otel-collector}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
K6_POD_NAME="${K6_POD_NAME:-k6-inference-api-go-multicity}"
CONFIGMAP_PREFIX="${CONFIGMAP_PREFIX:-inference-api-go-k6}"

BASE_URL="${BASE_URL:-${TARGET:-http://inference-api-go.otel-collector.svc.cluster.local:8456}}"
BASE_URL="${BASE_URL%/}"
API_KEY="${API_KEY:?Set API_KEY}"
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
echo "==> ConfigMap ${SCRIPT_CM}"
kubectl delete configmap "${SCRIPT_CM}" -n "${NS}" --ignore-not-found=true
kubectl create configmap "${SCRIPT_CM}" \
  -n "${NS}" \
  --from-file=predict-multicity.js="${BENCH}/k6/predict-multicity.js"

for city in "${CITIES[@]}"; do
  slug="$(city_cm_slug "${city}")"
  cm="${CONFIGMAP_PREFIX}-fixture-${slug}"
  echo "==> ConfigMap ${cm} (${city}.json)"
  kubectl delete configmap "${cm}" -n "${NS}" --ignore-not-found=true
  # Large fixtures: avoid kubectl apply (last-applied-configuration annotation >256KiB).
  kubectl create configmap "${cm}" \
    -n "${NS}" \
    --from-file="${city}.json=${FIXTURE_DIR}/${city}.json"
done

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
    slug = city.lower()
    sources.append(
        {
            "configMap": {
                "name": f"{prefix}-fixture-{slug}",
                "items": [{"key": f"{city}.json", "path": f"fixtures/multicity/{city}.json"}],
            }
        }
    )
print(json.dumps(sources))
PY
)"

TOTAL_RPS=$((BENCH_PER_CITY_RPS * 7))
echo "==> Start k6 pod (${BENCH_PER_CITY_RPS} RPS × 7 = ${TOTAL_RPS}, ${BENCH_DURATION}) -> ${BASE_URL}"

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

kubectl wait -n "${NS}" --for=condition=Ready "pod/${K6_POD_NAME}" --timeout=120s 2>/dev/null || true

echo "==> Stream logs: pod/${K6_POD_NAME}"
kubectl logs -n "${NS}" -f "pod/${K6_POD_NAME}"
