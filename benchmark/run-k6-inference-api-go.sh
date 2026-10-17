#!/usr/bin/env bash
# In-cluster multi-city /predict load (same pattern as location-engine/benchmark/run-k6-location-engine.sh).
#
# Fixtures (~600KB/city) use a PVC + kubectl cp (ConfigMaps hit size/annotation limits).
#
#   Application: repo .env (MODEL_API_KEY for X-API-Key)
#   K8s/bench: NS, BASE_URL, BENCH_* (defaults in this script)
#   ./benchmark/run-k6-inference-api-go.sh
#
# Re-copy fixtures: FORCE_FIXTURE_COPY=1 ./benchmark/run-k6-inference-api-go.sh
# First run: SKIP_DELETE=1 ./benchmark/run-k6-inference-api-go.sh
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${BENCH}/.." && pwd)"
CITIES=(RUH JED AMM DMM MAD MEC OtherCities)

# shellcheck source=dotenv.sh
source "${BENCH}/dotenv.sh"
load_app_dotenv "${ROOT}" || exit 1
print_app_env_summary "${ROOT}" || exit 1
API_KEY="${MODEL_API_KEY:?Set MODEL_API_KEY in repo .env}"

# --- K8s / load test (not application .env) ---
NS="${NS:-otel-collector}"
SVC_NAME="${SVC_NAME:-inference-api-go}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
K6_POD_NAME="${K6_POD_NAME:-k6-inference-api-go-multicity}"
CONFIGMAP_PREFIX="${CONFIGMAP_PREFIX:-inference-api-go-k6}"
FIXTURE_PVC="${FIXTURE_PVC:-inference-api-go-k6-fixtures}"
FIXTURE_PVC_SIZE="${FIXTURE_PVC_SIZE:-1Gi}"
FIXTURE_LOADER_POD="${FIXTURE_LOADER_POD:-inference-api-go-k6-fixtures-loader}"
LOADER_IMAGE="${LOADER_IMAGE:-public.ecr.aws/debian/debian:bookworm-slim}"
CP_RETRIES="${CP_RETRIES:-3}"
FORCE_FIXTURE_COPY="${FORCE_FIXTURE_COPY:-0}"
# Short cluster DNS (same namespace); override with BASE_URL if needed.
BASE_URL="${BASE_URL:-http://${SVC_NAME}:8456}"
INFERENCE_POD="${INFERENCE_POD:-${SVC_NAME}}"
BASE_URL="${BASE_URL%/}"
BENCH_PER_CITY_RPS="${BENCH_PER_CITY_RPS:-20}"
BENCH_DURATION="${BENCH_DURATION:-30s}"
BENCH_STRICT="${BENCH_STRICT:-0}"
BENCH_POD_ANTIAFFINITY="${BENCH_POD_ANTIAFFINITY:-preferred}"

echo ""
echo "── k6 load test ──"
echo "  BASE_URL:           ${BASE_URL}"
echo "  BENCH_PER_CITY_RPS: ${BENCH_PER_CITY_RPS}  (×7 cities)"
echo "  BENCH_DURATION:     ${BENCH_DURATION}"
echo "  API_KEY:            $(mask_secret "${API_KEY}")"
echo ""
echo "  Under load, failed/timed-out requests = capacity limit for the current inference pod config."
echo "  Summary reports attempted vs successful RPS and an estimated ceiling."
echo ""

if ! bench_confirm "Start k6 multicity load?"; then
  echo "Aborted."
  exit 0
fi

if [[ "${SKIP_INFERENCE_WAIT:-0}" != "1" ]]; then
  kubectl wait -n "${NS}" --for=condition=Ready "pod/${INFERENCE_POD}" --timeout=600s 2>/dev/null || true
  wait_for_inference_service "${NS}" "${SVC_NAME}" "${BASE_URL}" || exit 1
fi

fixtures_ok() {
  [[ -f "${1}/RUH.json" ]]
}

