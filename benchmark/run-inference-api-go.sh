#!/usr/bin/env bash
# Run inference-api-go in otel-collector.
#
# Models: PVC + one-time kubectl cp from MODELS_DIR (ConfigMaps cannot hold multi-MB .txt files).
#
#   Application: repo .env (MODEL_API_KEY, OTEL_*, MODEL_DIR, …)
#   K8s/bench: export IMAGE=… (and optional NS, MODELS_DIR, …) before running.
#   ./benchmark/run-inference-api-go.sh
#
# Re-copy models: FORCE_MODEL_COPY=1 ./benchmark/run-inference-api-go.sh
# Image already has /models: MODELS_FROM_IMAGE=1 ./benchmark/run-inference-api-go.sh
# First run: SKIP_DELETE=1 ./benchmark/run-inference-api-go.sh
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${BENCH}/.." && pwd)"

# shellcheck source=dotenv.sh
source "${BENCH}/dotenv.sh"
# --- K8s / bench (not application .env) ---
NS="${NS:-otel-collector}"

load_app_dotenv "${ROOT}" || exit 1
print_app_env_summary "${ROOT}" "${NS}" || exit 1
POD_NAME="${POD_NAME:-inference-api-go}"
SVC_NAME="${SVC_NAME:-inference-api-go}"
LOADER_POD="${LOADER_POD:-inference-api-go-models-loader}"
MODELS_DIR="${MODELS_DIR:-${ROOT}/ml-models}"
PVC_NAME="${PVC_NAME:-inference-api-go-models}"
PVC_SIZE="${PVC_SIZE:-2Gi}"
# kubectl cp requires tar in the container (aws-cli image does not include it).
LOADER_IMAGE="${LOADER_IMAGE:-public.ecr.aws/debian/debian:bookworm-slim}"
CP_RETRIES="${CP_RETRIES:-3}"

IMAGE="${IMAGE:-}"
bench_prompt_nonempty IMAGE "Container IMAGE (ghcr.io/ashxcodes/inference-api-go:<git-sha>)" || exit 1

echo ""
echo "── Kubernetes / bench ──"
echo "  NS:          ${NS}"
echo "  IMAGE:       ${IMAGE}"
echo "  MODELS_DIR:  ${MODELS_DIR}"
echo "  MODELS_FROM_IMAGE: ${MODELS_FROM_IMAGE:-0}"
echo ""

if ! bench_confirm "Deploy inference-api-go with these settings?"; then
  echo "Aborted."
  exit 0
fi

MODEL_API_KEY="${MODEL_API_KEY:?Set MODEL_API_KEY in repo .env}"
OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:?Set OTEL_EXPORTER_OTLP_ENDPOINT in repo .env}"

