#!/usr/bin/env python3
"""Generate golden.jsonl from Python transform + predict_eta (reference implementation)."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import MagicMock

import numpy as np

# Run from jeeny-ml-model repo root so imports resolve.
JEENY_ROOT = Path(__file__).resolve().parents[2] / "jeeny-ml-model"
if str(JEENY_ROOT) not in sys.path:
    sys.path.insert(0, str(JEENY_ROOT))

from models.Schema import PredictRequest  # noqa: E402
from services.predict_eta import predict_eta_sync  # noqa: E402
from transform import Transform  # noqa: E402

OUT = Path(__file__).resolve().parents[1] / "testdata" / "golden.jsonl"

CASES = [
    {
        "name": "basic_ruh",
        "body": {
            "city": "RUH",
            "key": "trip-1",
            "origin_lat": 24.71,
            "origin_lng": 46.67,
            "destination_lat": 24.75,
            "destination_lng": 46.70,
            "created_at": "2024-06-15 08:30:00",
        },
    },
    {
        "name": "string_coords",
        "body": {
            "city": "AMM",
            "key": "trip-str",
            "origin_lat": "28.0",
            "origin_lng": "52.0",
            "destination_lat": "30.1",
            "destination_lng": "54.1",
            "created_at": "2024-06-15 08:30:00",
        },
    },
    {
        "name": "created_at_utc_fraction",
        "body": {
            "city": "JED",
            "key": "trip-utc",
            "origin_lat": 30.0,
            "origin_lng": 54.0,
            "destination_lat": 32.1,
            "destination_lng": 56.1,
            "created_at": "2024-12-17 08:53:45.450213 UTC",
        },
    },
    {
        "name": "waypoint",
        "body": {
            "city": "RUH",
            "key": "trip-wp",
            "origin_lat": 24.71,
            "origin_lng": 46.67,
            "waypoint_lat": 24.73,
            "waypoint_lng": 46.68,
            "destination_lat": 24.75,
            "destination_lng": 46.70,
            "created_at": "2024-01-01 00:00:00",
        },
    },
    {
        "name": "waypoint_zero_ignored",
        "body": {
            "city": "RUH",
            "key": "trip-wp0",
            "origin_lat": 24.71,
            "origin_lng": 46.67,
            "waypoint_lat": 0,
            "waypoint_lng": 0,
            "destination_lat": 24.75,
            "destination_lng": 46.70,
            "created_at": "2024-01-01 00:00:00",
        },
    },
    {
        "name": "empty_created_at",
        "body": {
            "city": "DMM",
            "key": "trip-now",
            "origin_lat": 26.0,
            "origin_lng": 50.0,
            "destination_lat": 28.1,
            "destination_lng": 52.1,
            "created_at": "",
        },
        "skip_response": True,
    },
]


class FixedModel:
    """Returns deterministic ETA from aerial feature (index 6)."""

    def predict(self, city: str, rows: list):
        etas = [float(r[6]) * 1.5 + 3.0 for r in rows]
        return {"success": True, "prediction": etas}


def features_for_body(body: dict, transformer: Transform) -> list[list[float]]:
    created = body.get("created_at") or ""
    if body.get("waypoint_lat") and body.get("waypoint_lng"):
        legs = [
            (
                body["origin_lat"],
                body["origin_lng"],
                body["waypoint_lat"],
                body["waypoint_lng"],
            ),
            (
                body["waypoint_lat"],
                body["waypoint_lng"],
                body["destination_lat"],
                body["destination_lng"],
            ),
        ]
    else:
        legs = [
            (
                body["origin_lat"],
                body["origin_lng"],
                body["destination_lat"],
                body["destination_lng"],
            ),
        ]
    out = []
    for leg in legs:
        lat1, lng1, lat2, lng2 = [float(x) for x in leg]
        out.append(transformer.transform(lat1, lng1, lat2, lng2, created or "2024-06-15 08:30:00"))
    return out


def main() -> int:
    transformer = Transform()
    model = FixedModel()

    lines = []
    for case in CASES:
        body = case["body"].copy()
        feats = features_for_body(body, transformer)
        record = {
            "name": case["name"],
            "request": body,
            "features": [[float(x) for x in row] for row in feats],
        }
        if not case.get("skip_response"):
            payload = PredictRequest.model_validate(body)
            resp = predict_eta_sync(payload, transformer, model)  # type: ignore[arg-type]
            record["response"] = resp
            record["status"] = 200
        lines.append(record)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w") as f:
        for rec in lines:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    print(f"wrote {len(lines)} cases to {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
