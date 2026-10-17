# Application .env loader for benchmark scripts (K8s vars stay in run-*.sh).

is_app_env_key() {
  case "$1" in
    MODEL_API_KEY | MODEL_DIR | PORT | PREDICT_CONCURRENCY | SERVICE_VERSION | HOSTNAME)
      return 0
      ;;
    PREDICT_MAX_IN_FLIGHT | PREDICT_MAX_WAITERS | PREDICT_RETRY_AFTER_SECONDS)
      return 0
      ;;
    LOG_CAPTURE_BODIES | LOG_QUEUE_SIZE | LOG_FLUSH_INTERVAL | SHUTDOWN_DRAIN | SHUTDOWN_HTTP)
      return 0
      ;;
    OTEL_*)
      return 0
      ;;
  esac
  return 1
}

# Pod labels + anti-affinity so k6 and inference land on different nodes when possible.
# BENCH_POD_ANTIAFFINITY=preferred (default) | required | 0
# BENCH_ROLE_LABEL_KEY=ml-model-go.bench/role
bench_k8s_pod_extras() {
  local role="$1"
  python3 - "${role}" "${BENCH_POD_ANTIAFFINITY:-preferred}" "${BENCH_ROLE_LABEL_KEY:-ml-model-go.bench/role}" <<'PY'
import json, sys

role, mode, label_key = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
avoid = "k6" if role == "inference" else "inference"
term = {
    "labelSelector": {"matchLabels": {label_key: avoid}},
    "topologyKey": "kubernetes.io/hostname",
}
out = {
    "metadata": {"labels": {label_key: role}},
    "spec": {},
}
if mode in ("0", "off", "false", "no"):
    print(json.dumps(out))
    raise SystemExit(0)
affinity = {}
if mode == "required":
    affinity["podAntiAffinity"] = {
        "requiredDuringSchedulingIgnoredDuringExecution": [term],
    }
else:
    affinity["podAntiAffinity"] = {
        "preferredDuringSchedulingIgnoredDuringExecution": [
            {"weight": 100, "podAffinityTerm": term},
        ],
    }
out["spec"]["affinity"] = affinity
print(json.dumps(out))
PY
}

bench_is_interactive() {
  [[ "${BENCH_NONINTERACTIVE:-0}" == "1" ]] && return 1
  [[ -t 0 ]]
}

mask_secret() {
  local v="$1"
  if [[ -z "${v}" ]]; then
    echo "(empty)"
  elif [[ "${#v}" -le 4 ]]; then
    echo "****"
  else
    echo "${v:0:4}…(${#v} chars)"
  fi
}