copy_models_to_pod() {
  local pod="$1"
  local dir="$2"
  shopt -s nullglob
  local files=("${dir}"/*.txt)
  shopt -u nullglob
  for f in "${files[@]}"; do
    local base
    base="$(basename "${f}")"
    local attempt=1
    while [[ "${attempt}" -le "${CP_RETRIES}" ]]; do
      echo "==> kubectl cp ${base} (attempt ${attempt}/${CP_RETRIES})"
      if kubectl cp "${f}" "${NS}/${pod}:/models/${base}"; then
        break
      fi
      if [[ "${attempt}" -eq "${CP_RETRIES}" ]]; then
        echo "kubectl cp failed for ${base}" >&2
        return 1
      fi
      attempt=$((attempt + 1))
    done
  done
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

STORAGE_CLASS="$(resolve_storage_class)"
MODELS_FROM_IMAGE="${MODELS_FROM_IMAGE:-0}"
FORCE_MODEL_COPY="${FORCE_MODEL_COPY:-0}"

if [[ "${MODELS_FROM_IMAGE}" != "1" ]]; then
  if [[ ! -d "${MODELS_DIR}" ]]; then
    echo "MODELS_DIR not found: ${MODELS_DIR}" >&2
    exit 1
  fi
  if ! compgen -G "${MODELS_DIR}/*.txt" >/dev/null; then
    echo "No *.txt under ${MODELS_DIR}" >&2
    exit 1
  fi
fi

if [[ "${SKIP_DELETE:-0}" != "1" ]]; then
  echo "==> Delete pod/${POD_NAME} svc/${SVC_NAME} (namespace ${NS})"
  kubectl delete "pod/${POD_NAME}" -n "${NS}" --ignore-not-found=true
  kubectl delete "svc/${SVC_NAME}" -n "${NS}" --ignore-not-found=true
else
  echo "==> SKIP_DELETE=1 — not deleting pod/${POD_NAME}"
fi

USE_PVC="0"
if [[ "${MODELS_FROM_IMAGE}" != "1" ]]; then
  USE_PVC="1"
  if [[ -z "${STORAGE_CLASS}" ]]; then
    echo "No StorageClass found. Set STORAGE_CLASS (e.g. gp3) or create a default SC." >&2
    exit 1
  fi
  echo "==> Ensure PVC ${PVC_NAME} (${PVC_SIZE}, storageClassName=${STORAGE_CLASS})"
  # Replace PVC if it was created without storageClassName (stays Pending forever).
  existing_sc="$(kubectl get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
  if [[ -n "${existing_sc}" && "${existing_sc}" != "${STORAGE_CLASS}" ]]; then
    echo "==> Delete PVC ${PVC_NAME} (was storageClassName=${existing_sc:-<unset>})"
    kubectl delete pvc "${PVC_NAME}" -n "${NS}" --wait=true
  elif kubectl get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Pending; then
    if [[ -z "${existing_sc}" ]]; then
      echo "==> Delete stuck Pending PVC ${PVC_NAME} (no storageClassName)"
      kubectl delete pvc "${PVC_NAME}" -n "${NS}" --wait=true
    fi
  fi
  kubectl apply -n "${NS}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NS}
spec:
  storageClassName: ${STORAGE_CLASS}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF

  need_copy="${FORCE_MODEL_COPY}"
  if [[ "${need_copy}" != "1" ]]; then
    if ! kubectl get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.metadata.annotations.ml-model-go/models-populated}' 2>/dev/null | grep -q '^true$'; then
      need_copy="1"
    fi
  fi

  if [[ "${need_copy}" == "1" ]]; then
    echo "==> Copy models from ${MODELS_DIR} onto PVC (via ${LOADER_POD})"
    kubectl delete "pod/${LOADER_POD}" -n "${NS}" --ignore-not-found=true --wait=false

    kubectl run "${LOADER_POD}" -n "${NS}" --restart=Never \
      --image="${LOADER_IMAGE}" \
      --overrides="$(cat <<EOF
{
  "spec": {
    "containers": [{
      "name": "loader",
      "image": "${LOADER_IMAGE}",
      "command": ["sh", "-c", "mkdir -p /models && sleep 3600"],
      "volumeMounts": [{
        "name": "models",
        "mountPath": "/models"
      }]
    }],
    "volumes": [{
      "name": "models",
      "persistentVolumeClaim": {"claimName": "${PVC_NAME}"}
    }]
  }
}
EOF
)"

    kubectl wait -n "${NS}" --for=condition=Ready "pod/${LOADER_POD}" --timeout=300s
    echo "==> Copy *.txt to PVC (one file at a time; ~600MB total)"
    copy_models_to_pod "${LOADER_POD}" "${MODELS_DIR}"
    kubectl delete "pod/${LOADER_POD}" -n "${NS}" --wait=false

    kubectl annotate pvc "${PVC_NAME}" -n "${NS}" \
      ml-model-go/models-populated=true --overwrite
  else
    echo "==> PVC ${PVC_NAME} already populated (set FORCE_MODEL_COPY=1 to refresh)"
  fi
fi

CONTAINER_APP_ENV_JSON="$(container_app_env_json "${ROOT}" "${NS}" "${POD_NAME}")"
BENCH_POD_EXTRAS="$(bench_k8s_pod_extras inference)"
export IMAGE USE_PVC PVC_NAME CONTAINER_APP_ENV_JSON BENCH_POD_EXTRAS
echo "==> Pod anti-affinity: ${BENCH_POD_ANTIAFFINITY:-preferred} (not on same node as k6)"

echo "==> Start pod/${POD_NAME} image=${IMAGE}"
kubectl run "${POD_NAME}" -n "${NS}" --restart=Never \
  --image="${IMAGE}" \
  --image-pull-policy=Always \
  --port=8456 \
  --overrides="$(python3 - <<'PY'
import json, os

image = os.environ["IMAGE"]
use_pvc = os.environ["USE_PVC"] == "1"
pvc = os.environ["PVC_NAME"]
env_list = json.loads(os.environ["CONTAINER_APP_ENV_JSON"])
extras = json.loads(os.environ["BENCH_POD_EXTRAS"])

container = {
  "name": "app",
  "image": image,
  "imagePullPolicy": "Always",
  "ports": [{"containerPort": 8456}],
  "env": env_list,
  "readinessProbe": {
    "httpGet": {"path": "/readyz", "port": 8456},
    "initialDelaySeconds": 30,
    "periodSeconds": 10,
    "timeoutSeconds": 2,
  },
  "livenessProbe": {
    "httpGet": {"path": "/healthz", "port": 8456},
    "initialDelaySeconds": 60,
    "periodSeconds": 30,
    "timeoutSeconds": 2,
  },
  "resources": {
    "requests": {"cpu": "1000m", "memory": "2Gi"},
    "limits": {"cpu": "1000m", "memory": "2Gi"},
  },
}

spec = {"containers": [container]}
if use_pvc:
  container["volumeMounts"] = [{
    "name": "models",
    "mountPath": "/models",
    "readOnly": True,
  }]
  spec["volumes"] = [{
    "name": "models",
    "persistentVolumeClaim": {"claimName": pvc},
  }]

if extras.get("spec", {}).get("affinity"):
  spec["affinity"] = extras["spec"]["affinity"]

pod = {"metadata": extras.get("metadata", {}), "spec": spec}
print(json.dumps(pod))
PY
)"

kubectl expose pod "${POD_NAME}" -n "${NS}" --name="${SVC_NAME}" --port=8456 --target-port=8456

echo "==> Wait for Ready"
kubectl wait -n "${NS}" --for=condition=Ready "pod/${POD_NAME}" --timeout=600s

echo ""
echo "BASE_URL for k6:"
echo "  http://${SVC_NAME}.${NS}.svc.cluster.local:8456"
