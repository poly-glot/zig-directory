import { getClient } from "../lib/dmoz-client.ts";
import { OP_NAME } from "../lib/dmoz-protocol.gen.ts";

const NS_PER_MS = 1_000_000;

const ms = (ns: number) => Math.round(ns / NS_PER_MS * 10) / 10;

const rows = (await getClient().opLatency())
  .toSorted((a, b) => b.meanNs * b.samples - a.meanNs * a.samples)
  .map((row) => ({
    op: OP_NAME[row.op] ?? String(row.op),
    samples: row.samples,
    p50: ms(row.p50Ns),
    p95: ms(row.p95Ns),
    p99: ms(row.p99Ns),
    max: ms(row.maxNs),
    mean: ms(row.meanNs),
  }));

console.table(rows);
Deno.exit(0);
