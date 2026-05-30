import { page } from "fresh";
import { define } from "../../../../utils.ts";
import { type Category, getClient } from "../../../../lib/dmoz-client.ts";
import { formField } from "../../../../lib/utils.ts";
import AdminShell from "../../../../components/admin/AdminShell/AdminShell.tsx";
import AdminStatusChip from "../../../../components/admin/AdminStatusChip/AdminStatusChip.tsx";
import EditForm from "../../../../components/admin/EditForm/EditForm.tsx";
import Field from "../../../../components/admin/Field/Field.tsx";
import {
  type AdminContext,
  loadAdminContext,
} from "../../../../lib/admin-context.ts";

interface Data {
  category: Category;
  parentId: number;
  message?: string;
  adminCtx: AdminContext;
}

function backHref(parentId: number): string {
  return parentId
    ? `/admin/categories?parent=${parentId}`
    : "/admin/categories";
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const id = Number(ctx.params.id);
    if (!Number.isFinite(id) || id <= 0) {
      return new Response("Not found", { status: 404 });
    }
    const parentId = Number(ctx.url.searchParams.get("parent") || "0");
    const message = ctx.url.searchParams.get("msg") ?? undefined;
    let category: Category;
    try {
      category = await getClient().getCategory(id);
    } catch {
      return new Response("Not found", { status: 404 });
    }
    const adminCtx = await loadAdminContext();
    ctx.state.title = `Edit: ${category.name} · Admin`;
    return page({ category, parentId, message, adminCtx });
  },

  async POST(ctx) {
    const id = Number(ctx.params.id);
    const form = await ctx.req.formData();
    const action = formField(form, "_action");
    const parentId = Number(formField(form, "parentId") || "0");
    let message = "";
    try {
      if (action === "update") {
        const updates: Record<string, string> = {};
        const name = formField(form, "name");
        const slug = formField(form, "slug");
        if (name) updates.name = name;
        if (slug) updates.slug = slug;
        updates.description = formField(form, "description");
        await getClient().updateCategory(id, updates);
        message = "Category updated";
      } else if (action === "delete") {
        await getClient().deleteCategory(id);
        return Response.redirect(
          new URL(
            `${backHref(parentId)}${parentId ? "&" : "?"}msg=${
              encodeURIComponent("Category deleted")
            }`,
            ctx.req.url,
          ),
          303,
        );
      } else {
        message = "Error: unknown action";
      }
    } catch (e) {
      message = `Error: ${e instanceof Error ? e.message : String(e)}`;
    }
    return Response.redirect(
      new URL(
        `/admin/categories/${id}/edit?parent=${parentId}&msg=${
          encodeURIComponent(message)
        }`,
        ctx.req.url,
      ),
      303,
    );
  },
});

export default define.page<typeof handler>(function EditCategory(props) {
  const { category, parentId, message, adminCtx } = props.data;
  return (
    <AdminShell
      active="categories"
      title={`Edit ${category.name}.`}
      crumbs={[
        { label: "Directory", href: "/" },
        { label: "Admin", href: "/admin" },
        { label: "Categories", href: backHref(parentId) },
        { label: `#${category.id}` },
      ]}
      tabCounts={adminCtx.tabCounts}
      tabsTrailing={<AdminStatusChip healthy={adminCtx.healthy} />}
    >
      <EditForm
        message={message}
        cancelHref={backHref(parentId)}
        hidden={[["_action", "update"], ["parentId", String(parentId)]]}
        deleteAction={{
          message: "Delete this category? This cannot be undone.",
          hidden: [["_action", "delete"], ["parentId", String(parentId)]],
          label: "Delete category",
        }}
      >
        <Field label="Name" htmlFor="edit-name">
          <input
            id="edit-name"
            class="input"
            type="text"
            name="name"
            value={category.name}
            required
          />
        </Field>
        <Field label="Slug" htmlFor="edit-slug">
          <input
            id="edit-slug"
            class="input"
            type="text"
            name="slug"
            value={category.slug}
            required
          />
        </Field>
        <Field label="Description" htmlFor="edit-description">
          <textarea
            id="edit-description"
            class="textarea"
            name="description"
            rows={4}
          >
            {category.description ?? ""}
          </textarea>
        </Field>
      </EditForm>
    </AdminShell>
  );
});
