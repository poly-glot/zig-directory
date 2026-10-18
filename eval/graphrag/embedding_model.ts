import { fnv1a64 } from "../../web/lib/dmoz-client.ts";

export const EMBEDDING_MODEL = fnv1a64(
  new TextEncoder().encode("Xenova/bge-small-en-v1.5:model_quantized.onnx:cls"),
);
