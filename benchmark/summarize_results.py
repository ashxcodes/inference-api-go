#!/usr/bin/env python3
"""Print a short human-readable summary from k6 summary.json."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "k6/results/summary.json")
    if not path.is_file():
        print(f"missing summary: {path}", file=sys.stderr)
        return 1
    data = json.loads(path.read_text())
    m = data.get("metrics", {})

    def trend(name: str) -> dict:
        return m.get(name, {}).get("values", {})

    http = m.get("http_reqs", {}).get("values", {})
    failed = m.get("http_req_failed", {}).get("values", {}).get("rate", 0)
    pd = trend("http_req_duration") or trend("predict_duration")
    dropped = m.get("dropped_iterations", {}).get("values", {}).get("count", 0)
    vus = m.get("vus", {}).get("values", {})
    duration_s = data.get("state", {}).get("testRunDurationMs", 0) / 1000

    print(f"file: {path}")
    print(f"duration: {duration_s:.0f}s")
    attempted = http.get("rate", 0)
    success_rps = attempted * (1 - failed)
    print(f"attempted_http_rps: {attempted:.2f}  successful_http_rps: {success_rps:.2f}")
    print(f"total_requests: {http.get('count', 0)}  failed: {failed * 100:.2f}%  dropped: {dropped}")
    if failed > 0.001 or dropped > 0:
        print(
            "capacity: limit reached for current service config "
            f"(ceiling ~{success_rps:.2f} total rps) — reduce BENCH_PER_CITY_RPS or scale pod"
        )
    else:
        print("capacity: no limit signal at this target (failures/drops negligible)")
    if vus:
        print(f"vus min/max: {vus.get('min', '?')}/{vus.get('max', '?')}")
    if pd:
        print(
            "latency_ms: "
            f"avg={pd.get('avg', 0):.2f} med={pd.get('med', 0):.2f} "
            f"p90={pd.get('p(90)', 0):.2f} p95={pd.get('p(95)', 0):.2f} "
            f"p99={pd.get('p(99)', 0):.2f} max={pd.get('max', 0):.2f}"
        )
    cities = ["RUH", "JED", "AMM", "DMM", "MAD", "MEC", "OtherCities"]
    for city in cities:
        key = f"http_req_duration{{city:{city}}}"
        sub = trend(key)
        if sub:
            print(
                f"  {city}: p95={sub.get('p(95)', 0):.2f} p99={sub.get('p(99)', 0):.2f} avg={sub.get('avg', 0):.2f}"
            )
    checks = m.get("checks", {}).get("values", {})
    if checks:
        print(f"checks_pass: {checks.get('rate', 0) * 100:.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
