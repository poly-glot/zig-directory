import { page } from "fresh";
import { define } from "../../utils.ts";
import { type DbStats, getClient } from "../../lib/dmoz-client.ts";
import AdminShell from "../../components/admin/AdminShell/AdminShell.tsx";
import AdminStatusChip from "../../components/admin/AdminStatusChip/AdminStatusChip.tsx";
import Banner from "../../components/admin/Banner/Banner.tsx";
import CategoryRow from "../../components/common/CategoryRow/CategoryRow.tsx";
import KpiStrip from "../../components/common/KpiStrip/KpiStrip.tsx";
import SectionHead from "../../components/common/SectionHead/SectionHead.tsx";
import {
  type AdminContext,
  loadAdminContext,
} from "../../lib/admin-context.ts";

interface Data {
  stats: DbStats | null;
  adminCtx: AdminContext;
}

const fmt = (n: number) => n.toLocaleString();

const QUICK_LINKS: { href: string; title: string; desc: string }[] = [
  {
    href: "/admin/categories",
    title: "Categories",
    desc: "Create, edit, and organise directory categories.",
  },
  {
    href: "/admin/links",
    title: "Links",
    desc: "Add, update, and remove directory listings.",
  },
  {
    href: "/admin/users",
    title: "Users",
    desc: "View registered users and manage roles.",
  },
  {
    href: "/admin/integrity",
    title: "Integrity",
    desc: "Inspect index coverage and run the verifier.",
  },
];

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "Admin";
    const adminCtx = await loadAdminContext();
    const stats = await getClient().stats().catch(() => null);
    return page({ stats, adminCtx });
  },
});

export default define.page<typeof handler>(function AdminDashboard(props) {
  const { stats, adminCtx } = props.data;
  const total = stats ? stats.cacheHits + stats.cacheMisses : 0;
  const hitRate = total > 0
    ? Math.round((stats!.cacheHits / total) * 100).toString()
    : "0";

  const cache = [
    { label: "Cache hits", value: stats ? fmt(stats.cacheHits) : "--" },
    { label: "Cache misses", value: stats ? fmt(stats.cacheMisses) : "--" },
    { label: "Hit rate", value: stats ? `${hitRate}%` : "--" },
    { label: "WAL pending", value: stats ? fmt(stats.walPending) : "--" },
  ];

  return (
    <>
      <AdminShell
        active="dashboard"
        title="Dashboard."
        crumbs={[
          { label: "Directory", href: "/" },
          { label: "Admin" },
        ]}
        tabCounts={adminCtx.tabCounts}
        tabsTrailing={<AdminStatusChip healthy={adminCtx.healthy} />}
      >
        {!adminCtx.healthy && (
          <Banner
            variant="error"
            message="The Zig backend is currently unreachable."
          />
        )}

        <ul class="list list-bleed-borders mt-32">
          {QUICK_LINKS.map((q, i) => (
            <CategoryRow
              key={q.href}
              num={String(i + 1).padStart(2, "0")}
              href={q.href}
              name={q.title}
              childrenPreview={[q.desc]}
            />
          ))}
        </ul>
      </AdminShell>

      <section class="section dark">
        <div class="container">
          <SectionHead
            num="01"
            topic="Backend"
            title="Cache + WAL."
            lede="Live metrics from the embedded Zig server."
          />
          <KpiStrip cells={cache} />
        </div>
      </section>
    </>
  );
});
