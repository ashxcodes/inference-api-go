# In-cluster multi-city load (ml-model-go)

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

Merge these into your repo `.env` or the Deployment env. Gitops `jeeny-ml-model-startupenv` already matches this for Python staging; use the same endpoint for your **locally built Go image** when you replace or sidecar-test the workload.

Port-forward to `otelcol-gateway` is only for **your laptop** (Grafana, `BENCH_OTLP=1` Docker bench).

## Deploy your image

```bash
kubectl -n jeeny-ml-model set image deployment/jeeny-ml-model app=YOUR_REGISTRY/ml-model-go:TAG
kubectl -n jeeny-ml-model scale deployment/jeeny-ml-model --replicas=1
kubectl -n jeeny-ml-model rollout status deployment/jeeny-ml-model
```

Mount all `{CITY}.txt` under `MODEL_DIR` (multi-model pod).

## Run k6 in the cluster

From **ml-model-go** repo root:

```bash
export NS=otel-collector
export API_KEY='…'
export BASE_URL='http://jeeny-ml-model.jeeny-ml-model.svc.cluster.local:8456'
# optional if service name differs:
# export ML_MODEL_NAMESPACE=jeeny-ml-model ML_MODEL_SERVICE=jeeny-ml-model

export BENCH_PER_CITY_RPS=20
export BENCH_DURATION=30s
SKIP_DELETE=1 ./benchmark/run-k6-ml-model.sh
```

Fixtures: set `FIXTURES_DIR` or `JEENY_ML_MODEL_ROOT=../jeeny-ml-model`, or copy/generate under `benchmark/k6/fixtures/multicity/`:

```bash
# from jeeny-ml-model (generator lives there)
python3 ../jeeny-ml-model/benchmark/tools/gen_multicity_fixtures.py \
  --out-dir benchmark/k6/fixtures/multicity \
  --combine benchmark/k6/fixtures/multicity/manifest.json
```

## Laptop Docker k6 (port-forward)

```bash
export API_KEY='…'
./benchmark/in-cluster/run-multicity-via-port-forward.sh --rps 50 --duration 30s
```

## location-engine

LE integration load: `location-engine/benchmark/run-k6-location-engine.sh` with `TARGET=https://location-engine.staging.jeeny.me`. Direct multi-city `/predict` bench uses **`ml-model-go/benchmark/run-k6-ml-model.sh`**.
