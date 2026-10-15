# Benchmarks (ml-model-go)

## In-cluster (`otel-collector` namespace)

**1. Inference server** — `ghcr.io/ashxcodes/inference-api-go:e378d03`

Large `*.txt` models cannot go in ConfigMaps (~3 MiB API limit). The script uses a **PVC** and copies from your laptop once via `kubectl cp`:

```bash
export API_KEY='…'
export MODELS_DIR=/path/to/ml-models   # default: repo ml-models/
./benchmark/run-inference-api-go.sh
```

PVC uses `storageClassName: gp3` (or `gp2`) — auto-detected; override with `STORAGE_CLASS=gp3`.  
Loader pod image defaults to `debian:bookworm-slim` (`tar` required for `kubectl cp`).  
Refresh models on the PVC: `FORCE_MODEL_COPY=1 ./benchmark/run-inference-api-go.sh`  
Models already in the image: `MODELS_FROM_IMAGE=1 ./benchmark/run-inference-api-go.sh`

**2. k6 multi-city** (same style as `location-engine/benchmark/run-k6-location-engine.sh`):

```bash
export NS=otel-collector
export API_KEY='…'
export BASE_URL='http://inference-api-go.otel-collector.svc.cluster.local:8456'
export BENCH_PER_CITY_RPS=20
export BENCH_DURATION=30s
SKIP_DELETE=1 ./benchmark/run-k6-inference-api-go.sh
```

Fixtures: `benchmark/k6/fixtures/multicity/` or `JEENY_ML_MODEL_ROOT=../jeeny-ml-model`.

OTEL on the server pod: `OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol-gateway.otel-collector.svc.cluster.local:4317` (set in `run-inference-api-go.sh`).

## Local Docker

```bash
BENCH_PER_CITY_RPS=20 BENCH_DURATION=30s ./benchmark/run-multicity-load.sh
```

Single-city sweep: root `README.md` (`server.sh`, `sweep.sh`).
