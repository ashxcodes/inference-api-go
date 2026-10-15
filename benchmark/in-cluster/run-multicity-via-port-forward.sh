#!/usr/bin/env bash
# Port-forward in-cluster ml-model Service, then run benchmark/run-multicity-load.sh.
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="${NAMESPACE:-jeeny-ml-model}"
SERVICE="${SERVICE:-jeeny-ml-model}"
LOCAL_PORT="${LOCAL_PORT:-8456}"
REMOTE_PORT="${REMOTE_PORT:-8456}"
RPS="${RPS:-50}"
DURATION="${DURATION:-30s}"

usage() {
  echo "Usage: $0 [--namespace NS] [--service NAME] [--local-port P] [--rps N] [--duration D]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    --rps) RPS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if ! kubectl -n "${NAMESPACE}" get svc "${SERVICE}" >/dev/null 2>&1; then
  echo "Service ${NAMESPACE}/${SERVICE} not found" >&2
  exit 1
fi

echo "Port-forward ${NAMESPACE}/${SERVICE} ${LOCAL_PORT}:${REMOTE_PORT}"
kubectl -n "${NAMESPACE}" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" &
PF_PID=$!
cleanup() { kill "${PF_PID}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

for i in $(seq 1 30); do
  if curl -sf -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/health-check-RUH" 2>/dev/null \
    || curl -sf -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/readyz" 2>/dev/null; then
    break
  fi
  sleep 1
done

export BASE_URL="http://127.0.0.1:${LOCAL_PORT}"
export BENCH_PER_CITY_RPS="${RPS}"
export BENCH_DURATION="${DURATION}"
"${BENCH}/run-multicity-load.sh"
