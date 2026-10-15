# Go benchmark — ml-model-go (pure Go / go-lgbm)

## concurrent 25 VUs / 2m @ **0.7 CPU**, 1000Mi RAM

- Date: 2026-10-11
- Model: `testdata/parity/AMM.txt` (v4, ~133MB)
- `PREDICT_CONCURRENCY=4`, `OTEL_SDK_DISABLED=true`
- Artifact: `jeeny-ml-model/benchmark/k6/results/summary-go-concurrent-25vu-cpu0.7.json`

| Service | CPU limit | RPS | Total | med (ms) | p95 (ms) | avg (ms) | fail % | MEM |
|---------|----------:|----:|------:|---------:|---------:|---------:|-------:|-----|
| **ml-model-go** | 0.7 | **664.9** | 79,809 | 15.5 | 93.3 | 37.5 | 0.00% | ~148 MiB |

### Python reference (same profile, **0.5 CPU** — not apples-to-apples on CPU)

| Service | CPU | RPS | med (ms) | p95 (ms) |
|---------|----:|----:|---------:|---------:|
| Python thread pool ×4 | 0.5 | ~65–68 | ~384 | ~505 |
| Python inference sweep best | 0.5 | 65.5 | 391 | 509 |

Re-run Go bench from either repo:

```bash
# ml-model-go
BENCH_CPU=0.7 ./benchmark/run-benchmark.sh concurrent 25 2m

# or from jeeny-ml-model (builds sibling ../ml-model-go)
BENCH_CPU=0.7 bash ./benchmark/run-benchmark-go.sh concurrent 25 2m
```
