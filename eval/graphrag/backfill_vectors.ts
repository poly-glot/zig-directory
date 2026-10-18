import {
  DmozClient,
  EMBEDDING_DIMS,
  linkTextFingerprint,
  MAX_VECTORS_PER_WRITE,
} from "../../web/lib/dmoz-client.ts";
import { EMBEDDING_MODEL } from "./embedding_model.ts";

interface LinkText {
  id: number;
  title: string;
  description: string;
}

const host = Deno.env.get("DMOZDB_HOST") ?? "127.0.0.1";
const port = Number(Deno.env.get("DMOZDB_PORT") ?? 18080);
const indexDir = new URL("./data/index/", import.meta.url);
const client = new DmozClient(host, port);

const links: LinkText[] = JSON.parse(
  await Deno.readTextFile(new URL("link_vector_ids.json", indexDir)),
);
const raw = await Deno.readFile(new URL("link_vectors_onnx.f32", indexDir));
const vectors = new Float32Array(
  raw.buffer,
  raw.byteOffset,
  raw.byteLength / 4,
);
if (vectors.length !== links.length * EMBEDDING_DIMS) {
  throw new Error("vector file does not match the link list");
}

const counts = new Map<string, number>();
const started = performance.now();
for (let start = 0; start < links.length; start += MAX_VECTORS_PER_WRITE) {
  const batch = links.slice(start, start + MAX_VECTORS_PER_WRITE).map((
    link,
    i,
  ) => ({
    linkId: link.id,
    textFingerprint: linkTextFingerprint(link.title, link.description),
    vector: vectors.subarray(
      (start + i) * EMBEDDING_DIMS,
      (start + i + 1) * EMBEDDING_DIMS,
    ),
  }));
  for (const { code } of await client.putLinkVectors(EMBEDDING_MODEL, batch)) {
    counts.set(code, (counts.get(code) ?? 0) + 1);
  }
}

console.log(JSON.stringify({
  seconds: Math.round((performance.now() - started) / 1000),
  results: Object.fromEntries(counts),
}));
Deno.exit(0);
