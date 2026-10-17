# Overload stability (keep `c=0`, don’t get killed)

Design note: **keep unlimited predict concurrency** (`PREDICT_CONCURRENCY=0`) as the normal operating mode — it was objectively better in benches. Make the pod **survive sustained high CPU** so kubelet does not restart it, and optionally fail excess `/predict` with **503** instead of a death spiral.

## Why `c=0` stays the default

Repeat runs @ **560 RPS / 1000m** (`C_VALUES=2 4 8 0`, 5×5m):

- **`c=0` and `c=8`** were best on p95/p99; **`c=0` needs no infra-specific tuning**.
- Lower caps (`c=2`, `c=4`) were noisier on tails.

Ladder on **`c=0`**:

| Load | Result | Peak goroutines (process) |
|------|--------|---------------------------|
| 80/city → 560 RPS | Healthy, ~4–7 ms med | — |
| 85/city → 595 RPS (`20261017T000209Z`) | **OK:** med ~4.3 ms, p95 ~33 ms | **~321** |
| 90/city → 630 RPS (`20261016T234919Z`) | **OK:** 630 RPS, 0% fail, med ~6.9 ms, p95 ~78 ms | **~346** |
| 100/city → 700 RPS (`20261016T233123Z`) | **Fail:** ~1s latency, VUs → 2100, liveness timeout → kubelet **Killing** | **~1.5k** |

So: do **not** replace `c=0` with a small `PREDICT_CONCURRENCY` as the steady-state mode. That would trade away the latency win.

**Do not size concurrency from the node** (e.g. “set `PREDICT_CONCURRENCY` = host vCPUs”). The app must not be tied to instance type. A pod on `1000m` only has ~1 CPU even on an 8‑vCPU node; `c=1`–`4` already showed **much worse latency** in repeats. Keep **`PREDICT_CONCURRENCY=0`** everywhere; stability comes from **cheap liveness** + optional **admission/503**, not from matching node specs.

## Goal

1. **Liveness → `/healthz`** (do this first). Bench/prod today use `/health-check-RUH`, which can run a real predict. Under load the probe hits `context deadline exceeded` and kubelet **stops the container**. `/healthz` is already a bare `200` with no model work — that alone stops most “100% CPU → pod restart” failures. Readiness may stay on `/readyz` (or go NotReady under overload); deep `/health-check-*` is for manual/startup checks only, **not** liveness.
2. Preserve **`PREDICT_CONCURRENCY=0`** under normal load (≈560–630 RPS): no artificial small concurrency cap.
3. Optionally add a **high admission ceiling** on how many `/predict` calls may be inside the predict path (in-flight + short wait).
4. Brief bursts may **wait** a little (bounded waiters); beyond that → **503**, pod stays up, probes still answer.

Under healthy load, average in-flight *predicts* is tiny (e.g. 630 RPS × ~7 ms ≈ **~4**). Process-wide goroutines (HTTP, runtime, OTEL, …) sat around **~321 @ 85/city** and **~346 @ 90/city**, then jumped to **~1.5k @ 100/city** with the kill. Chosen safety ceiling: **`PREDICT_MAX_IN_FLIGHT=320`** — aligned with the healthy band; at 100/city, admitted `/predict` work would hit the ceiling and return **503** long before ~1.5k goroutines / probe death.

## 1. Liveness probe (immediate)

| Probe | Path | Notes |
|-------|------|-------|
| **Liveness** | **`/healthz`** | Process up only; never runs model |
| Readiness | `/readyz` | Can fail under overload to shed traffic without killing the pod |
| Deep check | `/health-check-*` | Manual / startup only — **not** liveness |

Bench deploy today (`run-inference-api-go.sh`):

```yaml
livenessProbe:
  httpGet: { path: /health-check-RUH, port: 8456 }  # change → /healthz
```

A background goroutine does **not** satisfy kubelet by itself; the probe must get a timely HTTP response. Pointing liveness at `/healthz` is the minimal fix. (Optional later: a separate probe listen port so `/predict` saturation cannot starve accept on the main port.)

## 2. Optional: high admission ceiling + waiters

