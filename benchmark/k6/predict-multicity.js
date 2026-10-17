import http from "k6/http";
import { check } from "k6";
import { SharedArray } from "k6/data";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";

const baseUrl = __ENV.BASE_URL || "http://127.0.0.1:8456";
const apiKey = __ENV.API_KEY || "benchmark-key";
const perCityRps = Number(__ENV.BENCH_PER_CITY_RPS || "1000");
const duration = __ENV.BENCH_DURATION || "5m";
const fixtureDir = __ENV.FIXTURE_DIR || "/scripts/fixtures/multicity";
const strict = (__ENV.BENCH_STRICT || "0") === "1";

const CITIES = ["RUH", "JED", "AMM", "DMM", "MAD", "MEC", "OtherCities"];

function flattenFixture(city) {
  const raw = JSON.parse(open(`${fixtureDir}/${city}.json`));
  const bodies = [];
  for (const cust of raw.customers) {
    for (const drv of cust.drivers) {
      const body = {
        city: raw.city,
        key: drv.key,
        origin_lat: drv.origin_lat,
        origin_lng: drv.origin_lng,
        destination_lat: cust.destination_lat,
        destination_lng: cust.destination_lng,
        created_at: cust.created_at,
      };
      if (drv.waypoint_lat != null) {
        body.waypoint_lat = drv.waypoint_lat;
        body.waypoint_lng = drv.waypoint_lng;
      }
      bodies.push(JSON.stringify(body));
    }
  }
  return bodies;
}

const cityBodies = {};
for (const city of CITIES) {
  cityBodies[city] = new SharedArray(`bodies-${city}`, () => flattenFixture(city));
}

const headers = {
  "Content-Type": "application/json",
  "X-API-Key": apiKey,
};

function vuCaps(rps) {
  const pre = Math.max(20, Math.min(500, Math.ceil(rps / 2)));
  const max = Math.max(pre, Math.min(3000, rps * 3));
  return { preAllocatedVUs: pre, maxVUs: max };
}

function scenarioFor(city) {
  const caps = vuCaps(perCityRps);
  return {
    executor: "constant-arrival-rate",
    exec: `predict_${city}`,
    rate: perCityRps,
    timeUnit: "1s",
    duration,
    preAllocatedVUs: caps.preAllocatedVUs,
    maxVUs: caps.maxVUs,
    tags: { city },
  };
}

const scenarios = {};
for (const city of CITIES) {
  scenarios[`load_${city}`] = scenarioFor(city);
}

export const options = {
  scenarios,
  // Default: no pass/fail thresholds — failures under load are the capacity signal.
  thresholds: strict
    ? {
        http_req_failed: ["rate<0.01"],
        "http_req_duration{city:RUH}": ["p(99)<500"],
        "http_req_duration{city:JED}": ["p(99)<500"],
        "http_req_duration{city:AMM}": ["p(99)<500"],
        "http_req_duration{city:DMM}": ["p(99)<500"],
        "http_req_duration{city:MAD}": ["p(99)<500"],
        "http_req_duration{city:MEC}": ["p(99)<500"],
        "http_req_duration{city:OtherCities}": ["p(99)<500"],
      }
    : {},
};

export function setup() {
  const ready = http.get(`${baseUrl}/readyz`, {
    timeout: "30s",
    tags: { name: "setup_readyz" },
  });
  if (ready.status !== 200) {
    throw new Error(
      `inference not reachable: GET ${baseUrl}/readyz => status ${ready.status} error=${ready.error}`
    );
  }
  const sample = cityBodies.RUH[0];
  const probe = http.post(`${baseUrl}/predict`, sample, {
    headers,
    timeout: "120s",
    tags: { name: "setup_predict" },
  });
  if (probe.status !== 200) {
    throw new Error(
      `predict preflight failed: POST ${baseUrl}/predict => status ${probe.status} error=${probe.error}`
    );
  }
}

