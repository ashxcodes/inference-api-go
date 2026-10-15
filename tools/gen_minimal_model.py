#!/usr/bin/env python3
"""Train a tiny 9-feature LightGBM model for unit tests."""

from __future__ import annotations

from pathlib import Path

import lightgbm as lgb
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "testdata" / "minimal.txt"

FEATURE_NAMES = [
    "lat_1",
    "lng_1",
    "lat_2",
    "lng_2",
    "dow",
    "hour",
    "aerial",
    "sin_dir",
    "cos_dir",
]


def main() -> None:
    rng = np.random.default_rng(42)
    x = rng.uniform(-1, 1, size=(200, 9))
    y = x[:, 6] * 2.0 + x[:, 5] * 0.1 + rng.normal(0, 0.01, size=200)

    train = lgb.Dataset(x, label=y, feature_name=FEATURE_NAMES)
    params = {
        "objective": "regression",
        "metric": "l2",
        "num_leaves": 8,
        "learning_rate": 0.3,
        "verbosity": -1,
        "num_threads": 1,
    }
    booster = lgb.train(params, train, num_boost_round=5)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    booster.save_model(str(OUT))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
