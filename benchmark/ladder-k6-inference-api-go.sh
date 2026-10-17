#!/usr/bin/env bash
# One entry point: deploy inference-api-go + in-cluster RPS ladder.
# Host-local JSON/logs under benchmark/k6/results/ (kubectl cp / tee).
#
#   IMAGE=ghcr.io/ashxcodes/inference-api-go:<sha> C=1 ./benchmark/ladder-k6-inference-api-go.sh
#   IMAGE=... C_VALUES="2 4 8 0" BENCH_RPS_STEPS="80" ./benchmark/ladder-k6-inference-api-go.sh
#
# Repeat each C (fresh deploy every run, pause between, timestamped folders):
#   IMAGE=... C_VALUES="2 4 8 0" BENCH_RPS_STEPS="80" \
#     BENCH_DURATION=5m REPEATS=5 PAUSE_SECONDS=30 \
#     ./benchmark/ladder-k6-inference-api-go.sh
#
#   SKIP_DEPLOY=1 C=1 ./benchmark/ladder-k6-inference-api-go.sh   # ladder only
#
# Env:
#   IMAGE                        required unless SKIP_DEPLOY=1
#   C / C_VALUES                 PREDICT_CONCURRENCY to deploy+label (default C=1)
#   BENCH_RPS_STEPS              per-city RPS list (default: 20 40 60 80 100 120 150)
#   BENCH_DURATION               step duration (default: 60s)
#   REPEATS                      runs per C (default: 1); redeploys each time
#   PAUSE_SECONDS                sleep between runs (default: 30; only if REPEATS>1 or more steps left)
#   CPU_TAG                      folder tag (default: cpu1)
#   OUT_DIR                      override results dir for a single C / single-repeat run
#   SKIP_DEPLOY=1                skip run-inference-api-go.sh
#   + any env for run-inference-api-go.sh / run-k6-inference-api-go.sh
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CPU_TAG="${CPU_TAG:-cpu1}"
BENCH_DURATION="${BENCH_DURATION:-60s}"
BENCH_RPS_STEPS="${BENCH_RPS_STEPS:-20 40 60 80 100 120 150}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
REPEATS="${REPEATS:-1}"
PAUSE_SECONDS="${PAUSE_SECONDS:-30}"

if [[ -n "${C_VALUES:-}" ]]; then
  # shellcheck disable=SC2206
  CONCURRENCY_VALUES=(${C_VALUES})
else
  CONCURRENCY_VALUES=("${C:-${PREDICT_CONCURRENCY_TAG:-1}}")
fi

export BENCH_NONINTERACTIVE=1
# Avoid a stale interactive export like PREDICT_CONCURRENCY='$c' confusing summaries.
unset PREDICT_CONCURRENCY || true

echo "── in-cluster deploy + RPS ladder ──"
echo "  PREDICT_CONCURRENCY: ${CONCURRENCY_VALUES[*]}"
echo "  BENCH_DURATION:      ${BENCH_DURATION}"
echo "  BENCH_RPS_STEPS:     ${BENCH_RPS_STEPS}  (per city; ×7 total)"
echo "  REPEATS:             ${REPEATS}"
echo "  PAUSE_SECONDS:       ${PAUSE_SECONDS}"
echo "  SKIP_DEPLOY:         ${SKIP_DEPLOY}"
echo "  IMAGE:               ${IMAGE:-<unset>}"
echo ""

if [[ "${SKIP_DEPLOY}" != "1" && -z "${IMAGE:-}" ]]; then
  echo "ERROR: set IMAGE=ghcr.io/...:tag (or SKIP_DEPLOY=1 for ladder-only)" >&2
  exit 1
fi

