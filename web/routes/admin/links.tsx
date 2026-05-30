import { page } from "fresh";
import { define } from "../../utils.ts";
import {
  getClient,
  type Link,
  type LinkStatus,
} from "../../lib/dmoz-client.ts";
import AdminShell from "../../components/admin/AdminShell/AdminShell.tsx";
import AdminStatusChip from "../../components/admin/AdminStatusChip/AdminStatusChip.tsx";
import Banner from "../../components/admin/Banner/Banner.tsx";
import {
  type AdminContext,
  loadAdminContext,
} from "../../lib/admin-context.ts";
import { formField } from "../../lib/utils.ts";
import LinkRow from "../../components/admin/AdminLinkRow/AdminLinkRow.tsx";
import AdminTable from "../../components/admin/AdminTable/AdminTable.tsx";
import AdminFilterChips from "../../components/admin/AdminFilterChips/AdminFilterChips.tsx";
import AdminPaginator from "../../components/admin/AdminPaginator/AdminPaginator.tsx";
import AdminSearchBar from "../../islands/AdminSearchBar.tsx";
import AdminBulkBar from "../../islands/AdminBulkBar.tsx";
import AdminHintBanner from "../../islands/AdminHintBanner.tsx";
import { loadAncestorMap } from "../search/_lib/ancestors.ts";

/** Resolved Category-cell text for a link: leaf name + full "Top / … / leaf" path. */
interface CategoryInfo {
  name: string;
  path: string;
}

/** Resolve leaf name + full path for each referenced category id, batched. */
async function loadCategoryInfo(
  client: ReturnType<typeof getClient>,
  links: Link[],
): Promise<Record<number, CategoryInfo>> {
  const ids = [
    ...new Set(links.map((l) => l.categoryId).filter((id) => id > 0)),
  ];
  if (ids.length === 0) return {};
  const map = await loadAncestorMap(client, ids);
  const out: Record<number, CategoryInfo> = {};
  for (const id of ids) {
    const names: string[] = [];
    let cur = id;
    for (let i = 0; i < 16 && cur > 0; i++) {
      const c = map.get(cur);
      if (!c) break;
      names.unshift(c.name);
      cur = c.parentId;
    }
    if (names.length > 0) {
      out[id] = { name: names[names.length - 1], path: names.join(" / ") };
    }
  }
  return out;
}

export type StatusFilter = LinkStatus | "all";

const PAGE_SIZE = 50;

interface Data {
  links: Link[];
  selectedCategoryId: number;
  statusFilter: StatusFilter;
  query: string;
  cursorStack: string;
  nextAfterId: number;
  counts: { pending: number; approved: number; rejected: number };
  /** categoryId → { leaf name, full path } for the Category column. */
  categoryInfo: Record<number, CategoryInfo>;
  /** Absolute URL of the current request, for SSR cursor/chip link building. */
  baseUrl: string;
  message?: string;
  subtreeMode?: boolean;
  isRoot?: boolean;
  adminCtx: AdminContext;
}

function parseStatusFilter(raw: string | null): StatusFilter {
  if (raw === "pending" || raw === "approved" || raw === "rejected") return raw;
  return "all";
}

async function loadLinks(
  client: ReturnType<typeof getClient>,
  categoryId: number,
  filter: StatusFilter,
  query: string,
  afterId: number,
): Promise<{
  links: Link[];
  subtreeMode: boolean;
  isRoot: boolean;
  nextAfterId: number;
}> {
  const status = filter === "all" ? undefined : filter;

  // Search mode: the search op caps at 50 hits and has no cursor, so there is
  // no pagination here. Status is applied client-side over the hit set.
  if (query.length >= 2) {
    const res = await client.search(query, {
      scope: "links",
      limit: PAGE_SIZE,
    });
    return {
      links: res.links.filter((l) => !status || l.status === status),
      subtreeMode: false,
      isRoot: false,
      nextAfterId: 0,
    };
  }

  if (categoryId <= 0) {
    const { links, nextAfterId } = await client.listAllLinks({
      limit: PAGE_SIZE,
      status,
      afterId,
    });
    return {
      links,
      subtreeMode: false,
      isRoot: false,
      nextAfterId,
    };
  }

  const cat = await client.getCategory(categoryId).catch(() => null);
  const isRoot = cat ? cat.parentId === 0 : false;

  const direct = await client.listLinks(categoryId, {
    limit: PAGE_SIZE,
    status,
    afterId,
  });
  if (direct.links.length > 0) {
    return {
      links: direct.links,
      subtreeMode: false,
      isRoot,
      nextAfterId: direct.nextAfterId,
    };
  }

  // Fallback: branch categories with no direct links surface descendants'
  // rows for moderation.
  try {
    const sub = await client.listSubtreeLinks(categoryId, {
      limit: PAGE_SIZE,
      status,
      afterId,
    });
    if (sub.links.length > 0) {
      return {
        links: sub.links,
        subtreeMode: true,
        isRoot,
        nextAfterId: sub.nextAfterId,
      };
    }
  } catch {
    // fall through to empty
  }

  return {
    links: [],
    subtreeMode: false,
    isRoot,
    nextAfterId: 0,
  };
}

async function applyAction(
  form: FormData,
  action: string,
  client: ReturnType<typeof getClient>,
): Promise<string> {
  const id = Number(formField(form, "id"));
  switch (action) {
    case "update": {
      const updates: Record<string, string> = {};
      const title = formField(form, "title");
      const urlVal = formField(form, "url");
      if (title) updates.title = title;
      if (urlVal) updates.url = urlVal;
      updates.description = formField(form, "description");
      await client.updateLink(id, updates);
      return "Link updated";
    }
    case "delete":
      await client.deleteLink(id);
      return "Link deleted";
    case "approve":
      await client.updateLinkStatus(id, "approved");
      return "Link approved";
    case "reject":
      await client.updateLinkStatus(id, "rejected");
      return "Link rejected";
    default:
      return "";
  }
}

