type ProbePath = "ranked" | "targeted" | "categories";

interface Probe {
  path: ProbePath;
  route: string;
}

interface Sample {
  path: ProbePath;
  route: string;
  status: number;
  wallMs: number;
  stages: Record<string, number>;
}

const BASE = Deno.env.get("BASE") ?? "https://directory.junaid.guru";
const ROUNDS = Number(Deno.env.get("PROBE_ROUNDS") ?? 2);

const P95_BUDGET_MS: Record<ProbePath, number> = {
  ranked: Number(Deno.env.get("BUDGET_RANKED_MS") ?? 2000),
  targeted: Number(Deno.env.get("BUDGET_TARGETED_MS") ?? 1500),
  categories: Number(Deno.env.get("BUDGET_CATEGORIES_MS") ?? 500),
};

const ranked = (q: string): Probe => ({
  path: "ranked",
  route: `/api/v1/search?scope=links&limit=20&q=${encodeURIComponent(q)}`,
});

const targeted = (q: string): Probe => ({
  path: "targeted",
  route: `/search?q=${encodeURIComponent(q)}`,
});

const categories = (q: string): Probe => ({
  path: "categories",
  route: `/api/v1/search?scope=categories&limit=20&q=${encodeURIComponent(q)}`,
});

const PROBES: readonly Probe[] = [
  ranked("chess"),
  ranked("jazz festival"),
  ranked("steam railways"),
  ranked("somewhere to learn the history of jazz"),
  ranked("biographies of politicians"),
  ranked("zymurgy"),
  targeted("site:ietf.org"),
  targeted("site:cornell.edu"),
  targeted("art in japan about buddhism"),
  categories("chess"),
  categories("origami"),
  categories("lighthouses"),
];

function stagesOf(header: string | null): Record<string, number> {
  const stages: Record<string, number> = {};
  if (!header) return stages;

  for (const part of header.split(",")) {
    const [name, duration] = part.trim().split(";dur=");
    const ms = Number(duration);
    if (name && Number.isFinite(ms)) stages[name] = ms;
  }
  return stages;
}

async function sample(probe: Probe): Promise<Sample> {
  const started = performance.now();
  const response = await fetch(BASE + probe.route, {
    headers: { "user-agent": "search-probe" },
  });
  await response.arrayBuffer();

  return {
    ...probe,
    status: response.status,
    wallMs: performance.now() - started,
    stages: stagesOf(response.headers.get("server-timing")),
  };
}

function percentile(sorted: readonly number[], fraction: number): number {
  if (sorted.length === 0) return 0;
  const rank = Math.ceil(sorted.length * fraction) - 1;
  return Math.round(sorted[Math.max(0, rank)]);
}

function summarise(path: ProbePath, samples: readonly Sample[]) {
  const wall = samples.map((s) => s.wallMs).toSorted((a, b) => a - b);
  const stageNames = new Set(samples.flatMap((s) => Object.keys(s.stages)));
  const stageP50 = Object.fromEntries(
    [...stageNames].map((name) => [
      name,
      percentile(
        samples.map((s) => s.stages[name] ?? 0).toSorted((a, b) => a - b),
        0.5,
      ),
    ]),
  );

  const p95 = percentile(wall, 0.95);
  return {
    path,
    samples: samples.length,
    p50: percentile(wall, 0.5),
    p95,
    budget: P95_BUDGET_MS[path],
    overBudget: p95 > P95_BUDGET_MS[path],
    stageP50,
  };
}

const samples: Sample[] = [];
for (let round = 0; round < ROUNDS; round++) {
  for (const probe of PROBES) samples.push(await sample(probe));
}

const failed = samples.filter((s) => s.status !== 200);
const byPath = Map.groupBy(samples, (s) => s.path);
const summaries = [...byPath].map(([path, group]) => summarise(path, group));

for (const summary of summaries) console.log(JSON.stringify(summary));
for (const failure of failed) {
  console.error(
    JSON.stringify({ failed: failure.route, status: failure.status }),
  );
}

const healthy = failed.length === 0 && summaries.every((s) => !s.overBudget);
Deno.exit(healthy ? 0 : 1);
