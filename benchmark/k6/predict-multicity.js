import http from "k6/http";
import { check } from "k6";
import { SharedArray } from "k6/data";

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
    : {
        http_req_failed: ["rate<0.05"],
      },
};

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

export function handleSummary(data) {
  const out = __ENV.K6_SUMMARY_FILE;
  if (out) {
    return { [out]: JSON.stringify(data, null, 2) };
  }
  return {};
}
