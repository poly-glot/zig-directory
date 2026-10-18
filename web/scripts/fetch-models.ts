import { encodeHex } from "jsr:@std/encoding@^1.0.10/hex";
import {
  EMBEDDING_MODEL_DIR,
  EMBEDDING_MODEL_FILES,
  EMBEDDING_MODEL_REPO,
  EMBEDDING_MODEL_REVISION,
} from "../lib/embedder.ts";
import {
  NER_MODEL_DIR,
  NER_MODEL_FILES,
  NER_MODEL_REPO,
  NER_MODEL_REVISION,
} from "../lib/entities.ts";

const MODELS = [
  {
    repo: EMBEDDING_MODEL_REPO,
    revision: EMBEDDING_MODEL_REVISION,
    files: EMBEDDING_MODEL_FILES,
    dir: EMBEDDING_MODEL_DIR,
  },
  {
    repo: NER_MODEL_REPO,
    revision: NER_MODEL_REVISION,
    files: NER_MODEL_FILES,
    dir: NER_MODEL_DIR,
  },
];

async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return encodeHex(await crypto.subtle.digest("SHA-256", bytes));
}

for (const model of MODELS) {
  const base = `https://huggingface.co/${model.repo}/resolve/${model.revision}`;
  for (const [file, expected] of Object.entries(model.files)) {
    const target = `${model.dir}/${file}`;
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
}
