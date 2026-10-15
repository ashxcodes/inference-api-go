#!/usr/bin/env python3
"""Generate parity fixtures: Python LightGBM vs go-lgbm (Go) on random 9-feature rows."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import joblib
import lightgbm as lgb
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PKL = Path.home() / "Downloads" / "AMM.pkl"
DEFAULT_TXT = ROOT / "testdata" / "parity" / "AMM.txt"
OUT = ROOT / "testdata" / "amm_samples.jsonl"


def _booster(pkl_path: Path) -> lgb.Booster:
    obj = joblib.load(pkl_path)
    if isinstance(obj, lgb.Booster):
        return obj
    if hasattr(obj, "booster_"):
        return obj.booster_
    raise TypeError(type(obj))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pkl", type=Path, default=Path(os.environ.get("AMM_PKL", DEFAULT_PKL)))
    parser.add_argument("--txt", type=Path, default=DEFAULT_TXT)
    parser.add_argument("-n", type=int, default=500)
    parser.add_argument("-o", type=Path, default=OUT)
    args = parser.parse_args()

    if not args.pkl.is_file():
        print(f"missing pkl: {args.pkl}", file=sys.stderr)
        return 1

    booster = _booster(args.pkl)
    rng = np.random.default_rng(42)
    rows = rng.uniform(
        low=[20, 40, 20, 40, 0, 0, 0, -1, -1],
        high=[35, 55, 35, 55, 6, 23, 500, 1, 1],
        size=(args.n, 9),
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    max_diff = 0.0
    with args.o.open("w") as f:
        for i, row in enumerate(rows):
            py = float(booster.predict([row.tolist()], num_threads=1)[0])
            rec = {"i": i, "features": [float(x) for x in row], "python_eta": py}
            f.write(json.dumps(rec) + "\n")

    # Reload from txt if present and compare (sanity for export)
    if args.txt.is_file():
        reloaded = lgb.Booster(model_file=str(args.txt))
        for line in args.o.read_text().strip().split("\n")[:20]:
            rec = json.loads(line)
            row = np.array([rec["features"]], dtype=np.float64)
            p2 = float(reloaded.predict(row, num_threads=1)[0])
            max_diff = max(max_diff, abs(p2 - rec["python_eta"]))
        print(f"txt reload max diff (first 20): {max_diff}")

    print(f"wrote {args.n} samples to {args.o}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
