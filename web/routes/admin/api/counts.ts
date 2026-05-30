import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";

// GET /admin/api/counts → { pending, approved, rejected } for the chip strip.
// counts_by_status (op 36) is an O(1) read of maintained per-status counters
// (seeded at boot, kept current by the apply path) — no full-tree scan. The
// chip strip treats a non-2xx here as "counts unavailable" and renders without
// them, so failures degrade quietly.
export const handler = define.handlers({
  async GET() {
    try {
      const counts = await getClient().countsByStatus();
      return Response.json(counts);
    } catch (e) {
      console.error("counts_by_status failed:", e);
      return Response.json({ error: String(e) }, { status: 503 });
    }
  },
});
