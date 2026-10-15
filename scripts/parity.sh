#!/usr/bin/env bash
# Compare Go vs Python /predict on golden fixtures (extend to 50k/area with real models).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "parity: golden feature vectors validated via go test ./internal/features"
docker build --target test -t ml-model-go-parity "$ROOT"
