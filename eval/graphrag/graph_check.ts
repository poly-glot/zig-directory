import { DmozClient, type LinkQuery } from "../../web/lib/dmoz-client.ts";

interface Gold {
  question: string;
  query: LinkQuery & { category?: string };
  answer: {
    total: number;
    sites: number;
    hosts: number;
    domains: number;
    groups: Array<
      { label: string; categoryId: number; links: number; sites: number }
    >;
    ids: number[];
  };
}

const host = Deno.env.get("DMOZDB_HOST") ?? "127.0.0.1";
const port = Number(Deno.env.get("DMOZDB_PORT") ?? 18080);
const client = new DmozClient(host, port);
const gold: Gold[] = JSON.parse(
  await Deno.readTextFile(new URL("./out/graph_gold.json", import.meta.url)),
);

async function categoryId(path: string | undefined): Promise<number> {
  return path ? (await client.browsePath(path)).category.id : 0;
}

let failures = 0;
const latencies: number[] = [];
for (const { question, query, answer } of gold) {
  const { category, ...rest } = query;
  const started = performance.now();
  const got = await client.queryLinks({
    ...rest,
    categoryId: await categoryId(category),
  });
  latencies.push(performance.now() - started);

  const native = {
    total: got.total,
    sites: got.sites,
    hosts: got.hosts,
    domains: got.domains,
    groups: got.groups,
    ids: got.links.map((l) => l.id),
  };
  const matches = got.ready &&
    JSON.stringify(native) === JSON.stringify(answer);
  if (!matches) failures++;
  console.log(`${matches ? "PASS" : "FAIL"}  ${question}`);
  if (!matches) {
    console.log("  native:   ", JSON.stringify(native).slice(0, 400));
    console.log("  reference:", JSON.stringify(answer).slice(0, 400));
  }
}

latencies.sort((a, b) => a - b);
console.log(JSON.stringify({
  questions: gold.length,
  failures,
  ms: {
    p50: Math.round(latencies[latencies.length >> 1]),
    max: Math.round(latencies[latencies.length - 1]),
  },
}));
Deno.exit(failures === 0 ? 0 : 1);
