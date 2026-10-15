#!/usr/bin/env python3
"""Print one markdown table row from a k6 summary plus container cgroup deltas."""
from __future__ import annotations

import json
import sys


def main() -> None:
    path, label, target, usage_usec, throttled, mem_bytes = sys.argv[1:7]
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        print(
            f"error: missing k6 summary {path} "
            "(often permission denied on benchmark/k6/results; "
            "run: sudo chown -R \"$(id -u):$(id -g)\" benchmark/k6/results)",
            file=sys.stderr,
        )
        sys.exit(1)
    metrics = data["metrics"]
    reqs = metrics["http_reqs"]["values"]
    lat = metrics["http_req_duration"]["values"]
    failed = metrics.get("http_req_failed", {}).get("values", {}).get("rate", 0)
    dropped = metrics.get("dropped_iterations", {}).get("values", {}).get("count", 0)
    dur_s = data["state"]["testRunDurationMs"] / 1000
    count = reqs["count"]
    cpu_ms_per_req = int(usage_usec) / 1000 / count if count else float("nan")
    cores_used = int(usage_usec) / 1e6 / dur_s
    print(
        f"| {label} | {target} | {reqs['rate']:.1f} | {lat['med']:.2f} | {lat['p(90)']:.2f} | "
        f"{lat['p(95)']:.2f} | {lat['p(99)']:.2f} | {lat['max']:.0f} | {failed * 100:.2f}% | {int(dropped)} | "
        f"{cpu_ms_per_req:.2f} | {cores_used:.2f} | {throttled} | {int(mem_bytes) / 2**20:.0f} |",
        flush=True,
    )


if __name__ == "__main__":
    main()
