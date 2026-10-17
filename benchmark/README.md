# Benchmarks (ml-model-go)

## In-cluster (`otel-collector` namespace)

On the bench machine: `git pull`, `cp env.sample .env` (application only: `MODEL_API_KEY`, `OTEL_*`, …), put `*.txt` in `ml-models/` (gitignored). k6 JSON: `benchmark/k6/fixtures/multicity/`.

End-to-end:

```bash
cd ~/personal/ml-model-go
git pull origin main

./benchmark/run-inference-api-go.sh
# interactive: confirms .env + prompts for IMAGE if unset

SKIP_DELETE=1 ./benchmark/run-k6-inference-api-go.sh

# CI / no prompts:
# BENCH_NONINTERACTIVE=1 IMAGE=ghcr.io/...:tag ./benchmark/run-inference-api-go.sh
```

Build/push image (where you build Docker):

```bash
TAG=$(git rev-parse --short HEAD) ./benchmark/push-inference-image.sh
```

Models use PVC `inference-api-go-models` + one-time `kubectl cp` from `MODELS_DIR` (not ConfigMaps).  
Refresh models: `FORCE_MODEL_COPY=1 ./benchmark/run-inference-api-go.sh`  
Skip PVC if models are baked into the image: `MODELS_FROM_IMAGE=1 ./benchmark/run-inference-api-go.sh`

k6 fixtures use PVC `inference-api-go-k6-fixtures` + copy from `benchmark/k6/fixtures/multicity/`.  
Refresh fixtures: `FORCE_FIXTURE_COPY=1 ./benchmark/run-k6-inference-api-go.sh`

Run **inference** before k6. The k6 script preflights `BASE_URL` (default `http://inference-api-go:8456`).  
`dial: i/o timeout` on every request = inference not reachable (run deploy + preflight first).  
During a healthy run, **failed requests under load** mean you hit the **capacity ceiling** for the current pod (CPU, memory, concurrency) — not a broken test.  
Summary: attempted vs successful RPS, p95/p99, and `=== capacity ===` at end of k6 logs + `benchmark/k6/results/summary-multicity-incluster-*.json`.

**RPS ladder** (one entry point: deploy + load; saves JSON + logs on the host):

```bash
IMAGE=ghcr.io/ashxcodes/inference-api-go:<sha> C=1 ./benchmark/ladder-k6-inference-api-go.sh

# Sweep several PREDICT_CONCURRENCY values (redeploys between each):
IMAGE=... C_VALUES="2 4 8 0" BENCH_RPS_STEPS="80" ./benchmark/ladder-k6-inference-api-go.sh

# Repeat each C for stable latency stats (fresh deploy, 30s pause, timestamped dirs):
IMAGE=... C_VALUES="2 4 8 0" BENCH_RPS_STEPS="80" \
  BENCH_DURATION=5m REPEATS=5 PAUSE_SECONDS=30 \
  ./benchmark/ladder-k6-inference-api-go.sh

# Ladder only (pod already running):
SKIP_DEPLOY=1 C=1 ./benchmark/ladder-k6-inference-api-go.sh
```

Sets pod `PREDICT_CONCURRENCY` via `BENCH_PREDICT_CONCURRENCY` (does not rewrite `.env`).  
Output: `benchmark/k6/results/cpu1-c${C}/<UTC-stamp>[-runN]/`.  
Overrides: `BENCH_DURATION`, `BENCH_RPS_STEPS`, `REPEATS`, `PAUSE_SECONDS`, `CPU_TAG`, `OUT_DIR`, plus env for `run-inference-api-go.sh` / `run-k6-inference-api-go.sh`.

OTEL: set `OTEL_EXPORTER_OTLP_ENDPOINT` in repo `.env` (application config).

**Grafana APM** (`environment=staging`, `service_name=ml-model-go`): keep  
`OTEL_RESOURCE_ATTRIBUTES=deployment.environment=staging,service.namespace=jeeny,...` in `.env`.  
SDK sets `service.instance.id` from `HOSTNAME` (pod name) or a UUID; bench deploy strips a static instance id from `.env`.  
k6 RPS ≠ Grafana HTTP rate if the dashboard time range, route filter (`/predict`), or  
OTLP drops under load differ; compare **successful** k6 RPS to server metrics, not the nominal target if `dropped_iterations` > 0.

**Separate nodes (recommended):** both bench scripts label pods `ml-model-go.bench/role` and use pod anti-affinity (default `BENCH_POD_ANTIAFFINITY=preferred`). Hard requirement: `BENCH_POD_ANTIAFFINITY=required`. Disable: `BENCH_POD_ANTIAFFINITY=0`. Verify:  
`kubectl get pod -n otel-collector -l ml-model-go.bench/role -o wide`

### k6 RPS vs Grafana (`~/Work/Repos/otel-apm.json`)

HTTP tab **Request rate** (panel-2) queries Mimir with:

```promql
rate(http_server_request_duration_count{...}[$__rate_interval])
  or (histogram_count(http_server_request_duration{...})
      - histogram_count(http_server_request_duration{...} offset $__rate_interval)) / $__rate_interval
```

That matches **Java/Micrometer** naming and **native exponential histograms** (your `.env` sets `OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION=base2_exponential_bucket_histogram`). **Go otelhttp** often lands in Mimir as `http_server_request_duration_seconds` (unit s), not `http_server_request_duration_count` — the dashboard `or` may only partially match, and **histogram_count deltas** under OTLP batching (60s) **smooth peaks** below k6’s ~2700 RPS.

**Validate in Explore (same time range as k6):**

1. Dashboard-equivalent: `./benchmark/mimir-rps-check.sh` (first query = panel-2).
2. Go counter: `sum(rate(http_server_request_duration_seconds_count{service_name="ml-model-go",deployment_environment="staging",http_route="/predict"}[1m]))`
3. Metric names present: `count by (__name__) ({service_name="ml-model-go",__name__=~"http_server.*"})`

If (2) ≈ k6 but (1) ≈ 891, the **dashboard query** is the gap (metric name + native histogram rate math), not the service. Fix: extend `otel-apm.json` with a third `or` branch for `_seconds_count`, or export classic explicit buckets from Go for this dashboard.

**Instance variable:** `instance=$__all` → `service_instance_id=~".+"`. Each replica should appear as its pod name under `service.instance.id`. Set **HTTP route** filter to `predict` when comparing `/predict` only.

## Local Docker

```bash
BENCH_PER_CITY_RPS=20 BENCH_DURATION=30s ./benchmark/run-multicity-load.sh
```

Single-city sweep: root `README.md` (`server.sh`, `sweep.sh`).