function predictCity(city) {
  const bodies = cityBodies[city];
  const body = bodies[Math.floor(Math.random() * bodies.length)];
  const res = http.post(`${baseUrl}/predict`, body, {
    headers,
    tags: { name: "predict", city },
    timeout: "60s",
  });
  check(res, {
    "status is 200": (r) => r.status === 200,
    "has eta": (r) => {
      try {
        return JSON.parse(r.body).eta != null;
      } catch {
        return false;
      }
    },
  });
}

export function predict_RUH() {
  predictCity("RUH");
}
export function predict_JED() {
  predictCity("JED");
}
export function predict_AMM() {
  predictCity("AMM");
}
export function predict_DMM() {
  predictCity("DMM");
}
export function predict_MAD() {
  predictCity("MAD");
}
export function predict_MEC() {
  predictCity("MEC");
}
export function predict_OtherCities() {
  predictCity("OtherCities");
}

function multicityLines(data) {
  const m = data.metrics;
  const lines = [];
  const targetTotal = perCityRps * CITIES.length;
  const http = m.http_reqs?.values ?? {};
  const attemptedRps = http.rate ?? 0;
  const dur = m.http_req_duration?.values ?? {};
  const failedRate = m.http_req_failed?.values?.rate ?? 0;
  const dropped = m.dropped_iterations?.values?.count ?? 0;
  const successRps = attemptedRps * (1 - failedRate);
  const atCapacity = failedRate > 0.001;
  const generatorLimited = dropped > 0;

  lines.push("=== multicity load ===");
  lines.push(`target_rps_total: ${targetTotal} (${perCityRps}/city × ${CITIES.length})`);
  lines.push(`attempted_http_rps: ${attemptedRps.toFixed(2)}`);
  lines.push(`successful_http_rps: ${successRps.toFixed(2)}`);
  lines.push(
    `http_requests: ${http.count ?? 0}  failed: ${(failedRate * 100).toFixed(2)}%  dropped_iterations: ${dropped}`
  );
  lines.push(
    `http_req_duration_ms (successful reqs): avg=${fmt(dur.avg)} med=${fmt(dur.med)} p90=${fmt(dur["p(90)"])} p95=${fmt(dur["p(95)"])} p99=${fmt(dur["p(99)"])} max=${fmt(dur.max)}`
  );

  for (const city of CITIES) {
    const key = `http_req_duration{city:${city}}`;
    const sub = m[key]?.values;
    if (sub) {
      lines.push(
        `  ${city}: p95=${fmt(sub["p(95)"])} p99=${fmt(sub["p(99)"])} avg=${fmt(sub.avg)}`
      );
    }
  }

  lines.push("");
  lines.push("=== capacity (current service config) ===");
  if (atCapacity) {
    lines.push(
      "service_limit: yes — failed/timed-out requests mean the inference pod config is overloaded."
    );
    lines.push(
      `ceiling_estimate_total_rps: ~${successRps.toFixed(2)} (~${(successRps / CITIES.length).toFixed(2)}/city)`
    );
    lines.push(
      "next_step: lower BENCH_PER_CITY_RPS or scale CPU/memory/replicas, then re-run."
    );
  } else {
    lines.push(
      "service_limit: no — 0% failed HTTP; inference kept up with successful requests."
    );
    lines.push(
      `successful_rps: ${successRps.toFixed(2)} (target ${targetTotal})`
    );
  }
  if (generatorLimited) {
    lines.push("");
    lines.push("=== load generator ===");
    lines.push(
      `dropped_iterations: ${dropped} — k6 could not inject full target RPS (scheduler/VU cap or CPU on k6 node).`
    );
    lines.push(
      "next_step: run k6 on a different node than inference (BENCH_POD_ANTIAFFINITY), raise maxVUs, or lower target."
    );
  }
  return lines.join("\n");
}

function fmt(n) {
  if (n == null || Number.isNaN(n)) return "n/a";
  return Number(n).toFixed(2);
}

export function handleSummary(data) {
  const summaryPath = __ENV.K6_SUMMARY_FILE || "/summary/k6-summary.json";
  const block = multicityLines(data);
  return {
    stdout: `${textSummary(data, { indent: " ", enableColors: false })}\n\n${block}\n`,
    [summaryPath]: JSON.stringify(data, null, 2),
  };
}
