#!/usr/bin/env bash
# Repeat the same in-cluster config N times: fresh deploy → k6 → pause.
# Each repeat gets its own timestamped results folder.
#
#   IMAGE=ghcr.io/ashxcodes/inference-api-go:<sha> \
#     C=4 BENCH_PER_CITY_RPS=80 \
#     ./benchmark/repeat-k6-inference-api-go.sh
#
# Env:
#   IMAGE                 required (same as run-inference-api-go.sh)
#   C                     PREDICT_CONCURRENCY to deploy (default: 4)
#   BENCH_PER_CITY_RPS    per-city RPS (default: 80; ×7 total)
#   BENCH_DURATION        per-run duration (default: 5m)
#   REPEATS               number of runs (default: 5)
#   PAUSE_SECONDS         sleep between runs (default: 30)
#   CPU_TAG               folder tag (default: cpu1)
#   + any env for run-inference-api-go.sh / run-k6-inference-api-go.sh
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C="${C:-4}"
CPU_TAG="${CPU_TAG:-cpu1}"
BENCH_PER_CITY_RPS="${BENCH_PER_CITY_RPS:-80}"
BENCH_DURATION="${BENCH_DURATION:-5m}"
REPEATS="${REPEATS:-5}"
PAUSE_SECONDS="${PAUSE_SECONDS:-30}"
TOTAL_RPS=$((BENCH_PER_CITY_RPS * 7))

export BENCH_NONINTERACTIVE=1
unset PREDICT_CONCURRENCY || true

echo "── in-cluster repeat (fresh deploy each run) ──"
echo "  PREDICT_CONCURRENCY: ${C}"
echo "  BENCH_PER_CITY_RPS:  ${BENCH_PER_CITY_RPS}  (×7 = ${TOTAL_RPS} total)"
echo "  BENCH_DURATION:      ${BENCH_DURATION}"
echo "  REPEATS:             ${REPEATS}"
echo "  PAUSE_SECONDS:       ${PAUSE_SECONDS}"
echo "  IMAGE:               ${IMAGE:-<unset>}"
echo ""

if [[ -z "${IMAGE:-}" ]]; then
  echo "ERROR: set IMAGE=ghcr.io/...:tag" >&2
  exit 1
fi

SESSION_ROOT="${BENCH}/k6/results/${CPU_TAG}-c${C}-${BENCH_PER_CITY_RPS}rps-x${REPEATS}"
mkdir -p "${SESSION_ROOT}"
echo "Session root: ${SESSION_ROOT}"
echo ""

for i in $(seq 1 "${REPEATS}"); do
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="${SESSION_ROOT}/${stamp}-run${i}"
  mkdir -p "${out}"

  echo "======== run ${i}/${REPEATS}  start=${stamp}  out=${out} ========"

  echo "==> Deploy inference-api-go PREDICT_CONCURRENCY=${C}"
  BENCH_PREDICT_CONCURRENCY="${C}" \
    "${BENCH}/run-inference-api-go.sh"

  echo "==> k6 ${BENCH_PER_CITY_RPS}/city × 7 = ${TOTAL_RPS} for ${BENCH_DURATION}"
  BENCH_PER_CITY_RPS="${BENCH_PER_CITY_RPS}" \
    BENCH_DURATION="${BENCH_DURATION}" \
    K6_SUMMARY_LOCAL="${out}/summary-c${C}-${BENCH_PER_CITY_RPS}rps.json" \
    K6_LOG_LOCAL="${out}/log-c${C}-${BENCH_PER_CITY_RPS}rps.txt" \
    "${BENCH}/run-k6-inference-api-go.sh"

  echo "---- run ${i} summary ----"
  if [[ -f "${out}/summary-c${C}-${BENCH_PER_CITY_RPS}rps.json" ]]; then
    python3 "${BENCH}/summarize_results.py" \
      "${out}/summary-c${C}-${BENCH_PER_CITY_RPS}rps.json" || true
  else
    sed -n '/=== multicity load ===/,/successful_rps:/p' \
      "${out}/log-c${C}-${BENCH_PER_CITY_RPS}rps.txt" 2>/dev/null || true
  fi
  echo "Results: ${out}"

  if [[ "${i}" -lt "${REPEATS}" ]]; then
    echo "==> Pause ${PAUSE_SECONDS}s before next run"
    sleep "${PAUSE_SECONDS}"
  fi
done

echo ""
echo "── all ${REPEATS} runs done ──"
echo "Session root: ${SESSION_ROOT}"
echo ""
echo "Quick compare:"
shopt -s nullglob
for log in "${SESSION_ROOT}"/*/log-*.txt; do
  echo "---- $(basename "$(dirname "${log}")") ----"
  sed -n '/=== multicity load ===/,/successful_rps:/p' "${log}" 2>/dev/null || true
  echo
done
