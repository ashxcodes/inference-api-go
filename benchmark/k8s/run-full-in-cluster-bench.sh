#!/usr/bin/env bash
# Deploy bench server (local image or ECR) then run in-cluster k6.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export API_KEY="${API_KEY:?Set API_KEY}"

APP_NS="${APP_NS:-jeeny-ml-model}"
SVC_NAME="${SVC_NAME:-ml-model-go-bench}"

"${ROOT}/benchmark/k8s/deploy-bench-server.sh"

export BASE_URL="${BASE_URL:-http://${SVC_NAME}.${APP_NS}.svc.cluster.local:8456}"
export BENCH_PER_CITY_RPS="${BENCH_PER_CITY_RPS:-20}"
export BENCH_DURATION="${BENCH_DURATION:-30s}"

exec "${ROOT}/benchmark/run-k6-ml-model.sh"
