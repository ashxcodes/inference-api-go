#!/usr/bin/env bash
# Deploy a single-pod inference-api-go bench server in the cluster (local image or kind).
#
# Usage:
#   export API_KEY='...'
#   export MODEL_HOST_PATH=/path/to/dir/with/RUH.txt,...   # hostPath on node
#   LOCAL_K8S=1 ./benchmark/k8s/deploy-bench-server.sh
#
# Or use a pre-built image (e.g. from GHCR):
#   IMAGE=ghcr.io/ashxcodes/inference-api-go:latest ./benchmark/k8s/deploy-bench-server.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NS="${APP_NS:-ml-model}"
POD_NAME="${POD_NAME:-ml-model-go-bench}"
SVC_NAME="${SVC_NAME:-ml-model-go-bench}"
LOCAL_IMAGE="${LOCAL_IMAGE:-ml-model-go:bench-local}"
DOCKERFILE="${DOCKERFILE:-${ROOT}/Dockerfile}"
MODEL_HOST_PATH="${MODEL_HOST_PATH:-${ROOT}/ml-models}"
KIND_CLUSTER="${KIND_CLUSTER:-kind}"

API_KEY="${API_KEY:?Set API_KEY (MODEL_API_KEY)}"
LOCAL_K8S="${LOCAL_K8S:-0}"

if [[ -z "${IMAGE:-}" ]]; then
  if [[ "${LOCAL_K8S}" != "1" ]]; then
    echo "Set LOCAL_K8S=1 to build/load a local image, or set IMAGE to an existing registry tag." >&2
    exit 1
  fi

  if [[ "${EMBED_MODELS:-0}" == "1" ]]; then
    if [[ ! -d "${MODEL_HOST_PATH}" ]]; then
      echo "EMBED_MODELS=1 requires MODEL_HOST_PATH with *.txt" >&2
      exit 1
    fi
    echo "==> docker build (embed models from ${MODEL_HOST_PATH})"
    tmpdf="$(mktemp)"
    cat >"${tmpdf}" <<EOF
FROM golang:1.25-bookworm AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/server /server
COPY models /models
ENV MODEL_DIR=/models PORT=8456
USER nonroot:nonroot
EXPOSE 8456
ENTRYPOINT ["/server"]
EOF
    rm -rf "${ROOT}/.bench-docker-models"
    cp -a "${MODEL_HOST_PATH}" "${ROOT}/.bench-docker-models/models"
    docker build -t "${LOCAL_IMAGE}" -f "${tmpdf}" "${ROOT}"
    rm -rf "${ROOT}/.bench-docker-models"
    rm -f "${tmpdf}"
  else
    echo "==> docker build -t ${LOCAL_IMAGE}"
    docker build -t "${LOCAL_IMAGE}" -f "${DOCKERFILE}" "${ROOT}"
  fi
  IMAGE="${LOCAL_IMAGE}"
fi

PULL_POLICY="IfNotPresent"
if [[ "${IMAGE}" != "${LOCAL_IMAGE}" ]]; then
  PULL_POLICY="Always"
fi

if [[ "${LOCAL_K8S}" == "1" && "${IMAGE}" == "${LOCAL_IMAGE}" ]]; then
  if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
    echo "==> kind load docker-image ${LOCAL_IMAGE}"
    kind load docker-image "${LOCAL_IMAGE}" --name "${KIND_CLUSTER}"
  else
    echo "==> LOCAL_K8S: using image ${LOCAL_IMAGE} with imagePullPolicy=IfNotPresent"
  fi
  if [[ ! -d "${MODEL_HOST_PATH}" ]]; then
    echo "MODEL_HOST_PATH not a directory: ${MODEL_HOST_PATH}" >&2
    echo "Put all {CITY}.txt under this path for hostPath mount." >&2
    exit 1
  fi
fi

OTEL_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://otelcol-gateway.otel-collector.svc.cluster.local:4317}"

MODEL_VOLUME_JSON='{"name":"models","emptyDir":{}}'
MODEL_MOUNT_JSON='{"name":"models","mountPath":"/models","readOnly":true}'
if [[ "${LOCAL_K8S}" == "1" ]]; then
  MODEL_VOLUME_JSON="$(python3 - <<PY
import json, os
print(json.dumps({
  "name": "models",
  "hostPath": {"path": os.environ["MODEL_HOST_PATH"], "type": "Directory"},
}))
PY
)"
fi

export MODEL_HOST_PATH IMAGE PULL_POLICY API_KEY OTEL_ENDPOINT MODEL_VOLUME_JSON MODEL_MOUNT_JSON
kubectl delete pod/"${POD_NAME}" -n "${APP_NS}" --ignore-not-found=true
kubectl delete svc/"${SVC_NAME}" -n "${APP_NS}" --ignore-not-found=true

echo "==> Create pod/${POD_NAME} image=${IMAGE}"
kubectl run "${POD_NAME}" -n "${APP_NS}" --restart=Never \
  --image="${IMAGE}" \
  --image-pull-policy="${PULL_POLICY}" \
  --port=8456 \
  --overrides="$(python3 - <<PY
import json, os

pull = os.environ["PULL_POLICY"]
image = os.environ["IMAGE"]
api_key = os.environ["API_KEY"]
otel = os.environ["OTEL_ENDPOINT"]
models_vol = json.loads(os.environ["MODEL_VOLUME_JSON"])
models_mount = json.loads(os.environ["MODEL_MOUNT_JSON"])

spec = {
  "containers": [{
    "name": "app",
    "image": image,
    "imagePullPolicy": pull,
    "ports": [{"containerPort": 8456}],
    "env": [
      {"name": "MODEL_API_KEY", "value": api_key},
      {"name": "MODEL_DIR", "value": "/models"},
      {"name": "PORT", "value": "8456"},
      {"name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": otel},
      {"name": "OTEL_EXPORTER_OTLP_PROTOCOL", "value": "grpc"},
      {"name": "OTEL_EXPORTER_OTLP_INSECURE", "value": "true"},
      {"name": "OTEL_TRACES_EXPORTER", "value": "otlp"},
      {"name": "OTEL_METRICS_EXPORTER", "value": "otlp"},
      {"name": "OTEL_SERVICE_NAME", "value": "inference-api-go"},
      {"name": "OTEL_RESOURCE_ATTRIBUTES", "value": "deployment.environment=staging,service.namespace=ml-model"},
    ],
    "readinessProbe": {
      "httpGet": {"path": "/readyz", "port": 8456},
      "initialDelaySeconds": 30,
      "periodSeconds": 10,
    },
    "livenessProbe": {
      "httpGet": {"path": "/health-check-RUH", "port": 8456},
      "initialDelaySeconds": 60,
      "periodSeconds": 30,
    },
    "resources": {
      "requests": {"cpu": "500m", "memory": "1Gi"},
      "limits": {"cpu": "2", "memory": "3Gi"},
    },
    "volumeMounts": [models_mount],
  }],
  "volumes": [models_vol],
}
print(json.dumps({"spec": spec}))
PY
)"


kubectl expose pod "${POD_NAME}" -n "${APP_NS}" --name="${SVC_NAME}" --port=8456 --target-port=8456

echo "==> Wait for ready"
kubectl wait -n "${APP_NS}" --for=condition=Ready "pod/${POD_NAME}" --timeout=300s 2>/dev/null \
  || kubectl get pod "${POD_NAME}" -n "${APP_NS}"

echo ""
echo "In-cluster BASE_URL for k6:"
echo "  http://${SVC_NAME}.${APP_NS}.svc.cluster.local:8456"
