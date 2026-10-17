#!/usr/bin/env bash
# Multi-city load test — see benchmark/README.md and benchmark/in-cluster/README.md.
# Fixtures: benchmark/k6/fixtures/multicity, FIXTURES_DIR, or JEENY_ML_MODEL_ROOT.
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${FIXTURES_DIR:-}" ]]; then
  FIXTURES="${FIXTURES_DIR}"
elif [[ -f "${BENCH}/k6/fixtures/multicity/RUH.json" ]]; then
  FIXTURES="${BENCH}/k6/fixtures/multicity"
else
  JEENY_ROOT="${JEENY_ML_MODEL_ROOT:-$(cd "${BENCH}/../jeeny-ml-model" 2>/dev/null && pwd || echo "")}"
  FIXTURES="${JEENY_ROOT}/benchmark/k6/fixtures/multicity"
fi
RESULTS="${BENCH}/k6/results"
mkdir -p "${RESULTS}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8456}"
API_KEY="${API_KEY:-benchmark-key}"
BENCH_PER_CITY_RPS="${BENCH_PER_CITY_RPS:-1000}"
BENCH_DURATION="${BENCH_DURATION:-5m}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
K6_CPUSET="${K6_CPUSET:-}"

for c in RUH JED AMM DMM MAD MEC OtherCities; do
  if [[ ! -f "${FIXTURES}/${c}.json" ]]; then
    echo "Missing ${FIXTURES}/${c}.json" >&2
    echo "git pull or set FIXTURES_DIR (benchmark/k6/fixtures/multicity/)" >&2
    exit 1
  fi
done

TOTAL_RPS=$((BENCH_PER_CITY_RPS * 7))
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="summary-multicity-${BENCH_PER_CITY_RPS}rps-per-city-${STAMP}.json"

k6_cpuset=()
if [[ -n "${K6_CPUSET}" ]]; then
  k6_cpuset=(--cpuset-cpus "${K6_CPUSET}")
fi

echo "Multi-city load: ${BENCH_PER_CITY_RPS} RPS × 7 cities = ${TOTAL_RPS} RPS total"
echo "Target: ${BASE_URL}  Duration: ${BENCH_DURATION}"
echo "Fixtures: ${FIXTURES}"
echo "Results: ${RESULTS}/${OUT}"

docker run --rm "${k6_cpuset[@]}" \
  --add-host=host.docker.internal:host-gateway \
  -v "${BENCH}/k6/predict-multicity.js:/scripts/predict-multicity.js:ro" \
  -v "${FIXTURES}:/scripts/fixtures/multicity:ro" \
  -v "${RESULTS}:/scripts/results" \
  -e BASE_URL="${BASE_URL}" \
  -e API_KEY="${API_KEY}" \
  -e BENCH_PER_CITY_RPS="${BENCH_PER_CITY_RPS}" \
  -e BENCH_DURATION="${BENCH_DURATION}" \
  -e BENCH_STRICT="${BENCH_STRICT:-0}" \
  -e FIXTURE_DIR=/scripts/fixtures/multicity \
  -e K6_SUMMARY_FILE="/scripts/results/${OUT}" \
  "${K6_IMAGE}" run \
    --summary-trend-stats="avg,min,med,p(90),p(95),p(99),max" \
    /scripts/predict-multicity.js

echo "Wrote ${RESULTS}/${OUT}"
python3 "${BENCH}/summarize_results.py" "${RESULTS}/${OUT}" || true
