#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";

const REPO_ROOT = path.resolve(import.meta.dirname, "../..");
const WEB_ROOT = path.join(REPO_ROOT, "web");

let raw = "";
for await (const chunk of process.stdin) raw += chunk;
const payload = JSON.parse(raw || "{}");

// Infinite-loop guard: if we already blocked once for this stop, let it through.
if (payload.stop_hook_active) process.exit(0);

const status = spawnSync("git", ["status", "--porcelain"], { cwd: REPO_ROOT, encoding: "utf8" });
const files = (status.stdout || "")
  .split("\n")
  .map((line) => line.slice(3).trim())
  .filter(Boolean);

const webTouched = files.some((f) => f.startsWith("web/") && /\.(ts|tsx|js|json|css|md)$/.test(f));
const zigTouched = files.some((f) => f.endsWith(".zig"));

function gate(label, cmd, args, cwd) {
  const res = spawnSync(cmd, args, { cwd, encoding: "utf8" });
  if (res.status === 0) return true;
  const out = ((res.stdout || "") + (res.stderr || "")).slice(-3000);
  console.error(`verify-gate: ${label} FAILED — do not declare done until it passes.\n${out}`);
  return false;
}

let ok = true;
if (zigTouched) ok = gate("zig build test", "zig", ["build", "test"], REPO_ROOT) && ok;
if (webTouched) ok = gate("deno task check", "deno", ["task", "check"], WEB_ROOT) && ok;

process.exit(ok ? 0 : 2);
