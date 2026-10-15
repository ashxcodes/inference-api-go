#!/usr/bin/env bash
# In-cluster multi-city /predict load (same pattern as location-engine/benchmark/run-k6-location-engine.sh).
#
# Fixtures (~600KB/city) use a PVC + kubectl cp (ConfigMaps hit size/annotation limits).
#
#   export NS=otel-collector
#   export BASE_URL='http://inference-api-go.otel-collector.svc.cluster.local:8456'
#   export API_KEY='...'
#   export BENCH_PER_CITY_RPS=20
#   export BENCH_DURATION=30s
#   ./benchmark/run-k6-inference-api-go.sh
#
# Re-copy fixtures: FORCE_FIXTURE_COPY=1 ./benchmark/run-k6-inference-api-go.sh
# First run: SKIP_DELETE=1 ./benchmark/run-k6-inference-api-go.sh
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
  local jeeny="${JEENY_ML_MODEL_ROOT:-$(cd "${ROOT}/../jeeny-ml-model" 2>/dev/null && pwd || echo "")}"
  if [[ -n "${jeeny}" && -f "${jeeny}/benchmark/k6/fixtures/multicity/RUH.json" ]]; then
    echo "${jeeny}/benchmark/k6/fixtures/multicity"
    return
  fi
  echo ""
}

resolve_storage_class() {
  if [[ -n "${STORAGE_CLASS:-}" ]]; then
    echo "${STORAGE_CLASS}"
    return
  fi
  if kubectl get storageclass gp3 >/dev/null 2>&1; then
    echo "gp3"
    return
  fi
  if kubectl get storageclass gp2 >/dev/null 2>&1; then
    echo "gp2"
    return
  fi
  echo ""
}