print_log_compare() {
  local out="$1"
  local c="$2"
  local log
  shopt -s nullglob
  local logs=("${out}"/log-c${c}-*.txt)
  shopt -u nullglob
  if [[ ${#logs[@]} -eq 0 ]]; then
    echo "No log files under ${out}" >&2
    return 1
  fi
  for log in "${logs[@]}"; do
    echo "---- $(basename "${log}") ----"
    sed -n '/=== multicity load ===/,/successful_rps:/p' "${log}" 2>/dev/null \
      || sed -n '/=== multicity load ===/,/=== capacity/p' "${log}"
    echo
  done
}

run_one() {
  local c="$1"
  local out="$2"
  mkdir -p "${out}"

  if [[ "${SKIP_DEPLOY}" != "1" ]]; then
    echo "==> Deploy inference-api-go PREDICT_CONCURRENCY=${c}"
    BENCH_PREDICT_CONCURRENCY="${c}" \
      "${BENCH}/run-inference-api-go.sh"
  else
    echo "==> SKIP_DEPLOY=1 — using existing inference pod (label c=${c})"
  fi

  for rps in ${BENCH_RPS_STEPS}; do
    local total=$((rps * 7))
    echo "==== c=${c} per_city=${rps} total=${total} ===="
    BENCH_PER_CITY_RPS="${rps}" \
      BENCH_DURATION="${BENCH_DURATION}" \
      K6_SUMMARY_LOCAL="${out}/summary-c${c}-${rps}rps.json" \
      K6_LOG_LOCAL="${out}/log-c${c}-${rps}rps.txt" \
      "${BENCH}/run-k6-inference-api-go.sh"
  done

  echo ""
  echo "── compare (c=${c} → ${out}) ──"
  local f
  shopt -s nullglob
  local summaries=("${out}"/summary-c${c}-*.json)
  shopt -u nullglob
  if [[ ${#summaries[@]} -eq 0 ]]; then
    echo "WARN: no summary JSON under ${out}; comparing from logs" >&2
    print_log_compare "${out}" "${c}" || true
  else
    for f in "${summaries[@]}"; do
      python3 "${BENCH}/summarize_results.py" "${f}"
      echo
    done
  fi
  echo "Results: ${out}"
}

maybe_pause() {
  local more="$1"
  if [[ "${more}" == "1" ]]; then
    echo "==> Pause ${PAUSE_SECONDS}s"
    sleep "${PAUSE_SECONDS}"
  fi
}

c_count=${#CONCURRENCY_VALUES[@]}
total_runs=$((c_count * REPEATS))
run_idx=0

for c in "${CONCURRENCY_VALUES[@]}"; do
  for rep in $(seq 1 "${REPEATS}"); do
    run_idx=$((run_idx + 1))
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"

    if [[ "${REPEATS}" -gt 1 ]]; then
      out="${BENCH}/k6/results/${CPU_TAG}-c${c}/${stamp}-run${rep}"
    elif [[ -n "${OUT_DIR:-}" && "${c_count}" -eq 1 ]]; then
      out="${OUT_DIR}"
    else
      # Single pass: keep prior layout, but still stamp so re-runs do not overwrite.
      out="${BENCH}/k6/results/${CPU_TAG}-c${c}/${stamp}"
    fi

    echo "======== [${run_idx}/${total_runs}] c=${c} repeat=${rep}/${REPEATS} start=${stamp} ========"
    run_one "${c}" "${out}"

    if [[ "${run_idx}" -lt "${total_runs}" ]]; then
      maybe_pause 1
    fi
  done
done

echo ""
echo "── all runs done (${total_runs}) ──"
for c in "${CONCURRENCY_VALUES[@]}"; do
  echo ""
  echo "### c=${c}"
  shopt -s nullglob
  for log in "${BENCH}/k6/results/${CPU_TAG}-c${c}"/*/log-c${c}-*.txt; do
    echo "---- $(basename "$(dirname "${log}")") ----"
    sed -n '/=== multicity load ===/,/successful_rps:/p' "${log}" 2>/dev/null || true
    echo
  done
  shopt -u nullglob
done
