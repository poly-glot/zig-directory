type OnnxRuntime = typeof import("onnxruntime-node");

let runtime: Promise<OnnxRuntime> | undefined;

export function onnxRuntime(): Promise<OnnxRuntime> {
  if (!runtime) {
    Deno.env.set("ORT_DISABLE_TELEMETRY", "1");
    runtime = import("onnxruntime-node");
  }
  return runtime;
}
