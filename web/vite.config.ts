import { defineConfig } from "vite";
import { fresh } from "@fresh/plugin-vite";

// Listen on :8000 to match the existing e2e suite (e2e/deno-app.spec.ts)
// and to avoid breaking any external scripts that hit the dev server.
export default defineConfig({
  plugins: [fresh()],
  server: {
    port: 8000,
    host: "0.0.0.0",
  },
});