```
HTTP /predict
    │
    ▼
┌─────────────────────────────────────────────┐
│  Admission (high ceiling, not “c=1”)        │
│  - outstanding < MAX_IN_FLIGHT              │
│       → run Predict immediately (c=0 style) │
│  - else waiters < MAX_WAITERS               │
│       → short queue (burst)                 │
│  - else → Busy → HTTP 503                   │
└─────────────────────────────────────────────┘
```

`MAX_IN_FLIGHT` means “max admitted into the predict path,” **not** “run only N at a time for latency.” It is a **backstop**, sized well above healthy steady-state concurrency.

### Env

| Env | Default | Meaning |
|-----|---------|---------|
| `PREDICT_CONCURRENCY` | `0` | **Keep default.** Unlimited runners; do not require node-size tuning. |
| `PREDICT_MAX_IN_FLIGHT` | `0` (off) | Safety ceiling on admitted `/predict` calls. `0` = off (today). When set (e.g. `320`), caps how many may enter the predict path. |
| `PREDICT_MAX_WAITERS` | `0` | Extra burst waiters beyond in-flight. `0` = no wait queue (immediate **503** when in-flight is full). `>0` = short queue then 503. |

Suggested start on **1000m / 2Gi** (preserve `c=0`; goroutine peaks **321 / 346 / ~1500** at 85 / 90 / 100 per-city):

```bash
PREDICT_CONCURRENCY=0
PREDICT_MAX_IN_FLIGHT=320   # healthy band ~321–346 total GRs; meltdown ~1.5k at 100/city
PREDICT_MAX_WAITERS=64      # optional short burst cushion
```

Note: `PREDICT_MAX_IN_FLIGHT` limits **admitted `/predict` handlers**, not total process goroutines. Healthy predict in-flight is only ~tens; **320** is a backstop that should stay dormant at 85–90/city and engage as load approaches the 100/city / ~1.5k-GR failure mode.

### Acquire algorithm (sketch)

```go
// sem capacity = PREDICT_MAX_IN_FLIGHT (feature off if 0)
func (p *Pool) acquire(ctx context.Context) error {
    select {
    case p.sem <- struct{}{}:
        return nil // admitted — run immediately (many can run; c=0-like)
    default:
    }
    if p.maxWaiters == 0 {
        return BusyError{} // → 503
    }
    if atomic.AddInt64(&p.waiters, 1) > int64(p.maxWaiters) {
        atomic.AddInt64(&p.waiters, -1)
        return BusyError{}
    }
    defer atomic.AddInt64(&p.waiters, -1)

    select {
    case <-ctx.Done():
        return ctx.Err()
    case p.sem <- struct{}{}:
        return nil
    }
}
```

- `BusyError` → HTTP **503**.
- Optional metrics: in-flight gauge, waiter gauge, `predict_busy_total`, queue-wait histogram.

## Expected tradeoff

| Load | `c=0` today (liveness = health-check) | `/healthz` liveness (+ optional ceiling) |
|------|----------------------------------------|------------------------------------------|
| ≤630 RPS | Best latency; pod OK | **Same** latency |
| ≥700 RPS | Probe kill / connection refused | Pod **stays up**; with ceiling, excess `/predict` → **503** |

## Implementation checklist

1. **Bench (and prod) liveness → `/healthz`**; keep readiness on `/readyz`; leave `/health-check-*` for deep checks only.
2. (Optional) `PREDICT_MAX_IN_FLIGHT` + `PREDICT_MAX_WAITERS` + `BusyError`; tests for admit, wait, full → 503, ctx cancel.
3. Config / `env.sample` / dotenv allowlist; HTTP map busy → **503**.
4. Re-ladder: 90/city still matches bare `c=0`; at 100/city expect **no** kubelet Killing (with or without some 503s if ceiling is on).

## Out of scope / rejected approaches

- Small `PREDICT_CONCURRENCY` (1–4) as steady-state — high latency in benches.
- Setting concurrency from **host** CPU count — couples the app to node SKU; wrong under cgroup limits.
- Raising connection limits as a capacity lever.
- Multi-replica autoscaling (complementary, still per-pod admission).
