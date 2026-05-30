import { page } from "fresh";
import { define } from "../../utils.ts";
import { getClient, type IndexHealthSnapshot } from "../../lib/dmoz-client.ts";
import AdminShell from "../../components/admin/AdminShell/AdminShell.tsx";
import AdminStatusChip from "../../components/admin/AdminStatusChip/AdminStatusChip.tsx";
import Banner from "../../components/admin/Banner/Banner.tsx";
import AdminTable from "../../components/admin/AdminTable/AdminTable.tsx";
import KpiStrip from "../../components/common/KpiStrip/KpiStrip.tsx";
import {
  type AdminContext,
  loadAdminContext,
} from "../../lib/admin-context.ts";
import { relativeTime } from "../../lib/format.ts";
import IntegrityIndexRow, {
  pctLabel,
} from "../../components/admin/IntegrityIndexRow/IntegrityIndexRow.tsx";

interface Data {
  snapshot: IndexHealthSnapshot | null;
  message?: string;
  error?: string;
  adminCtx: AdminContext;
}

async function applyAction(
  form: FormData,
  client: ReturnType<typeof getClient>,
): Promise<{ message?: string; error?: string }> {
  const action = form.get("action");
  try {
    if (action === "run_verifier") {
      const snap = await client.runVerifier();
      return {
        message: `Verifier completed at ${
          new Date(snap.lastRunAt * 1000).toISOString()
        }.`,
      };
    }
    if (action === "rebuild_index") {
      const name = String(form.get("name") ?? "");
      const result = await client.rebuildIndex(name);
      return {
        message:
          `Rebuilt ${name}: ${result.entriesInserted} entries inserted in ${result.elapsedMs} ms.`,
      };
    }
    return { error: "Unknown action." };
  } catch (e) {
    return { error: String(e) };
  }
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "Integrity · Admin";
    const adminCtx = await loadAdminContext();
    try {
      const snapshot = await getClient().indexHealth();
      return page({ snapshot, adminCtx });
    } catch (e) {
      console.error("indexHealth failed:", e);
      return page({ snapshot: null, error: String(e), adminCtx });
    }
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const result = await applyAction(form, getClient());
    const snapshot = await getClient().indexHealth().catch(() => null);
    const adminCtx = await loadAdminContext();
    return page({ snapshot, ...result, adminCtx });
  },
});

function summaryCells(snapshot: IndexHealthSnapshot | null) {
  const totalIndices = snapshot?.indices.length ?? 0;
  const driftedCount = snapshot
    ? snapshot.indices.filter((i) => i.coverageBp < 10000).length
    : 0;
  const minCoverage = snapshot && snapshot.indices.length > 0
    ? snapshot.indices.reduce((m, i) => Math.min(m, i.coverageBp), 10000)
    : 10000;
  const lastRunRel = snapshot ? relativeTime(snapshot.lastRunAt) : "never";
  return [
    { label: "Last verifier run", value: lastRunRel },
    { label: "Indices", value: String(totalIndices) },
    { label: "Drifted", value: String(driftedCount) },
    { label: "Min coverage", value: pctLabel(minCoverage) },
  ];
}

export default define.page<typeof handler>(function IntegrityPage(props) {
  const { snapshot, message, error, adminCtx } = props.data;
  return (
    <AdminShell
      active="integrity"
      title="Integrity."
      crumbs={[
        { label: "Directory", href: "/" },
        { label: "Admin", href: "/admin" },
        { label: "Integrity" },
      ]}
      tabCounts={adminCtx.tabCounts}
      tabsTrailing={<AdminStatusChip healthy={adminCtx.healthy} />}
    >
      <p class="lede mt-16">
        Per-index coverage snapshot from the verifier. Re-derive any index that
        has drifted below 100%.
      </p>

      {message && <Banner variant="success" message={message} />}
      {error && <Banner variant="error" message={`Error: ${error}`} />}

      <div class="mt-16">
        <KpiStrip cells={summaryCells(snapshot)} compact />
      </div>

      {snapshot
        ? (
          <>
            <AdminTable
              columns={["Index", "Primary", "Secondary", "Coverage", "Actions"]}
              emptyMessage="No indices reported."
            >
              {snapshot.indices.map((idx) => (
                <IntegrityIndexRow key={idx.name} idx={idx} />
              ))}
            </AdminTable>
            <form method="POST" class="mt-24">
              <input type="hidden" name="action" value="run_verifier" />
              <button type="submit" class="btn">Run verifier now</button>
            </form>
          </>
        )
        : null}
    </AdminShell>
  );
});
