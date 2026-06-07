import { page } from "fresh";
import { define } from "../../utils.ts";
import { type Category, getClient } from "../../lib/dmoz-client.ts";
import AdminShell from "../../components/admin/AdminShell/AdminShell.tsx";
import AdminStatusChip from "../../components/admin/AdminStatusChip/AdminStatusChip.tsx";
import Banner from "../../components/admin/Banner/Banner.tsx";
import AdminTable from "../../components/admin/AdminTable/AdminTable.tsx";
import Breadcrumb from "../../components/admin/Breadcrumb/Breadcrumb.tsx";
import {
  type AdminContext,
  loadAdminContext,
} from "../../lib/admin-context.ts";
import { formField } from "../../lib/utils.ts";
import { CANONICAL_ROOT_ID } from "../../lib/admin-constants.ts";
import CategoryRow from "../../components/admin/AdminCategoryRow/AdminCategoryRow.tsx";
import AdminSearchBar from "../../islands/AdminSearchBar.tsx";
import AdminBulkBar from "../../islands/AdminBulkBar.tsx";

interface Crumb {
  id: number;
  name: string;
}

interface Data {
  categories: Category[];
  parentCategory: Category | null;
  parentId: number;
  query: string;
  breadcrumb: Crumb[];
  message?: string;
  adminCtx: AdminContext;
}

async function loadView(
  client: ReturnType<typeof getClient>,
  parentId: number,
): Promise<{ categories: Category[]; parentCategory: Category | null }> {
  if (parentId === 0) {
    const categories = await client.listChildren(CANONICAL_ROOT_ID, 0, 100);
    return { categories, parentCategory: null };
  }
  const [categories, parentCategory] = await Promise.all([
    client.listChildren(parentId, 0, 100),
    client.getCategory(parentId),
  ]);
  return { categories, parentCategory };
}

async function loadBreadcrumb(
  client: ReturnType<typeof getClient>,
  parentId: number,
): Promise<Crumb[]> {
  if (parentId === 0) return [];
  const chains = await client.breadcrumbsByIds([parentId]);
  return (chains.get(parentId) ?? []).map((c) => ({ id: c.id, name: c.name }));
}

async function applyAction(
  form: FormData,
  action: string,
  client: ReturnType<typeof getClient>,
): Promise<string> {
  switch (action) {
    case "update": {
      const id = Number(formField(form, "id"));
      const updates: Record<string, string> = {};
      const name = formField(form, "name");
      const slug = formField(form, "slug");
      if (name) updates.name = name;
      if (slug) updates.slug = slug;
      updates.description = formField(form, "description");
      await client.updateCategory(id, updates);
      return "Category updated";
    }
    case "delete":
      await client.deleteCategory(Number(formField(form, "id")));
      return "Category deleted";
    default:
      return "";
  }
}

function buildRedirect(
  baseUrl: string,
  parentId: number,
  message: string,
): Response {
  const base = parentId
    ? `/admin/categories?parent=${parentId}`
    : "/admin/categories";
  const sep = parentId ? "&" : "?";
  const target = `${base}${
    message ? `${sep}msg=${encodeURIComponent(message)}` : ""
  }`;
  return Response.redirect(new URL(target, baseUrl), 303);
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "Categories · Admin";
    const url = ctx.url;
    const parentId = Number(url.searchParams.get("parent") || "0");
    const query = (url.searchParams.get("q") ?? "").trim();
    const message = url.searchParams.get("msg") || undefined;
    const client = getClient();

    let categories: Category[] = [];
    let parentCategory: Category | null = null;
    let breadcrumb: Crumb[] = [];

    try {
      if (query.length >= 2) {
        const res = await client.search(query, {
          scope: "categories",
          limit: 50,
        });
        categories = res.categories;
      } else {
        const loaded = await loadView(client, parentId);
        categories = loaded.categories;
        parentCategory = loaded.parentCategory;
        breadcrumb = await loadBreadcrumb(client, parentId);
      }
    } catch (e) {
      console.error("Failed to load categories:", e);
    }

    const adminCtx = await loadAdminContext();
    return page({
      categories,
      parentCategory,
      parentId,
      query,
      breadcrumb,
      message,
      adminCtx,
    });
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const action = formField(form, "_action");
    const parentId = Number(formField(form, "parentId") || "0");
    let message = "";
    try {
      message = await applyAction(form, action, getClient());
    } catch (e) {
      message = `Error: ${e instanceof Error ? e.message : String(e)}`;
    }
    return buildRedirect(ctx.req.url, parentId, message);
  },
});

export default define.page<typeof handler>(function AdminCategories(props) {
  const {
    categories,
    parentCategory,
    parentId,
    query,
    breadcrumb,
    message,
    adminCtx,
  } = props.data;

  const searching = query.length >= 2;

  // Top › … › current. The last crumb (the level being viewed) is inert;
  // ancestors link to their level. "Top" links home unless already at top.
  const crumbs = [
    { label: "Top", href: parentId === 0 ? undefined : "/admin/categories" },
    ...breadcrumb.map((b, i) => ({
      label: b.name,
      href: i < breadcrumb.length - 1
        ? `/admin/categories?parent=${b.id}`
        : undefined,
    })),
  ];

  return (
    <AdminShell
      active="categories"
      title="Categories."
      crumbs={[
        { label: "Directory", href: "/" },
        { label: "Admin", href: "/admin" },
        { label: "Categories" },
      ]}
      tabCounts={adminCtx.tabCounts}
      tabsTrailing={<AdminStatusChip healthy={adminCtx.healthy} />}
    >
      <Banner message={message} />

      <AdminSearchBar
        placeholder="Search by name, slug, description…"
        initialQuery={query}
        rightSlot={
          <a
            class="btn"
            href={parentId
              ? `/admin/categories/new?parent=${parentId}`
              : "/admin/categories/new"}
          >
            + New category
          </a>
        }
      />

      {!searching && <Breadcrumb crumbs={crumbs} />}

      <AdminBulkBar entity="categories">
        <AdminTable
          columns={[
            "",
            "Name",
            "Slug",
            "Direct (links / children)",
            "Subtree links",
            "Actions",
          ]}
          columnTooltips={{
            3: "Links directly in this category / its immediate subcategories",
            4: "Links in this category plus all descendants",
          }}
          emptyMessage={searching
            ? "No categories match your search."
            : (parentCategory
              ? `${parentCategory.name} has no subcategories. Add one with + New category.`
              : "No categories yet. Create your first with + New category.")}
        >
          {categories.map((cat) => (
            <CategoryRow key={cat.id} cat={cat} parentId={parentId} />
          ))}
        </AdminTable>
      </AdminBulkBar>
    </AdminShell>
  );
});
