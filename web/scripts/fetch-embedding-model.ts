import { encodeHex } from "jsr:@std/encoding@^1.0.10/hex";
import {
  EMBEDDING_MODEL_DIR,
  EMBEDDING_MODEL_FILES,
  EMBEDDING_MODEL_REPO,
  EMBEDDING_MODEL_REVISION,
} from "../lib/embedder.ts";

const base =
  `https://huggingface.co/${EMBEDDING_MODEL_REPO}/resolve/${EMBEDDING_MODEL_REVISION}`;

async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return encodeHex(await crypto.subtle.digest("SHA-256", bytes));
}

for (const [file, expected] of Object.entries(EMBEDDING_MODEL_FILES)) {
  const target = `${EMBEDDING_MODEL_DIR}/${file}`;
  const existing = await Deno.readFile(target).catch(() => undefined);
  if (existing && (await sha256(existing)) === expected) continue;

  const response = await fetch(`${base}/${file}`);
  if (!response.ok) throw new Error(`${file}: HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const actual = await sha256(bytes);
  if (actual !== expected) throw new Error(`${file}: sha256 ${actual}`);

  await Deno.mkdir(target.slice(0, target.lastIndexOf("/")), {
    recursive: true,
  });
  await Deno.writeFile(target, bytes);
  console.log(`fetched ${target}`);
}
