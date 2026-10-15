import http from "k6/http";
import { check } from "k6";
import { SharedArray } from "k6/data";

const baseUrl = __ENV.BASE_URL;
const apiKey = __ENV.API_KEY || "benchmark-key";
const targetRps = Number(__ENV.BENCH_TARGET_RPS || "50");
const duration = __ENV.BENCH_DURATION || "45s";

function mulberry32(seed) {
  let a = seed;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// 2,000 distinct trips inside Amman (lat 31.85-32.05, lng 35.80-36.05) at varied days and hours.
const bodies = new SharedArray("amman-trips", function () {
  const rand = mulberry32(20261011);
  const pad = (n) => String(n).padStart(2, "0");
  const out = [];
  for (let i = 0; i < 2000; i++) {
    out.push(JSON.stringify({
      city: "AMM",
      key: `v-${i}`,
      origin_lat: 31.85 + rand() * 0.2,
      origin_lng: 35.8 + rand() * 0.25,
      destination_lat: 31.85 + rand() * 0.2,
      destination_lng: 35.8 + rand() * 0.25,
      created_at: `2024-06-${pad(1 + Math.floor(rand() * 28))} ${pad(Math.floor(rand() * 24))}:${pad(Math.floor(rand() * 60))}:00`,
    }));
  }
  return out;
});

const headers = { "Content-Type": "application/json", "X-API-Key": apiKey };
const preVus = Math.max(10, Math.min(200, Math.ceil(targetRps / 3)));
const maxVus = Math.max(preVus, Math.min(500, targetRps * 3));

export const options = {
  scenarios: {
    sustained: {
      executor: "constant-arrival-rate",
      rate: targetRps,
      timeUnit: "1s",
      duration,
      preAllocatedVUs: preVus,
      maxVUs: maxVus,
    },
  },
};

export default function () {
  const body = bodies[Math.floor(Math.random() * bodies.length)];
  const res = http.post(`${baseUrl}/predict`, body, { headers, tags: { name: "predict" }, timeout: "60s" });
  check(res, {
    "status is 200": (r) => r.status === 200,
    "has eta": (r) => {
      try {
        return typeof r.json("eta") === "number";
      } catch (_) {
        return false;
      }
    },
  });
}

export function handleSummary(data) {
  const out = __ENV.K6_SUMMARY_FILE || "/scripts/results/summary.json";
  return { [out]: JSON.stringify(data, null, 2) };
}
