# `created_at` formats

## Production caller: location-engine

`location-engine` overwrites `dispatch.dt` on each `/direction` request and forwards it as `created_at`:

```python
now_ast.strftime("%Y-%m-%d %H:%M:%S.%f")
```

Example: `2026-01-01 14:30:45.123456` (wall clock in Asia/Riyadh, no `Z`/`UTC` in the string).

Go parses this with `time.ParseInLocation` and layouts:

- `2006-01-02 15:04:05.999999`
- `2006-01-02 15:04:05`

## Legacy / direct ml-model traffic

Also supported for parity with existing golden tests:

- `YYYY-MM-DD HH:MM:SS.ffffff UTC` (fraction + literal ` UTC` suffix)

Empty `created_at` is replaced with Asia/Riyadh “now” in `eta.Service` before parse.

Other pandas-style strings are **not** supported; callers must send one of the shapes above.
