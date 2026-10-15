# inference-api-go

HTTP inference API on port **8456** for LightGBM `.txt` models with pure-Go inference ([go-lgbm](https://github.com/zhongdai/go-lgbm)).

## Container image (GHCR)

CI publishes on every push to `main` or `master`:

```text
ghcr.io/ashxcodes/inference-api-go:latest
```

Pull (private package: use a GitHub PAT with `read:packages`):

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
docker pull ghcr.io/ashxcodes/inference-api-go:latest
```

Run (mount model `.txt` files into `/models`):

```bash
docker run --rm -p 8456:8456 \
  -e MODEL_API_KEY=change-me \
  -v "$PWD/ml-models:/models:ro" \
  ghcr.io/ashxcodes/inference-api-go:latest
```

To pull without logging in, set the package visibility to **Public** under the repo’s **Packages** tab after the first CI publish.

## Build and test

```bash
make test
make build
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_API_KEY` | (required) | `X-API-Key` |
| `MODEL_DIR` | `/models` | Directory of `{AREA}.txt` models |
| `PORT` | `8456` | HTTP port |
| `PREDICT_CONCURRENCY` | `0` | Max concurrent predictions (`0` = off; set `N>0` only to cap in-process parallelism) |

OpenTelemetry uses the standard Go SDK (`internal/telemetry`, `OTEL_*` env) with **`otelhttp`** for inbound traces and `http.server.*` metrics, **contrib/runtime** for `go_*`, and **contrib/host** for `process_*` / `system_*`. Images build with plain `go build`. Configure export with `OTEL_*` — see `env.sample`.

## Models

Export `.pkl` to `.txt` (Python LightGBM 4.6):

```bash
pip install -r tools/requirements-export.txt
python tools/export_model.py ~/Downloads/AMM.pkl -o testdata/parity
```

## Parity vs Python

```bash
python tools/parity_amm.py --pkl ~/Downloads/AMM.pkl
go test ./internal/lgbm -run AMM -v
```

`testdata/amm_samples.jsonl` holds 500 reference rows; keep large `AMM.txt` local under `testdata/parity/`.

## Benchmarks

Load tests use Docker with **0.7 CPU / 1000Mi** limits (K8s-like). Put `AMM.txt` under `testdata/parity/` (or set `MODEL_TXT`).

### RPS sweep (ladder + cgroup table)

From the repo root: build once, then start a named container and run k6 in `--network container:…` (same pattern as the Python bench harness).

**1. Environment** (export in your shell before `start`):

```bash
# Optional: host access while sweeping (parity_compare, manual curl)
export BENCH_HOST_PORT=18456:8456
export BENCH_CPU=0.7
export PREDICT_CONCURRENCY=0          # "c0" sweep — no in-process predict cap
export SERVER_CPUSET=1,3,6,8          # pin server to these CPUs; SERVER_CPUSET= to skip cpuset

# Optional OTLP (needs port-forward on host; copy env.sample → .env first):
# export BENCH_OTLP=1
# kubectl port-forward --address 0.0.0.0 -n otel-collector svc/otelcol-gateway 4317:4317
```

**2. Server** (`CONTAINER` is any label, e.g. `bench-go-cpu07`):

```bash
./benchmark/server.sh build
./benchmark/server.sh start bench-go-cpu07
./benchmark/server.sh warm bench-go-cpu07
```

With OTLP: set `BENCH_OTLP=1` (and `BENCH_OTEL_ENV_FILE` if not using repo `.env`) before `start`.

**3. Sweep** — each request uses a **random trip** from 2,000 generated Amman payloads (`predict-varied.js`). Prints a markdown table (RPS, latency percentiles, cgroup CPU throttle, memory). Default step length `DUR=45s`; tag summaries with `SWEEP_CPU`:

```bash
SWEEP_CPU=0.7 ./benchmark/sweep.sh bench-go-cpu07 8456 go-c0 \
  100 200 300 400 500 600 700 750 800
```

JSON per step: `benchmark/k6/results/summary-go-c0-cpu0.7-<rps>rps.json`.

Other sweep knobs: `DUR`, `K6_CPUSET` (default `12-19`; set empty to disable k6 cpuset). Fixed single-trip payload (old behavior): `SWEEP_FIXED_PAYLOAD=1 ./benchmark/sweep.sh ...`.

**Stop:**

```bash
./benchmark/server.sh stop bench-go-cpu07
```

If k6 reports `permission denied` writing `benchmark/k6/results/*.json`, the directory is often **root-owned** from an earlier `docker compose` run. Fix once, then re-run the sweep:

```bash
sudo chown -R "$(id -u):$(id -g)" benchmark/k6/results
```

(`sweep.sh` can fall back to running k6 as root so the sweep still completes; `chown` keeps new summaries owned by your user.)

### Multi-city load (7 models, up to 7000 RPS)

Mount all `{CITY}.txt` under `MODEL_DIR`. Harness lives in **`benchmark/`** — see [`benchmark/README.md`](benchmark/README.md).

**Docker (laptop):**

```bash
export BASE_URL=http://127.0.0.1:8456
export API_KEY=…
BENCH_PER_CITY_RPS=50 BENCH_DURATION=30s ./benchmark/run-multicity-load.sh
```

**In-cluster** (`otel-collector` namespace, `ghcr.io/ashxcodes/inference-api-go:e378d03`):

```bash
export API_KEY='…'   # optional: MODELS_DIR=./ml-models
./benchmark/run-inference-api-go.sh
export BENCH_PER_CITY_RPS=20 BENCH_DURATION=30s
./benchmark/run-k6-inference-api-go.sh
```

Models: PVC + `kubectl cp` (see `benchmark/README.md`). OTLP: `otelcol-gateway.otel-collector.svc.cluster.local:4317`.

### Compose (single k6 run)

```bash
BENCH_CPU=0.7 PREDICT_CONCURRENCY=0 ./benchmark/run-benchmark.sh sustained 100 3m
./benchmark/run-benchmark.sh concurrent 25 2m
./benchmark/run-benchmark.sh suite
```

Results: `benchmark/k6/results/*.json`.

**OTLP** with compose:

```bash
# kubectl port-forward --address 0.0.0.0 -n otel-collector svc/otelcol-gateway 4317:4317
BENCH_OTLP=1 BENCH_CPU=0.7 ./benchmark/run-benchmark.sh sustained 100 3m
./benchmark/verify-otlp.sh
```

When `BENCH_OTLP=1`, compose merges repo `.env` into `benchmark/.bench.ml-model.env` (see `env.sample`).

### Compare with Python

If both stacks are up (e.g. Python on `:8000`, Go on `BENCH_HOST_PORT`):

```bash
python3 benchmark/parity_compare.py http://127.0.0.1:8000 http://127.0.0.1:18456
```

| Script | Role |
|--------|------|
| `benchmark/server.sh` | build / start / warm / stop bench container |
| `benchmark/sweep.sh` | random-trip RPS ladder + cgroup stats (`SWEEP_FIXED_PAYLOAD=1` for one fixed body) |
| `benchmark/sweep-varied.sh` | same as `sweep.sh` |
| `benchmark/run-benchmark.sh` | docker-compose + one k6 profile |
| `benchmark/verify-otlp.sh` | quick OTLP span check via collector metrics |
| `benchmark/run-multicity-load.sh` | Docker k6, 7-city `/predict` load |
| `benchmark/run-inference-api-go.sh` | inference pod in `otel-collector` |
| `benchmark/run-k6-inference-api-go.sh` | in-cluster k6 multi-city |
| `benchmark/parity_compare.py` | `/predict` parity vs Python |
