#!/usr/bin/env bash
# RPS ladder: k6 constant-arrival-rate over container loopback + cgroup CPU stats.
#
# Usage:
#   ./benchmark/sweep.sh CONTAINER PORT LABEL RPS [RPS ...]
#
# Example (after ./benchmark/server.sh start bench-go-cpu07):
#   ./benchmark/sweep.sh bench-go-cpu07 8456 go-c0 50 70 80 90 100 200 300 400 500 600 700 800
#
# Env:
#   DUR=45s                  step duration
#   SWEEP_CPU=0.7            tag in summary-go-c0-cpu0.7-100rps.json
#   K6_CPUSET=12-19          cpuset for k6 (set empty to omit --cpuset-cpus)
#   K6_IMAGE=grafana/k6:0.54.0
#   SWEEP_FIXED_PAYLOAD=1    use single fixed trip (predict.js) instead of random Amman trips
set -uo pipefail

NAME="$1"
PORT="$2"
LABEL="$3"
shift 3

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${BENCH}/k6/results"
DUR="${DUR:-45s}"
SWEEP_CPU="${SWEEP_CPU:-0.7}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
K6_CPUSET="${K6_CPUSET:-12-19}"
CPU_TAG="cpu${SWEEP_CPU}"
K6_SCRIPT="${BENCH}/k6/predict-varied.js"
k6_scenario_env=()
if [[ "${SWEEP_FIXED_PAYLOAD:-0}" == "1" ]]; then
  K6_SCRIPT="${BENCH}/k6/predict.js"
  k6_scenario_env=(-e BENCH_SCENARIO=sustained)
fi

CG="/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' "$NAME").scope"

stat_field() { awk -v f="$1" '$1==f{print $2}' "$CG/cpu.stat"; }

k6_cpuset=()
if [[ -n "$K6_CPUSET" ]]; then
  k6_cpuset=(--cpuset-cpus "$K6_CPUSET")
fi

mkdir -p "$RESULTS"
k6_user=()
if [[ -w "$RESULTS" ]]; then
  k6_user=(--user "$(id -u):$(id -g)")
else
  echo "note: $RESULTS not writable; running k6 as root (fix: sudo chown -R $(id -u):$(id -g) $RESULTS)" >&2
  k6_user=(--user 0:0)
fi

echo "| server | target RPS | achieved RPS | p50 ms | p90 ms | p95 ms | p99 ms | max ms | failed | dropped | CPU ms/req | cores used | throttled periods | mem MiB |"
echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

for r in "$@"; do
  out="summary-${LABEL}-${CPU_TAG}-${r}rps.json"
  u0=$(stat_field usage_usec)
  t0=$(stat_field nr_throttled)
  docker run --rm "${k6_user[@]}" "${k6_cpuset[@]}" --network "container:$NAME" \
    -v "${K6_SCRIPT}:/scripts/predict.js:ro" \
    -v "${RESULTS}:/scripts/results" \
    -e BASE_URL="http://127.0.0.1:${PORT}" -e API_KEY=benchmark-key \
    "${k6_scenario_env[@]}" -e BENCH_TARGET_RPS="$r" -e BENCH_DURATION="$DUR" \
    -e K6_SUMMARY_FILE="/scripts/results/$out" \
    "$K6_IMAGE" run --quiet --summary-trend-stats "avg,min,med,max,p(90),p(95),p(99)" \
    /scripts/predict.js >/dev/null
  u1=$(stat_field usage_usec)
  t1=$(stat_field nr_throttled)
  mem=$(cat "$CG/memory.current")
  python3 "${BENCH}/row.py" "$RESULTS/$out" "$LABEL" "$r" "$((u1 - u0))" "$((t1 - t0))" "$mem"
done
