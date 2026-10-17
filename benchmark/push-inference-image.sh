#!/usr/bin/env bash
# Build and push inference image (root Dockerfile).
#
#   ./benchmark/push-inference-image.sh
#   TAG=$(git rev-parse --short HEAD) ./benchmark/push-inference-image.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-ghcr.io/ashxcodes/inference-api-go}"
TAG="${TAG:-$(git -C "${ROOT}" rev-parse --short HEAD)}"

docker build -f "${ROOT}/Dockerfile" -t "${IMAGE}:${TAG}" "${ROOT}"
docker push "${IMAGE}:${TAG}"

echo ""
echo "Deploy with:"
echo "  IMAGE=${IMAGE}:${TAG} ./benchmark/run-inference-api-go.sh"
