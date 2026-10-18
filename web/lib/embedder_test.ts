import { assertEquals, assertGreater } from "jsr:@std/assert@^1";
import { EMBEDDING_DIMS } from "./dmoz-client.ts";
import { embedQuery, embedText } from "./embedder.ts";

const PINNED_QUERY = "free sheet music for classical guitar";
const MIN_COSINE_TO_REFERENCE = 0.999;

const pythonOnnxReference: number[] = JSON.parse(
  await Deno.readTextFile(
    new URL("./embedder_test_reference.json", import.meta.url),
  ),
);

function cosine(a: ArrayLike<number>, b: ArrayLike<number>): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / Math.sqrt(normA * normB);
}

Deno.test("a query embeds like the Python ONNX reference, prefix included", async () => {
  const embedding = await embedQuery(PINNED_QUERY);

  assertEquals(embedding!.vector.length, EMBEDDING_DIMS);
  assertGreater(
    cosine(embedding!.vector, pythonOnnxReference),
    MIN_COSINE_TO_REFERENCE,
  );
});

Deno.test("text past 128 tokens is cut, so a different tail leaves the vector unchanged", async () => {
  const opening = Array.from({ length: 126 }, (_, i) => `word${i}`).join(" ");

  const [a, b] = await Promise.all([
    embedText(`${opening} tail about gardening`),
    embedText(`${opening} a different tail about astronomy and stars`),
  ]);

  assertEquals(Array.from(a), Array.from(b));
});