# Export application vars from repo .env (file wins over empty shell exports).
# Sets DOTENV_LOADED_COUNT. Returns 1 if .env missing.
load_app_dotenv() {
  local root="$1"
  local env_file="${root}/.env"
  DOTENV_LOADED_COUNT=0
  DOTENV_FILE="${env_file}"

  if [[ ! -f "${env_file}" ]]; then
    echo "ERROR: application .env not found: ${env_file}" >&2
    echo "  cp ${root}/env.sample ${env_file}" >&2
    echo "  # edit MODEL_API_KEY and OTEL_EXPORTER_OTLP_ENDPOINT" >&2
    return 1
  fi

  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      is_app_env_key "${key}" || continue
      val="${BASH_REMATCH[2]}"
      val="${val%%#*}"
      val="${val%"${val##*[![:space:]]}"}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "${val}" =~ ^\".*\"$ ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "${val}" =~ ^\'.*\'$ ]]; then
        val="${val:1:${#val}-2}"
      fi
      export "${key}=${val}"
      DOTENV_LOADED_COUNT=$((DOTENV_LOADED_COUNT + 1))
    fi
  done < "${env_file}"
  return 0
}

# JSON array [{name,value},...] for the inference pod: .env + in-cluster OTLP bench defaults.
container_app_env_json() {
  local root="$1"
  local k8s_ns="$2"
  local pod_name="${3:-}"
  python3 - "${root}/.env" "${k8s_ns}" "${pod_name}" <<'PY'
import json, os, re, sys

path, k8s_ns, pod_name = sys.argv[1], sys.argv[2], sys.argv[3]

APP_KEYS = {
    "MODEL_API_KEY", "MODEL_DIR", "PORT", "PREDICT_CONCURRENCY", "SERVICE_VERSION",
    "HOSTNAME", "LOG_CAPTURE_BODIES", "LOG_QUEUE_SIZE", "LOG_FLUSH_INTERVAL",
    "SHUTDOWN_DRAIN", "SHUTDOWN_HTTP",
    "PREDICT_MAX_IN_FLIGHT", "PREDICT_MAX_WAITERS", "PREDICT_RETRY_AFTER_SECONDS",
}

def is_app_key(key: str) -> bool:
    return key in APP_KEYS or key.startswith("OTEL_")

def parse_env(p):
    env = {}
    with open(p, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\r\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if not m:
                continue
            key, val = m.group(1), m.group(2)
            if not is_app_key(key):
                continue
            if "#" in val:
                val = val.split("#", 1)[0]
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            env[key] = val
    return env

def merge_resource_attr(attrs: str, rk: str, rv: str) -> str:
    parts = [p.strip() for p in attrs.split(",") if p.strip()]
    parts = [p for p in parts if not p.startswith(rk + "=")]
    parts.append(f"{rk}={rv}")
    return ",".join(parts)

env = parse_env(path)
if not env.get("MODEL_API_KEY"):
    raise SystemExit("MODEL_API_KEY missing in .env")

# Ladder/deploy override (does not rewrite .env): BENCH_PREDICT_CONCURRENCY=N
if (ov := os.environ.get("BENCH_PREDICT_CONCURRENCY", "").strip()) != "":
    env["PREDICT_CONCURRENCY"] = ov

# In-cluster bench defaults (matches original run-inference-api-go.sh behavior).
env.setdefault("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")
env.setdefault("OTEL_EXPORTER_OTLP_INSECURE", "true")
env.setdefault("OTEL_TRACES_EXPORTER", "otlp")
env.setdefault("OTEL_METRICS_EXPORTER", "otlp")
env.setdefault(
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    f"http://otelcol-gateway.{k8s_ns}.svc.cluster.local:4317",
)
# Keep service.namespace from .env (e.g. jeeny) so Grafana staging APM filters match.
# Only set namespace when missing — do not replace with Kubernetes namespace (otel-collector).
attrs = env.get("OTEL_RESOURCE_ATTRIBUTES", "deployment.environment=staging")
if "service.namespace=" not in attrs:
    attrs = merge_resource_attr(attrs, "service.namespace", k8s_ns)
if pod_name:
    attrs = merge_resource_attr(attrs, "service.instance.id", pod_name)
env["OTEL_RESOURCE_ATTRIBUTES"] = attrs

# Do not override kubelet HOSTNAME (pod name) with a static .env value.
env.pop("HOSTNAME", None)

items = [{"name": k, "value": env[k]} for k in sorted(env)]
print(json.dumps(items))
PY
}

print_app_env_summary() {
  local root="$1"
  local k8s_ns="${2:-${NS:-otel-collector}}"
  echo ""
  echo "── Application config (${DOTENV_FILE:-${root}/.env}) ──"
  if [[ ! -f "${root}/.env" ]]; then
    echo "  (file missing)"
    return 1
  fi
  echo "  keys in file:     ${DOTENV_LOADED_COUNT:-0}"
  echo "  MODEL_API_KEY:    $(mask_secret "${MODEL_API_KEY:-}")"
  echo "  MODEL_DIR:        ${MODEL_DIR:-<unset>}"
  echo "  PORT:             ${PORT:-<unset>}"
  if [[ -n "${BENCH_PREDICT_CONCURRENCY:-}" ]]; then
    echo "  PREDICT_CONCURRENCY: ${BENCH_PREDICT_CONCURRENCY}  (BENCH_PREDICT_CONCURRENCY override)"
  else
    echo "  PREDICT_CONCURRENCY: ${PREDICT_CONCURRENCY:-0}"
  fi
  echo "  OTEL endpoint:    ${OTEL_EXPORTER_OTLP_ENDPOINT:-<unset>}"
  echo "  OTEL service:     ${OTEL_SERVICE_NAME:-<unset>}"
  if [[ -z "${MODEL_API_KEY:-}" || -z "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]]; then
    echo "  WARNING: MODEL_API_KEY and OTEL_EXPORTER_OTLP_ENDPOINT are required in .env" >&2
    return 1
  fi
  local pod_attrs
  pod_attrs="$(container_app_env_json "${root}" "${k8s_ns}" | python3 -c 'import json,sys; e={x["name"]:x["value"] for x in json.load(sys.stdin)}; print(e.get("OTEL_RESOURCE_ATTRIBUTES",""))')"
  echo "  Pod OTEL attrs:   ${pod_attrs}"
  return 0
}

bench_confirm() {
  local prompt="$1"
  if ! bench_is_interactive; then
    return 0
  fi
  local ans
  read -r -p "${prompt} [y/N] " ans
  [[ "${ans}" =~ ^[yY]([eE][sS])?$ ]]
}

# Curl inference Service DNS from inside the cluster (same path k6 uses).
wait_for_inference_service() {
  local ns="$1"
  local svc="$2"
  local base_url="$3"
  local attempts="${4:-36}"
  local probe_pod="inference-preflight-$$"

  echo "==> Preflight ${base_url}/readyz (svc/${svc} in ${ns})"
  for i in $(seq 1 "${attempts}"); do
    local eps
    eps="$(kubectl get endpoints "${svc}" -n "${ns}" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || true)"
    if [[ -z "${eps}" ]]; then
      echo "  ${i}/${attempts}: no endpoints on svc/${svc} (is ./benchmark/run-inference-api-go.sh done?)"
      sleep 5
      continue
    fi
    kubectl delete pod "${probe_pod}" -n "${ns}" --ignore-not-found=true --wait=false 2>/dev/null || true
    if kubectl run "${probe_pod}" -n "${ns}" --restart=Never --image=curlimages/curl:8.5.0 \
      --command -- curl -sf --connect-timeout 5 --max-time 20 "${base_url}/readyz" >/dev/null 2>&1; then
      kubectl delete pod "${probe_pod}" -n "${ns}" --ignore-not-found=true --wait=false 2>/dev/null || true
      echo "==> Inference reachable"
      return 0
    fi
    kubectl delete pod "${probe_pod}" -n "${ns}" --ignore-not-found=true --wait=false 2>/dev/null || true
    echo "  ${i}/${attempts}: curl failed (endpoints: ${eps})"
    sleep 5
  done

  echo "ERROR: cannot reach ${base_url} from cluster (dial timeout in k6 usually means this)." >&2
  kubectl get pod,svc,endpoints -n "${ns}" 2>/dev/null | grep -E 'NAME|inference' >&2 || true
  return 1
}

bench_prompt_nonempty() {
  local varname="$1"
  local prompt="$2"
  local default="${3:-}"
  local current="${!varname:-}"
  if [[ -n "${current}" ]]; then
    return 0
  fi
  if ! bench_is_interactive; then
    echo "ERROR: set ${varname} (export ${varname}=… or run interactively)" >&2
    return 1
  fi
  local input
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " input
    input="${input:-${default}}"
  else
    read -r -p "${prompt}: " input
  fi
  if [[ -z "${input}" ]]; then
    echo "ERROR: ${varname} is required" >&2
    return 1
  fi
  export "${varname}=${input}"
}