function buildRedirect(
  baseUrl: string,
  categoryId: number,
  message: string,
): Response {
  const base = categoryId
    ? `/admin/links?category=${categoryId}`
    : "/admin/links";
  const sep = categoryId ? "&" : "?";
  const target = `${base}${
    message ? `${sep}msg=${encodeURIComponent(message)}` : ""
  }`;
  return Response.redirect(new URL(target, baseUrl), 303);
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "Links · Admin";
    const url = ctx.url;
    const categoryId = Number(url.searchParams.get("category") || "0");
    const statusFilter = parseStatusFilter(url.searchParams.get("status"));
    const query = (url.searchParams.get("q") ?? "").trim();
    const afterId = Number(url.searchParams.get("after_id") || "0");
    const cursorStack = url.searchParams.get("cursors") ?? "";
    const message = url.searchParams.get("msg") || undefined;

    const client = getClient();
    const [loadResult, counts, adminCtx] = await Promise.all([
      loadLinks(client, categoryId, statusFilter, query, afterId)
        .catch((e) => {
          console.error("loadLinks failed:", e);
          return null;
        }),
      client.countsByStatus().catch(() => ({
        pending: 0,
        approved: 0,
        rejected: 0,
      })),
      loadAdminContext(),
    ]);

    const links = loadResult?.links ?? [];
    // Resolve Category-column names/paths once per page (batched ancestor walk).
    const categoryInfo = await loadCategoryInfo(client, links).catch((e) => {
      console.error("loadCategoryInfo failed:", e);
      return {} as Record<number, CategoryInfo>;
    });

    return page({
      links,
      selectedCategoryId: categoryId,
      statusFilter,
      query,
      cursorStack,
      nextAfterId: loadResult?.nextAfterId ?? 0,
      counts,
      categoryInfo,
      baseUrl: url.href,
      message,
      subtreeMode: loadResult?.subtreeMode ?? false,
      isRoot: loadResult?.isRoot ?? false,
      adminCtx,
    });
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const action = formField(form, "_action");
    const categoryId = Number(formField(form, "categoryId") || "0");
    let message = "";
    try {
      message = await applyAction(form, action, getClient());
    } catch (e) {
      message = `Error: ${e instanceof Error ? e.message : String(e)}`;
    }
    return buildRedirect(ctx.req.url, categoryId, message);
  },
});

export default define.page<typeof handler>(function AdminLinks(props) {
  const {
    links,
    selectedCategoryId,
    statusFilter,
    query,
    cursorStack,
    nextAfterId,
    counts,
    categoryInfo,
    baseUrl,
    message,
    subtreeMode,
    isRoot,
    adminCtx,
  } = props.data;
  const url = new URL(baseUrl);
  const totalAll = counts.pending + counts.approved + counts.rejected;
  const pageNum = cursorStack.split(",").filter(Boolean).length + 1;

  return (
    <AdminShell
      active="links"
      title="Links."
      crumbs={[
        { label: "Directory", href: "/" },
        { label: "Admin", href: "/admin" },
        { label: "Links" },
      ]}
      tabCounts={adminCtx.tabCounts}
      tabsTrailing={<AdminStatusChip healthy={adminCtx.healthy} />}
    >
      <Banner message={message} />

      {statusFilter === "pending" && (
        <AdminHintBanner
          id="links_bulk_intro"
          message="Tip: use the checkboxes to bulk-approve or bulk-reject pending links. Type into search to filter further."
        />
      )}

      <AdminSearchBar
        placeholder="Search by title, URL, description, category name…"
        initialQuery={query}
        rightSlot={isRoot ? null : (
          <a
            class="btn"
            href={selectedCategoryId
              ? `/admin/links/new?category=${selectedCategoryId}`
              : "/admin/links/new"}
          >
            + New link
          </a>
        )}
      />

      <AdminFilterChips
        groups={[
          {
            label: "Status",
            param: "status",
            active: statusFilter,
            baseUrl: url,
            options: [
              { label: "All", value: "all", count: totalAll },
              {
                label: "Pending",
                value: "pending",
                count: counts.pending,
                dot: "●",
              },
              { label: "Approved", value: "approved", count: counts.approved },
              { label: "Rejected", value: "rejected", count: counts.rejected },
            ],
          },
        ]}
      />

      <AdminBulkBar entity="links">
        {subtreeMode && (
          <Banner
            variant="info"
            message={`No direct links here — showing ${links.length} from the whole subtree.`}
          />
        )}
        {isRoot && (
          <Banner
            variant="info"
            message="This is a root category — links can only live in subcategories."
          />
        )}
        <AdminTable
          columns={["", "Title", "Host", "Category", "Status", "Actions"]}
          emptyMessage="No links match your filter."
        >
          {links.map((link) => (
            <LinkRow
              key={link.id}
              link={link}
              selectedCategoryId={selectedCategoryId}
              categoryName={categoryInfo[link.categoryId]?.name}
              categoryPath={categoryInfo[link.categoryId]?.path}
            />
          ))}
        </AdminTable>
        <AdminPaginator
          baseUrl={url}
          pageSize={PAGE_SIZE}
          pageNum={pageNum}
          nextAfterId={nextAfterId}
          itemsOnPage={links.length}
        />
      </AdminBulkBar>
    </AdminShell>
  );
});
