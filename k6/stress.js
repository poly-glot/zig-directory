import http from "k6/http";
import { check, group, sleep } from "k6";
import { Trend } from "k6/metrics";

// Stress test for the dmozdb directory: homepage, category pages (incl.
// deeper subtrees + pagination), and search. Hits the live OKE deployment.
const BASE = __ENV.BASE_URL || "https://directory.junaid.guru";

// Tunable load profile. Override per-run with `-e VUS=50 -e DURATION=1m`,
// or rely on the ramping stages below when STAGED=1 (the default).
const VUS = parseInt(__ENV.VUS || "300", 10);
const DURATION = __ENV.DURATION || "5m";
const STAGED = (__ENV.STAGED || "0") === "1";

// Cloud run config. Pin execution to the London load zone (eu-west, closest to
// the OKE deployment) so latency reflects the app, not transatlantic RTT.
// Zone codes: https://grafana.com/docs/grafana-cloud/testing/k6/author-run/use-load-zones/
const CLOUD = {
  projectID: 7298441,
  name: "dmozdb directory — home/categories/search stress",
  distribution: {
    london: { loadZone: "amazon:gb:london", percent: 100 },
  },
};

// Per-area latency so the cloud dashboard breaks down where pressure lands.
const homeTrend = new Trend("home_duration", true);
const categoryTrend = new Trend("category_duration", true);
const searchTrend = new Trend("search_duration", true);

const TOP = [
  "arts",
  "business",
  "computers",
  "games",
  "health",
  "home",
  "news",
  "recreation",
  "reference",
  "science",
  "shopping",
  "society",
  "sports",
];

// Deeper subtrees exercise the server's recursive list_subtree ops, not just
// the cached top level.
const SUBCATS = [
  "arts/animation",
  "arts/architecture",
  "arts/comics",
  "arts/design",
  "arts/music",
  "computers/software",
  "science/biology",
  "sports/soccer",
];

const QUERIES = [
  "music",
  "linux",
  "football",
  "history",
  "design",
  "python",
  "travel",
  "recipes",
  "guitar",
  "astronomy",
];

const SORTS = ["relevance", "recent", "az"];

function pick(arr) {
  // Math.random is allowed in k6 scripts (this is not a Workflow script).
  return arr[Math.floor(Math.random() * arr.length)];
}

// k6's JS runtime (goja) has no URLSearchParams global, so build query strings
// by hand. Pairs is an array of [key, value]; empty values are dropped.
function qs(pairs) {
  const parts = [];
  for (const [k, v] of pairs) {
    if (v === "" || v === null || v === undefined) continue;
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(v)}`);
  }
  return parts.length ? `?${parts.join("&")}` : "";
}

export const options = STAGED
  ? {
    stages: [
      { duration: "30s", target: VUS }, // ramp up
      { duration: "1m", target: VUS }, // hold
      { duration: "30s", target: VUS * 2 }, // spike
      { duration: "30s", target: 0 }, // ramp down
    ],
    thresholds: {
      http_req_failed: ["rate<0.01"], // <1% errors
      http_req_duration: ["p(95)<800", "p(99)<2000"],
    },
    cloud: CLOUD,
  }
  : {
    vus: VUS,
    duration: DURATION,
    thresholds: {
      http_req_failed: ["rate<0.01"],
      http_req_duration: ["p(95)<800", "p(99)<2000"],
    },
    cloud: CLOUD,
  };

export default function () {
  group("homepage", function () {
    const res = http.get(`${BASE}/`, { tags: { area: "home", name: "home" } });
    homeTrend.add(res.timings.duration);
    check(res, {
      "home 200": (r) => r.status === 200,
      "home has categories": (r) => r.body.includes("/category/"),
    });
  });
  sleep(Math.random() * 1.5);

  group("category", function () {
    // Mix top-level, deep subtree, and a paginated/sorted listing.
    const roll = Math.random();
    let path, query = "";
    if (roll < 0.5) {
      path = pick(TOP);
    } else if (roll < 0.85) {
      path = pick(SUBCATS);
    } else {
      path = pick(TOP);
      const sort = pick(SORTS);
      query = qs([
        ["page", String(1 + Math.floor(Math.random() * 3))],
        ["sort", sort === "relevance" ? "" : sort],
      ]);
    }
    const res = http.get(`${BASE}/category/${path}${query}`, {
      tags: { area: "category", name: "category" },
    });
    categoryTrend.add(res.timings.duration);
    check(res, { "category 200": (r) => r.status === 200 });
  });
  sleep(Math.random() * 1.5);

  group("search", function () {
    const sort = pick(SORTS);
    const query = qs([
      ["q", pick(QUERIES)],
      ["sort", sort === "relevance" ? "" : sort],
    ]);
    const res = http.get(`${BASE}/search${query}`, {
      tags: { area: "search", name: "search" },
    });
    searchTrend.add(res.timings.duration);
    check(res, { "search 200": (r) => r.status === 200 });
  });
  sleep(Math.random() * 1.5);
}