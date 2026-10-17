# Overload stability

Keep **`PREDICT_CONCURRENCY=0`** (best latency in benches; not tied to node SKU). Survive overload with **cheap liveness**, **admission backstop**, and **HTTP 503 + `Retry-After`** instead of a kubelet kill spiral.

## Capacity on 1000m / 2Gi (`c=0`)

| Load | Result | Peak goroutines |
|------|--------|-----------------|
| 85/city → 595 RPS | OK — med ~4.3 ms, p95 ~33 ms | ~321 |
| 90/city → 630 RPS | OK — med ~7–11 ms, p95 ~78–116 ms | ~338–346 |
| 100/city → 700 RPS | Fail — multi-second latency, probe timeout, pod **Killed** | ~1.5k |

`c=1`–`4` raised latency; do not size concurrency from host vCPUs.

## Implemented

### 1. Liveness → `/healthz`

Bench deploy (`benchmark/run-inference-api-go.sh`):

- Liveness: `/healthz` (`timeoutSeconds: 2`)
- Readiness: `/readyz`
- Deep `/health-check-*` — not used for liveness

`/healthz` alone is **not enough** at 100/city: probes share `:8456` with `/predict` and can still starve. Optional later: separate probe listen port.

### 2. Admission ceiling + waiters → 503

```
/predict → admit if in-flight < MAX_IN_FLIGHT
        → else wait if waiters < MAX_WAITERS
        → else 503 + Retry-After
```

| Env | Default | Meaning |
|-----|---------|---------|
| `PREDICT_CONCURRENCY` | `0` | Keep unlimited runners (steady-state). |
| `PREDICT_MAX_IN_FLIGHT` | `0` (off) | Max admitted `/predict` calls. Set **`320`** on 1000m. |
| `PREDICT_MAX_WAITERS` | `0` | Extra waiters when in-flight is full. Set **`64`**. `0` = immediate 503 when full. |
| `PREDICT_RETRY_AFTER_SECONDS` | `1` | Value of the **`Retry-After`** response header on 503 (seconds). |

Recommended `.env` / `env.sample` for 1000m:

```bash
PREDICT_CONCURRENCY=0
PREDICT_MAX_IN_FLIGHT=320
PREDICT_MAX_WAITERS=64
PREDICT_RETRY_AFTER_SECONDS=1
```

**503 response**

```http
HTTP/1.1 503 Service Unavailable
Retry-After: 1
Content-Type: application/json

{"detail":"predict queue full"}
```

Clients should honor `Retry-After` before retrying.

Waypoint uses one admission slot for both legs (`Pool.Run`). See `internal/inference/pool.go`, `internal/httpapi/server.go`.

## Expected behavior

| Load | Without admission | With 320 / 64 + `/healthz` |
|------|-------------------|----------------------------|
| ≤90/city | OK | OK (ceiling usually idle) |
| 100/city | Pod kill / connection refused | Excess `/predict` → **503** + `Retry-After`; pod should stay up |

## Rejected approaches

- Small `PREDICT_CONCURRENCY` (1–4) as steady-state
- Setting concurrency from host CPU count
- Raising connection limits as a capacity lever

## Still optional

- Separate probe HTTP port (stronger liveness under saturation)
- Metrics: in-flight / waiters / busy count
