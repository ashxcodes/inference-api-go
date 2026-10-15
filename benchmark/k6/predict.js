import http from "k6/http";
import { check } from "k6";
import { Trend, Rate } from "k6/metrics";

const predictDuration = new Trend("predict_duration", true);
const predictFailed = new Rate("predict_failed");

const baseUrl = __ENV.BASE_URL || "http://ml-model:8456";
const apiKey = __ENV.API_KEY || "benchmark-key";
// Do not use K6_* names in the container env — k6 treats them as global overrides.
const scenario = (__ENV.BENCH_SCENARIO || "sustained").trim();
const targetRps = Number(__ENV.BENCH_TARGET_RPS || "50");
const duration = __ENV.BENCH_DURATION || "3m";
const vus = Number(__ENV.BENCH_VUS || "25");

const body = JSON.stringify({
  city: "AMM",
  key: `k6-${__VU}`,
  origin_lat: 28.0,
  origin_lng: 52.0,
  destination_lat: 30.1,
  destination_lng: 54.1,
  created_at: "2024-01-01 00:00:00",
});

const headers = {
  "Content-Type": "application/json",
  "X-API-Key": apiKey,
};

function sharedThresholds(strict) {
  if (!strict) {
    return {
      predict_failed: ["rate<0.05"],
      http_req_failed: ["rate<0.05"],
    };
  }
  return {
    predict_failed: ["rate<0.01"],
    predict_duration: ["p(95)<500"],
    http_req_failed: ["rate<0.01"],
  };
}

function scenarioOptions(name) {
  const strict = name === "smoke" || name === "sustained";

  if (name === "smoke") {
    return {
      scenarios: {
        smoke: {
          executor: "constant-vus",
          vus: 5,
          duration: "30s",
        },
      },
      thresholds: sharedThresholds(true),
    };
  }

  if (name === "single_vu") {
    return {
      scenarios: {
        single_vu: {
          executor: "constant-vus",
          vus: 1,
          duration,
        },
      },
      thresholds: sharedThresholds(true),
    };
  }

  if (name === "concurrent") {
    return {
      scenarios: {
        concurrent: {
          executor: "constant-vus",
          vus,
          duration,
        },
      },
      thresholds: sharedThresholds(false),
    };
  }

  if (name === "cluster_peak") {
    return {
      scenarios: {
        cluster_peak: {
          executor: "constant-arrival-rate",
          rate: 833,
          timeUnit: "1s",
          duration: "2m",
          preAllocatedVUs: 100,
          maxVUs: 500,
        },
      },
      thresholds: sharedThresholds(false),
    };
  }

  if (name === "ramp") {
    return {
      scenarios: {
        ramp: {
          executor: "ramping-arrival-rate",
          startRate: 10,
          timeUnit: "1s",
          stages: [
            { duration: "1m", target: 50 },
            { duration: "1m", target: 100 },
            { duration: "1m", target: 150 },
            { duration: "1m", target: 200 },
          ],
          preAllocatedVUs: 50,
          maxVUs: 300,
        },
      },
      thresholds: sharedThresholds(false),
    };
  }

  const preVus = Math.max(10, Math.min(200, Math.ceil(targetRps / 3)));
  const maxVus = Math.max(preVus, Math.min(500, targetRps * 3));
  return {
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
    thresholds: sharedThresholds(strict),
  };
}

export const options = scenarioOptions(scenario);

export default function () {
  const res = http.post(`${baseUrl}/predict`, body, {
    headers,
    tags: { name: "predict" },
    timeout: "60s",
  });

  const ok = check(res, {
    "status is 200": (r) => r.status === 200,
    "has eta": (r) => {
      try {
        return typeof r.json("eta") === "number";
      } catch (_) {
        return false;
      }
    },
  });

  predictDuration.add(res.timings.duration);
  predictFailed.add(!ok);
}

export function handleSummary(data) {
  const out = __ENV.K6_SUMMARY_FILE || "/scripts/results/summary.json";
  const text = JSON.stringify(data, null, 2);
  const files = { stdout: text };
  files[out] = text;
  return files;
}
