import { Tokenizer } from "@huggingface/tokenizers";
import { onnxRuntime } from "./onnx-runtime.ts";
import {
  type DmozClient,
  EMBEDDING_DIMS,
  fnv1a64,
  linkTextFingerprint,
  type QueryEmbedding,
} from "./dmoz-client.ts";
import { categoryNames } from "./format.ts";

export const EMBEDDING_MODEL_REPO = "Xenova/bge-small-en-v1.5";
export const EMBEDDING_MODEL_REVISION =
  "ea104dacec62c0de699686887e3f920caeb4f3e3";
export const EMBEDDING_MODEL_FILES: Record<string, string> = {
  "onnx/model_quantized.onnx":
    "6c9c6101a956d62dfb5e7190c538226c0c5bb9cb27b651234b6df063ee7dbfe4",
  "tokenizer.json":
    "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66",
  "tokenizer_config.json":
    "9261e7d79b44c8195c1cada2b453e55b00aeb81e907a6664974b4d7776172ab3",
};
export const EMBEDDING_MODEL = fnv1a64(
  new TextEncoder().encode(`${EMBEDDING_MODEL_REPO}:model_quantized.onnx:cls`),
);
export const EMBEDDING_MODEL_DIR = Deno.env.get("EMBEDDING_MODEL_DIR") ??
  "data/models/bge-small-en-v1.5";

const QUERY_PREFIX =
  "Represent this sentence for searching relevant passages: ";
const MAX_TOKENS = 128;

type Embed = (text: string) => Promise<Float32Array>;

let loading: Promise<Embed> | undefined;

function embedder(): Promise<Embed> {
  loading ??= loadEmbedder(EMBEDDING_MODEL_DIR).catch((e) => {
    console.error("embedder unavailable, search uses keywords only:", e);
    throw e;
  });
  return loading;
}

async function loadEmbedder(dir: string): Promise<Embed> {
  const ort = await onnxRuntime();
  const tokenizer = new Tokenizer(
    JSON.parse(await Deno.readTextFile(`${dir}/tokenizer.json`)),
    JSON.parse(await Deno.readTextFile(`${dir}/tokenizer_config.json`)),
  );
  const session = await ort.InferenceSession.create(
    await Deno.readFile(`${dir}/onnx/model_quantized.onnx`),
    { intraOpNumThreads: 1, interOpNumThreads: 1 },
  );

  return async (text) => {
    const ids = truncated(tokenizer.encode(text).ids);
    const shape = [1, ids.length];
    const out = await session.run({
      input_ids: new ort.Tensor(
        "int64",
        BigInt64Array.from(ids, BigInt),
        shape,
      ),
      attention_mask: new ort.Tensor(
        "int64",
        new BigInt64Array(ids.length).fill(1n),
        shape,
      ),
      token_type_ids: new ort.Tensor(
        "int64",
        new BigInt64Array(ids.length),
        shape,
      ),
    });
    return (out.last_hidden_state.data as Float32Array).slice(
      0,
      EMBEDDING_DIMS,
    );
  };
}

function truncated(ids: number[]): number[] {
  if (ids.length <= MAX_TOKENS) return ids;
  return [...ids.slice(0, MAX_TOKENS - 1), ids[ids.length - 1]];
}

export function linkDocumentText(
  categoryNames: readonly string[],
  title: string,
  description: string,
): string {
  const path = categoryNames.join(" > ");
  return [path, title, description].filter(Boolean).join(". ").trim();
}

export async function embedText(text: string): Promise<Float32Array> {
  return (await embedder())(text);
}

export async function embedQuery(
  query: string,
): Promise<QueryEmbedding | undefined> {
  const embed = await embedder().catch(() => undefined);
  if (!embed) return undefined;

  try {
    return {
      model: EMBEDDING_MODEL,
      vector: await embed(QUERY_PREFIX + query),
    };
  } catch (e) {
    console.error("embedQuery failed, searching by keywords only:", e);
    return undefined;
  }
}

export async function storeLinkVector(
  client: DmozClient,
  linkId: number,
): Promise<void> {
  try {
    const link = await client.getLink(linkId);
    const chains = await client.breadcrumbsByIds([link.categoryId]);
    const vector = await embedText(
      linkDocumentText(
        categoryNames(chains.get(link.categoryId) ?? []),
        link.title,
        link.description,
      ),
    );
    const [result] = await client.putLinkVectors(EMBEDDING_MODEL, [{
      linkId,
      textFingerprint: linkTextFingerprint(link.title, link.description),
      vector,
    }]);
    if (result.code !== "ok") {
      console.error(`storeLinkVector ${linkId}: ${result.code}`);
    }
  } catch (e) {
    console.error(`storeLinkVector ${linkId}: keyword search only:`, e);
  }
}