copy_fixtures_to_pod() {
  local pod="$1"
  local dir="$2"
  for city in "${CITIES[@]}"; do
    local f="${dir}/${city}.json"
    local attempt=1
    while [[ "${attempt}" -le "${CP_RETRIES}" ]]; do
      echo "==> kubectl cp ${city}.json (attempt ${attempt}/${CP_RETRIES})"
      if kubectl cp "${f}" "${NS}/${pod}:/fixtures/${city}.json"; then
        break
      fi
      if [[ "${attempt}" -eq "${CP_RETRIES}" ]]; then
        echo "kubectl cp failed for ${city}.json" >&2
        return 1
      fi
      attempt=$((attempt + 1))
    done
  done
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
FIXTURE_PVC="${FIXTURE_PVC:-inference-api-go-k6-fixtures}"
FIXTURE_PVC_SIZE="${FIXTURE_PVC_SIZE:-1Gi}"
FIXTURE_LOADER_POD="${FIXTURE_LOADER_POD:-inference-api-go-k6-fixtures-loader}"
LOADER_IMAGE="${LOADER_IMAGE:-public.ecr.aws/debian/debian:bookworm-slim}"
CP_RETRIES="${CP_RETRIES:-3}"
FORCE_FIXTURE_COPY="${FORCE_FIXTURE_COPY:-0}"

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

STORAGE_CLASS="$(resolve_storage_class)"
if [[ -z "${STORAGE_CLASS}" ]]; then
  echo "No StorageClass found. Set STORAGE_CLASS (e.g. gp3)." >&2
  exit 1
fi

if [[ "${SKIP_DELETE:-0}" != "1" ]]; then
  echo "==> Delete pod/${K6_POD_NAME} (namespace ${NS})"
  kubectl delete "pod/${K6_POD_NAME}" -n "${NS}" --ignore-not-found=true
else
  echo "==> SKIP_DELETE=1 — not deleting pod/${K6_POD_NAME}"
fi

# Remove legacy per-city fixture ConfigMaps (invalid names / too large).
for legacy in \
  inference-api-go-k6-fixture-RUH inference-api-go-k6-fixture-JED \
  inference-api-go-k6-fixture-AMM inference-api-go-k6-fixture-DMM \
  inference-api-go-k6-fixture-MAD inference-api-go-k6-fixture-MEC \
  inference-api-go-k6-fixture-OtherCities \
  inference-api-go-k6-fixture-ruh inference-api-go-k6-fixture-jed \
  inference-api-go-k6-fixture-amm inference-api-go-k6-fixture-dmm \
  inference-api-go-k6-fixture-mad inference-api-go-k6-fixture-mec \
  inference-api-go-k6-fixture-othercities; do
  kubectl delete configmap "${legacy}" -n "${NS}" --ignore-not-found=true
done

SCRIPT_CM="${CONFIGMAP_PREFIX}-script"
echo "==> ConfigMap ${SCRIPT_CM}"
kubectl delete configmap "${SCRIPT_CM}" -n "${NS}" --ignore-not-found=true
kubectl create configmap "${SCRIPT_CM}" \
  -n "${NS}" \
  --from-file=predict-multicity.js="${BENCH}/k6/predict-multicity.js"

echo "==> PVC ${FIXTURE_PVC} (${FIXTURE_PVC_SIZE}, storageClassName=${STORAGE_CLASS})"
kubectl apply -n "${NS}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${FIXTURE_PVC}
  namespace: ${NS}
spec:
  storageClassName: ${STORAGE_CLASS}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${FIXTURE_PVC_SIZE}
EOF

need_copy="${FORCE_FIXTURE_COPY}"
if [[ "${need_copy}" != "1" ]]; then
  if ! kubectl get pvc "${FIXTURE_PVC}" -n "${NS}" -o jsonpath='{.metadata.annotations.ml-model-go/k6-fixtures-populated}' 2>/dev/null | grep -q '^true$'; then
    need_copy="1"
  fi
fi

if [[ "${need_copy}" == "1" ]]; then
  echo "==> Copy fixtures from ${FIXTURE_DIR} onto PVC"
  kubectl delete "pod/${FIXTURE_LOADER_POD}" -n "${NS}" --ignore-not-found=true --wait=false
  kubectl run "${FIXTURE_LOADER_POD}" -n "${NS}" --restart=Never \
    --image="${LOADER_IMAGE}" \
    --overrides="$(cat <<EOF
{
  "spec": {
    "containers": [{
      "name": "loader",
      "image": "${LOADER_IMAGE}",
      "command": ["sh", "-c", "mkdir -p /fixtures && sleep 3600"],
      "volumeMounts": [{
        "name": "fixtures",
        "mountPath": "/fixtures"
      }]
    }],
    "volumes": [{
      "name": "fixtures",
      "persistentVolumeClaim": {"claimName": "${FIXTURE_PVC}"}
    }]
  }
}
EOF
)"
  kubectl wait -n "${NS}" --for=condition=Ready "pod/${FIXTURE_LOADER_POD}" --timeout=300s
  copy_fixtures_to_pod "${FIXTURE_LOADER_POD}" "${FIXTURE_DIR}"
  kubectl delete "pod/${FIXTURE_LOADER_POD}" -n "${NS}" --wait=false
  kubectl annotate pvc "${FIXTURE_PVC}" -n "${NS}" \
    ml-model-go/k6-fixtures-populated=true --overwrite
else
  echo "==> PVC ${FIXTURE_PVC} already has fixtures (FORCE_FIXTURE_COPY=1 to refresh)"
fi

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
        {
          "name": "k6-script",
          "mountPath": "/scripts/predict-multicity.js",
          "subPath": "predict-multicity.js",
          "readOnly": true
        },
        {
          "name": "k6-fixtures",
          "mountPath": "/scripts/fixtures/multicity",
          "readOnly": true
        }
      ]
    }],
    "volumes": [
      {
        "name": "k6-script",
        "configMap": {
          "name": "${SCRIPT_CM}",
          "items": [{"key": "predict-multicity.js", "path": "predict-multicity.js"}]
        }
      },
      {
        "name": "k6-fixtures",
        "persistentVolumeClaim": {"claimName": "${FIXTURE_PVC}"}
      }
    ]
  }
}
EOF
)"

kubectl wait -n "${NS}" --for=condition=Ready "pod/${K6_POD_NAME}" --timeout=120s 2>/dev/null || true

echo "==> Stream logs: pod/${K6_POD_NAME}"
kubectl logs -n "${NS}" -f "pod/${K6_POD_NAME}"
