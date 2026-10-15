# Benchmarks (ml-model-go)

## Multi-city load (7 × RPS)

- **k6 script:** `k6/predict-multicity.js` — seven `constant-arrival-rate` scenarios (one city each).
- **Docker (laptop):** `run-multicity-load.sh`
- **Kubernetes:** `run-k6-ml-model.sh` (see [`in-cluster/README.md`](in-cluster/README.md))

Fixtures (700 customers × 10 drivers per city) are usually generated from sibling **jeeny-ml-model**:

```bash
python3 ../jeeny-ml-model/benchmark/tools/gen_multicity_fixtures.py \
  --out-dir benchmark/k6/fixtures/multicity \
  --combine benchmark/k6/fixtures/multicity/manifest.json
```

Or set `FIXTURES_DIR` / `JEENY_ML_MODEL_ROOT` when running load scripts.

### Local smoke

```bash
export BASE_URL=http://127.0.0.1:8456
export API_KEY=…
BENCH_PER_CITY_RPS=20 BENCH_DURATION=30s ./benchmark/run-multicity-load.sh
```

### In-cluster smoke

```bash
export NS=otel-collector API_KEY='…'
BENCH_PER_CITY_RPS=20 BENCH_DURATION=30s ./benchmark/run-k6-ml-model.sh
```

Full profile: `BENCH_PER_CITY_RPS=1000 BENCH_DURATION=5m` (large k6 pod resources in script).

## Single-city RPS sweep

See root `README.md` — `server.sh`, `sweep.sh`, `run-benchmark.sh`.
