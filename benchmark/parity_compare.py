#!/usr/bin/env python3
"""Compare /predict responses (ETA, distance) between Python and Go services."""

from __future__ import annotations

import json
import math
import sys
import urllib.error
import urllib.request
from pathlib import Path

API_KEY = "benchmark-key"

# Same cases as Oct 11 parity (valid trips + error paths).
CASES: list[tuple[str, str, dict]] = [
    (
        "k6 payload",
        API_KEY,
        {
            "city": "AMM",
            "key": "k6",
            "origin_lat": 28.0,
            "origin_lng": 52.0,
            "destination_lat": 30.1,
            "destination_lng": 54.1,
            "created_at": "2024-01-01 00:00:00",
        },
    ),
    (
        "Amman trip",
        API_KEY,
        {
            "city": "AMM",
            "key": "a1",
            "origin_lat": 31.9539,
            "origin_lng": 35.9106,
            "destination_lat": 31.97,
            "destination_lng": 35.84,
            "created_at": "2024-06-15 08:30:00",
        },
    ),
    (
        "waypoint, UTC microseconds",
        API_KEY,
        {
            "city": "AMM",
            "key": "a2",
            "origin_lat": 31.95,
            "origin_lng": 35.91,
            "waypoint_lat": 31.98,
            "waypoint_lng": 35.87,
            "destination_lat": 32.0,
            "destination_lng": 35.85,
            "created_at": "2024-12-17 08:53:45.450213 UTC",
        },
    ),
    (
        "string coordinates",
        API_KEY,
        {
            "city": "AMM",
            "key": "a3",
            "origin_lat": "31.9539",
            "origin_lng": "35.9106",
            "destination_lat": "31.9900",
            "destination_lng": "35.8700",
            "created_at": "2024-02-29 23:59:59",
        },
    ),
    (
        "waypoint 0 means one leg",
        API_KEY,
        {
            "city": "AMM",
            "key": "a4",
            "origin_lat": 31.95,
            "origin_lng": 35.91,
            "waypoint_lat": 0,
            "waypoint_lng": 35.87,
            "destination_lat": 32.0,
            "destination_lng": 35.85,
            "created_at": "2024-03-10 22:15:00",
        },
    ),
    (
        "location-engine created_at",
        API_KEY,
        {
            "city": "AMM",
            "key": "a5",
            "origin_lat": 31.9,
            "origin_lng": 35.95,
            "destination_lat": 31.8,
            "destination_lng": 35.99,
            # location-engine: now_ast.strftime("%Y-%m-%d %H:%M:%S.%f")
            "created_at": "2024-03-10 22:15:00.000000",
        },
    ),
    (
        "bad API key",
        "wrong",
        {
            "city": "AMM",
            "key": "a6",
            "origin_lat": 31.9,
            "origin_lng": 35.95,
            "destination_lat": 31.8,
            "destination_lng": 35.99,
            "created_at": "2024-03-10 22:15:00",
        },
    ),
    (
        "unknown city",
        API_KEY,
        {
            "city": "XYZ",
            "key": "a7",
            "origin_lat": 31.9,
            "origin_lng": 35.95,
            "destination_lat": 31.8,
            "destination_lng": 35.99,
            "created_at": "2024-03-10 22:15:00",
        },
    ),
    (
        "missing field (status only)",
        API_KEY,
        {"city": "AMM", "key": "a8", "origin_lat": 31.9},
    ),
]


def call(base: str, api_key: str, payload: dict) -> tuple[int, str]:
    req = urllib.request.Request(
        f"{base.rstrip('/')}/predict",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "X-API-Key": api_key},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()


def load_golden(path: Path) -> list[tuple[str, str, dict]]:
    out: list[tuple[str, str, dict]] = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        req = rec["request"]
        out.append((rec.get("name", "golden"), API_KEY, req))
    return out


def eta_distance(body: str) -> tuple[float | None, float | None]:
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return None, None
    eta = data.get("eta")
    dist = data.get("distance")
    if eta is None:
        return None, dist if isinstance(dist, (int, float)) else None
    return float(eta), float(dist) if dist is not None else None


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: parity_compare.py PYTHON_BASE GO_BASE [golden.jsonl]", file=sys.stderr)
        return 2

    py_base, go_base = sys.argv[1], sys.argv[2]
    cases = list(CASES)
    if len(sys.argv) > 3:
        cases.extend(load_golden(Path(sys.argv[3])))

    eta_mismatches = 0
    status_mismatches = 0

    print(
        f"{'match':5} | {'case':28} | py_status | go_status | "
        f"py_eta      | go_eta      | Δeta      | py_dist   | go_dist   | Δdist"
    )
    print("-" * 120)

    for name, api_key, payload in cases:
        ps, pb = call(py_base, api_key, payload)
        gs, gb = call(go_base, api_key, payload)
        status_only = "status only" in name

        if ps != gs:
            status_mismatches += 1

        py_eta, py_dist = eta_distance(pb)
        go_eta, go_dist = eta_distance(gb)

        if status_only:
            same = ps == gs
            delta_eta = ""
            delta_dist = ""
        elif ps == 200 and gs == 200:
            if py_eta is None or go_eta is None:
                same = False
                delta_eta = "n/a"
            else:
                d_eta = go_eta - py_eta
                delta_eta = f"{d_eta:+.6g}"
                same = math.isclose(py_eta, go_eta, rel_tol=0, abs_tol=1e-9) and (
                    py_dist is None
                    or go_dist is None
                    or math.isclose(py_dist, go_dist, rel_tol=0, abs_tol=1e-6)
                )
                if not same:
                    eta_mismatches += 1
            delta_dist = ""
            if py_dist is not None and go_dist is not None:
                delta_dist = f"{go_dist - py_dist:+.6g}"
        else:
            same = ps == gs
            delta_eta = ""
            delta_dist = ""

        flag = "OK" if same else "DIFF"
        print(
            f"{flag:5} | {name[:28]:28} | {ps:9} | {gs:9} | "
            f"{py_eta if py_eta is not None else '':11} | "
            f"{go_eta if go_eta is not None else '':11} | "
            f"{delta_eta:9} | "
            f"{py_dist if py_dist is not None else '':9} | "
            f"{go_dist if go_dist is not None else '':9} | {delta_dist}"
        )

    print("-" * 120)
    print(f"status mismatches: {status_mismatches}")
    print(f"eta/distance mismatches (200/200): {eta_mismatches}")
    return 1 if status_mismatches or eta_mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
