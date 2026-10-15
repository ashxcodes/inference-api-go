#!/usr/bin/env python3
"""Export joblib LightGBM .pkl artifacts to LightGBM .txt for the Go service."""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

import joblib
import lightgbm as lgb
import numpy as np

# Fixed 9-feature row used for reload parity check (matches transform feature order).
_CHECK_ROW = np.array(
    [[24.71, 46.67, 24.75, 46.70, 1.0, 8.0, 4.5, 0.1, -0.2]],
    dtype=np.float64,
)

AREAS = ("RUH", "JED", "AMM", "DMM", "MEC", "MAD", "OtherCities")


def _extract_booster(obj) -> lgb.Booster:
    if isinstance(obj, lgb.Booster):
        return obj
    if hasattr(obj, "booster_"):
        return obj.booster_
    if hasattr(obj, "predict"):
        # sklearn LGBMRegressor etc.
        inner = getattr(obj, "booster_", None) or getattr(obj, "_Booster", None)
        if inner is not None:
            return inner
    raise TypeError(f"Unsupported model type: {type(obj)!r}")


def export_one(pkl_path: Path, txt_path: Path) -> str:
    if not pkl_path.is_file():
        raise FileNotFoundError(pkl_path)

    model = joblib.load(pkl_path)
    booster = _extract_booster(model)

    before = booster.predict(_CHECK_ROW, num_threads=1)
    txt_path.parent.mkdir(parents=True, exist_ok=True)
    booster.save_model(str(txt_path))

    reloaded = lgb.Booster(model_file=str(txt_path))
    after = reloaded.predict(_CHECK_ROW, num_threads=1)
    if not np.allclose(before, after, rtol=0, atol=1e-9):
        raise RuntimeError(
            f"reload mismatch for {pkl_path}: before={before!r} after={after!r}"
        )

    digest = hashlib.sha256(txt_path.read_bytes()).hexdigest()
    txt_path.with_suffix(txt_path.suffix + ".sha256").write_text(digest + "\n")
    return digest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "pkl",
        nargs="*",
        type=Path,
        help="Input .pkl files (default: modules/<AREA>.pkl for all areas)",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        default=Path("out"),
        help="Directory for .txt and .sha256 outputs",
    )
    args = parser.parse_args()

    pkls = list(args.pkl)
    if not pkls:
        modules = Path("modules")
        for area in AREAS:
            pkls.append(modules / f"{area}.pkl")

    failed = False
    for pkl in pkls:
        area = pkl.stem
        txt = args.output_dir / f"{area}.txt"
        try:
            digest = export_one(pkl, txt)
            print(f"OK {pkl} -> {txt} sha256={digest}")
        except Exception as e:
            print(f"FAIL {pkl}: {e}", file=sys.stderr)
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
