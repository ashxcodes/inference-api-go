# In-cluster multi-city load (inference-api-go)

Same pattern as **location-engine** `benchmark/run-k6-location-engine.sh`: k6 runs as a pod in `otel-collector`, scripts and fixtures via ConfigMaps.

## OTEL on the Go service

In-cluster pods should use the collector **Service DNS** (not localhost / port-forward):

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol-gateway.otel-collector.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_EXPORTER_OTLP_INSECURE=true
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
```

Merge these into your repo `.env` or the Deployment env. Port-forward to `otelcol-gateway` is only for **your laptop** (Grafana, `BENCH_OTLP=1` Docker bench).

## Deploy your image

```bash
LOCAL_K8S=1 API_KEY='…' MODEL_HOST_PATH=/path/to/models ./benchmark/k8s/deploy-bench-server.sh
# or
IMAGE=ghcr.io/your-org/inference-api-go:latest API_KEY='…' ./benchmark/k8s/deploy-bench-server.sh
```

Mount all `{CITY}.txt` under `MODEL_DIR` (multi-model pod).

## Run k6 in the cluster

From repo root:

```bash
export NS=otel-collector
export API_KEY='…'
export BASE_URL='http://ml-model.ml-model.svc.cluster.local:8456'
# optional if service name differs:
# export ML_MODEL_NAMESPACE=ml-model ML_MODEL_SERVICE=ml-model

export BENCH_PER_CITY_RPS=20
export BENCH_DURATION=30s
SKIP_DELETE=1 ./benchmark/run-k6-ml-model.sh
```

Fixtures: set `FIXTURES_DIR` or copy JSON under `benchmark/k6/fixtures/multicity/`.

## Laptop Docker k6 (port-forward)

```bash
export API_KEY='…'
./benchmark/in-cluster/run-multicity-via-port-forward.sh --rps 50 --duration 30s
```
