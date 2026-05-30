#!/usr/bin/env node
import { readFileSync } from "node:fs";
import path from "node:path";

const REPO_ROOT = path.resolve(import.meta.dirname, "../..");
const WEB_ROOT = path.join(REPO_ROOT, "web");

let raw = "";
for await (const chunk of process.stdin) raw += chunk;

const filePath = JSON.parse(raw || "{}").tool_input?.file_path;
if (typeof filePath !== "string" || filePath.length === 0) process.exit(0);

const resolved = path.resolve(filePath);
if (!resolved.startsWith(WEB_ROOT + path.sep)) process.exit(0);

let content;
try {
  content = readFileSync(resolved, "utf8");
} catch {
  process.exit(0);
}

const rel = path.relative(REPO_ROOT, resolved);
const INLINE_STYLE = /(?<![A-Za-z0-9_$])style\s*=\s*(?:"|\{\{)/;
const RAW_BLEED = /100vw|translateX\(\s*-50%\s*\)/;

if (resolved.endsWith(".tsx") && INLINE_STYLE.test(content)) {
  console.error(
    `web-guard: inline style in ${rel} — forbidden. Lift it into the co-located ` +
      `*.module.css and reference via class={styles.x}. See .claude/rules/web.md.`,
  );
  process.exit(2);
}

if (resolved.endsWith(".module.css") && RAW_BLEED.test(content)) {
  console.log(
    `web-guard (warning): raw 100vw / translateX(-50%) in ${rel}. Full-bleed must use ` +
      `.bleed-rule from web/assets/utility.css — do not add new raw 100vw. See .claude/rules/web.md.`,
  );
}

process.exit(0);
