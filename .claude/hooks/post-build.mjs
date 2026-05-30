#!/usr/bin/env node
import { existsSync, readdirSync } from "node:fs";
import path from "node:path";

const REPO_ROOT = path.resolve(import.meta.dirname, "../..");

let raw = "";
for await (const chunk of process.stdin) raw += chunk;

const command = JSON.parse(raw || "{}").tool_input?.command;
if (typeof command !== "string") process.exit(0);

const notes = [];
const isZigBuild = /\bzig\s+build\b/.test(command);
const isZigTest = /\bzig\s+build\s+test\b/.test(command);
const isGenClient = /\bzig\s+build\s+gen-client-ts\b/.test(command);

if (isZigBuild && !isZigTest && !isGenClient) {
  notes.push(
    "post-build: `zig build` ran — restart dmozdb (vite/chromium can OOM-kill it). " +
      "Launch it as a background process, not a blocking foreground call.",
  );
  const dataDir = path.join(REPO_ROOT, "data");
  if (existsSync(dataDir)) {
    const baks = readdirSync(dataDir).filter((f) => f.endsWith(".bak"));
    if (baks.length) notes.push(`post-build: stray backup artifacts in data/: ${baks.join(", ")}`);
  }
}

if (isGenClient) {
  notes.push(
    "post-build: web/lib/dmoz-protocol.gen.ts regenerated — never hand-edit it; " +
      "re-run `cd web && deno check`.",
  );
}

if (notes.length) console.log(notes.join("\n"));
process.exit(0);
