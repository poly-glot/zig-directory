#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const REPO_ROOT = path.resolve(import.meta.dirname, "../..");
const WEB_ROOT = path.join(REPO_ROOT, "web");
const MCP_ROOT = path.join(REPO_ROOT, "mcp");

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
const zigTouched = files.some((f) => f.endsWith(".zig") || f.endsWith(".zon"));
const mcpTouched = files.some((f) => f.startsWith("mcp/") && f.endsWith(".py"));

function gate(label, cmd, args, cwd) {
  const res = spawnSync(cmd, args, { cwd, encoding: "utf8" });
  if (res.status === 0) return true;
  const out = ((res.stdout || "") + (res.stderr || "")).slice(-3000);
  console.error(`verify-gate: ${label} FAILED — do not declare done until it passes.\n${out}`);
  return false;
}

// build.zig.zon names the Zig this repo needs; the `zig` on PATH is often older. Look for the
// matching toolchain where the host keeps it before giving up.
function zigBinary() {
  const zon = readFileSync(path.join(REPO_ROOT, "build.zig.zon"), "utf8");
  const wanted = (zon.match(/minimum_zig_version\s*=\s*"([^"]+)"/) || [])[1];
  const majorMinor = wanted ? wanted.split(".").slice(0, 2).join(".") : null;
  const onPath = spawnSync("zig", ["version"], { encoding: "utf8" });
  if (onPath.status === 0 && (!majorMinor || onPath.stdout.trim().startsWith(majorMinor))) {
    return "zig";
  }
  const home = os.homedir();
  const candidates = wanted
    ? [
        path.join(home, "Library", "zig", wanted, "zig"),
        path.join(home, ".zig", wanted, "zig"),
        path.join(home, ".local", "zig", wanted, "zig"),
        `/usr/local/zig-${wanted}/zig`,
      ]
    : [];
  return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

// dmozdb only builds for Linux (O_DIRECT, epoll). On macOS the hook runs what the host can:
// the TigerStyle checker and a Linux cross-compile of the whole test binary, whose run step is
// the only step allowed to fail. The full suite still needs the Docker gate.
function zigGate() {
  const zig = zigBinary();
  if (!zig) {
    console.error("verify-gate: no Zig matching build.zig.zon on PATH or in ~/Library/zig — install it.");
    return false;
  }
  if (process.platform !== "darwin") return gate("zig build test", zig, ["build", "test"], REPO_ROOT);

  let ok = gate("zig test src/tidy.zig", zig, ["test", "src/tidy.zig"], REPO_ROOT);
  ok =
    gate(
      "zig build -Dtools=true (cross-compile)",
      zig,
      ["build", "-Dtools=true", "-Dtarget=aarch64-linux-musl", "--cache-dir", ".zig-cache-host"],
      REPO_ROOT,
    ) && ok;
  const cross = spawnSync(
    zig,
    ["build", "test", "-Dtarget=aarch64-linux-musl", "--cache-dir", ".zig-cache-host"],
    { cwd: REPO_ROOT, encoding: "utf8" },
  );
  const out = (cross.stdout || "") + (cross.stderr || "");
  const compileErrors = out
    .split("\n")
    .filter((line) => /: error:/.test(line) && !/unable to execute binaries/.test(line));
  if (compileErrors.length > 0) {
    console.error(
      `verify-gate: zig build test (cross-compile) FAILED — do not declare done until it passes.\n${compileErrors.join("\n").slice(-3000)}`,
    );
    ok = false;
  }
  console.error("verify-gate: macOS host — run the full suite in the Docker gate before declaring done.");
  return ok;
}

let ok = true;
if (zigTouched) ok = zigGate() && ok;
if (webTouched) ok = gate("deno task check", "deno", ["task", "check"], WEB_ROOT) && ok;
if (mcpTouched) {
  ok =
    gate(
      "mcp check (ruff + mypy + pytest)",
      "sh",
      [
        "-c",
        "uv run ruff format --check . && uv run ruff check . && uv run mypy . && uv run pytest -q",
      ],
      MCP_ROOT,
    ) && ok;
}

process.exit(ok ? 0 : 2);
