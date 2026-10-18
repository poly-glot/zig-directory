import { assertAlmostEquals, assertEquals } from "jsr:@std/assert@^1";
import { EMBEDDING_DIMS } from "./dmoz-client.ts";
import { embedQuery, embedText } from "./embedder.ts";

const PINNED_QUERY = "free sheet music for classical guitar";
const PYTHON_ONNX_LEADING_VALUES = [
  -0.06455,
  -0.02109,
  0.02991,
  0.01696,
  -0.03462,
  -0.01317,
];

function normalised(vector: Float32Array): Float32Array {
  const norm = Math.hypot(...vector);
  return vector.map((v) => v / norm);
}

Deno.test("a query embeds like the Python ONNX reference, prefix included", async () => {
  const embedding = await embedQuery(PINNED_QUERY);
  const vector = normalised(embedding!.vector);

  assertEquals(vector.length, EMBEDDING_DIMS);
  PYTHON_ONNX_LEADING_VALUES.forEach((expected, i) =>
    assertAlmostEquals(vector[i], expected, 1e-3)
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
