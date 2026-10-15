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
    pd = trend("predict_duration")
    dropped = m.get("dropped_iterations", {}).get("values", {}).get("count", 0)
    vus = m.get("vus", {}).get("values", {})
    duration_s = data.get("state", {}).get("testRunDurationMs", 0) / 1000

    print(f"file: {path}")
    print(f"duration: {duration_s:.0f}s")
    print(f"http_rps: {http.get('rate', 0):.1f}  total_requests: {http.get('count', 0)}")
    print(f"http_failed: {failed * 100:.2f}%  dropped_iterations: {dropped}")
    if vus:
        print(f"vus min/max: {vus.get('min', '?')}/{vus.get('max', '?')}")
    if pd:
        print(
            "predict_ms: "
            f"avg={pd.get('avg', 0):.2f} med={pd.get('med', 0):.2f} "
            f"p95={pd.get('p(95)', 0):.2f} max={pd.get('max', 0):.2f}"
        )
    checks = m.get("checks", {}).get("values", {})
    if checks:
        print(f"checks_pass: {checks.get('rate', 0) * 100:.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