resolve_fixtures() {
  if [[ -n "${FIXTURES_DIR:-}" ]]; then
    if fixtures_ok "${FIXTURES_DIR}"; then
      echo "${FIXTURES_DIR}"
      return
    fi
    echo "FIXTURES_DIR=${FIXTURES_DIR} but RUH.json is missing (need 7 city JSON files, not ml-models/*.txt)." >&2
    return 1
  fi

  local candidates=(
    "${BENCH}/k6/fixtures/multicity"
  )
  if [[ -n "${JEENY_ML_MODEL_ROOT:-}" ]]; then
    candidates+=("${JEENY_ML_MODEL_ROOT}/benchmark/k6/fixtures/multicity")
  fi
  local jeeny_guess
  for jeeny_guess in \
    "${ROOT}/../jeeny-ml-model" \
    "${ROOT}/../Work/Repos/jeeny-ml-model" \
    "${HOME}/Work/Repos/jeeny-ml-model" \
    "${HOME}/personal/jeeny-ml-model"; do
    if [[ -d "${jeeny_guess}" ]]; then
      candidates+=("$(cd "${jeeny_guess}" && pwd)/benchmark/k6/fixtures/multicity")
    fi
  done

  local dir
  for dir in "${candidates[@]}"; do
    if fixtures_ok "${dir}"; then
      echo "${dir}"
      return
    fi
  done
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

FIXTURE_DIR="$(resolve_fixtures)" || exit 1
if [[ -z "${FIXTURE_DIR}" ]]; then
  cat >&2 <<EOF
Multicity k6 fixtures not found (MODELS_DIR is for inference *.txt only).

git pull — fixtures live under benchmark/k6/fixtures/multicity/
Or: export FIXTURES_DIR=/path/to/dir-with-RUH.json
EOF
  exit 1
fi

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
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Override for ladders: K6_SUMMARY_LOCAL=.../summary-c1-40rps.json
SUMMARY_LOCAL="${K6_SUMMARY_LOCAL:-${BENCH}/k6/results/summary-multicity-incluster-${STAMP}.json}"
# Optional: also tee k6 stdout to a host file (pod cannot mount your laptop).
LOG_LOCAL="${K6_LOG_LOCAL:-}"
mkdir -p "$(dirname "${SUMMARY_LOCAL}")"
[[ -n "${LOG_LOCAL}" ]] && mkdir -p "$(dirname "${LOG_LOCAL}")"
BENCH_POD_EXTRAS="$(bench_k8s_pod_extras k6)"
echo "==> Start k6 pod (${BENCH_PER_CITY_RPS} RPS × 7 = ${TOTAL_RPS}, ${BENCH_DURATION}) -> ${BASE_URL}"
echo "==> Pod anti-affinity: ${BENCH_POD_ANTIAFFINITY} (prefer different node than inference)"
echo "==> Summary JSON will be copied to: ${SUMMARY_LOCAL}"
[[ -n "${LOG_LOCAL}" ]] && echo "==> k6 logs will be teed to: ${LOG_LOCAL}"

export K6_IMAGE BASE_URL API_KEY BENCH_PER_CITY_RPS BENCH_DURATION BENCH_STRICT SCRIPT_CM FIXTURE_PVC BENCH_POD_EXTRAS
kubectl run "${K6_POD_NAME}" -n "${NS}" --restart=Never \
  --image="${K6_IMAGE}" \
  --overrides="$(python3 - <<'PY'
import json, os

extras = json.loads(os.environ["BENCH_POD_EXTRAS"])
spec = {
  "containers": [{
    "name": "k6",
    "image": os.environ["K6_IMAGE"],
    "command": [
      "k6", "run",
      "--summary-trend-stats=avg,min,med,p(90),p(95),p(99),max",
      "--insecure-skip-tls-verify",
      "/scripts/predict-multicity.js",
    ],
    "env": [
      {"name": "BASE_URL", "value": os.environ["BASE_URL"]},
      {"name": "API_KEY", "value": os.environ["API_KEY"]},
      {"name": "BENCH_PER_CITY_RPS", "value": os.environ["BENCH_PER_CITY_RPS"]},
      {"name": "BENCH_DURATION", "value": os.environ["BENCH_DURATION"]},
      {"name": "BENCH_STRICT", "value": os.environ["BENCH_STRICT"]},
      {"name": "FIXTURE_DIR", "value": "/scripts/fixtures/multicity"},
      {"name": "K6_SUMMARY_FILE", "value": "/summary/k6-summary.json"},
      {"name": "K6_LOG_LEVEL", "value": "error"},
    ],
    "volumeMounts": [
      {
        "name": "k6-script",
        "mountPath": "/scripts/predict-multicity.js",
        "subPath": "predict-multicity.js",
        "readOnly": True,
      },
      {
        "name": "k6-fixtures",
        "mountPath": "/scripts/fixtures/multicity",
        "readOnly": True,
      },
      {"name": "k6-summary", "mountPath": "/summary"},
    ],
  }],
  "volumes": [
    {
      "name": "k6-script",
      "configMap": {
        "name": os.environ["SCRIPT_CM"],
        "items": [{"key": "predict-multicity.js", "path": "predict-multicity.js"}],
      },
    },
    {
      "name": "k6-fixtures",
      "persistentVolumeClaim": {"claimName": os.environ["FIXTURE_PVC"]},
    },
    {"name": "k6-summary", "emptyDir": {}},
  ],
}
if extras.get("spec", {}).get("affinity"):
  spec["affinity"] = extras["spec"]["affinity"]
pod = {"metadata": extras.get("metadata", {}), "spec": spec}
print(json.dumps(pod))
PY
)"

kubectl wait -n "${NS}" --for=condition=Ready "pod/${K6_POD_NAME}" --timeout=120s 2>/dev/null || true

echo "==> Stream logs: pod/${K6_POD_NAME}"
if [[ -n "${LOG_LOCAL}" ]]; then
  kubectl logs -n "${NS}" -f "pod/${K6_POD_NAME}" 2>&1 | tee "${LOG_LOCAL}" || true
else
  kubectl logs -n "${NS}" -f "pod/${K6_POD_NAME}" || true
fi

echo "==> Wait for k6 to finish"
kubectl wait -n "${NS}" --for=jsonpath='{.status.phase}'=Succeeded "pod/${K6_POD_NAME}" --timeout=7200s 2>/dev/null \
  || kubectl wait -n "${NS}" --for=jsonpath='{.status.phase}'=Failed "pod/${K6_POD_NAME}" --timeout=120s 2>/dev/null \
  || true

if kubectl cp "${NS}/${K6_POD_NAME}:/summary/k6-summary.json" "${SUMMARY_LOCAL}" 2>/dev/null; then
  echo "==> Summary JSON: ${SUMMARY_LOCAL}"
  if [[ -n "${LOG_LOCAL}" ]]; then
    python3 "${BENCH}/summarize_results.py" "${SUMMARY_LOCAL}" | tee -a "${LOG_LOCAL}" || true
  else
    python3 "${BENCH}/summarize_results.py" "${SUMMARY_LOCAL}" || true
  fi
else
  echo "WARN: could not copy /summary/k6-summary.json (see k6 stdout above for === multicity load ===)" >&2
fi
