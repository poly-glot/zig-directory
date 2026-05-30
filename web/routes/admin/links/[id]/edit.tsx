import { page } from "fresh";
import { define } from "../../../../utils.ts";
import {
  getClient,
  type Link,
  type LinkStatus,
} from "../../../../lib/dmoz-client.ts";
import { formField } from "../../../../lib/utils.ts";
import AdminShell from "../../../../components/admin/AdminShell/AdminShell.tsx";
import AdminStatusChip from "../../../../components/admin/AdminStatusChip/AdminStatusChip.tsx";
import EditForm from "../../../../components/admin/EditForm/EditForm.tsx";
import Field from "../../../../components/admin/Field/Field.tsx";
import CategoryPicker from "../../../../islands/CategoryPicker.tsx";
import {
  type AdminContext,
  loadAdminContext,
} from "../../../../lib/admin-context.ts";

interface SelectedCategoryInfo {
  id: number;
  name: string;
  slug: string;
}

interface Data {
  link: Link;
  category: SelectedCategoryInfo | null;
  message?: string;
  adminCtx: AdminContext;
}

function parseStatus(raw: string): LinkStatus | null {
  if (raw === "pending" || raw === "approved" || raw === "rejected") return raw;
  return null;
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const id = Number(ctx.params.id);
    if (!Number.isFinite(id) || id <= 0) {
      return new Response("Not found", { status: 404 });
    }
    const client = getClient();
    let link: Link;
    try {
      link = await client.getLink(id);
    } catch {
      return new Response("Not found", { status: 404 });
    }
    const cat = await client.getCategory(link.categoryId).catch(() => null);
    const adminCtx = await loadAdminContext();
    ctx.state.title = `Edit: ${link.title} · Admin`;
    return page({
      link,
      category: cat ? { id: cat.id, name: cat.name, slug: cat.slug } : null,
      message: ctx.url.searchParams.get("msg") ?? undefined,
      adminCtx,
    });
  },

  async POST(ctx) {
    const id = Number(ctx.params.id);
    const form = await ctx.req.formData();
    const action = formField(form, "_action");
    const client = getClient();
    let message = "";
    try {
      switch (action) {
        case "update": {
          const link = await client.getLink(id);

          // Validate up front so we don't half-write on a malformed submit.
          const newStatus = parseStatus(formField(form, "status"));
          if (!newStatus) {
            message = "Error: Invalid status value.";
            break;
          }
          const newCategoryId = Number(formField(form, "categoryId"));
          if (!newCategoryId) {
            message = "Error: Pick a category.";
            break;
          }
          if (newCategoryId !== link.categoryId) {
            const targetCat = await client.getCategory(newCategoryId);
            if (targetCat.parentId === 0) {
              message =
                "Error: Cannot move a link into a root category. Pick a subcategory.";
              break;
            }
          }

          // All validation passed — now write.
          await client.updateLink(id, {
            title: formField(form, "title"),
            url: formField(form, "url"),
            description: formField(form, "description"),
          });
          if (newStatus !== link.status) {
            await client.updateLinkStatus(id, newStatus);
          }
          if (newCategoryId !== link.categoryId) {
            await client.moveLink(id, newCategoryId);
          }

          message = "Link updated";
          break;
        }
        case "delete":
          await client.deleteLink(id);
          return Response.redirect(
            new URL("/admin/links?msg=Link%20deleted", ctx.req.url),
            303,
          );
        default:
          message = "Error: unknown action";
      }
    } catch (e) {
      message = `Error: ${e instanceof Error ? e.message : String(e)}`;
    }
    return Response.redirect(
      new URL(
        `/admin/links/${id}/edit?msg=${encodeURIComponent(message)}`,
        ctx.req.url,
      ),
      303,
    );
  },
});

export default define.page<typeof handler>(function EditLink(props) {
  const { link, category, message, adminCtx } = props.data;
  const initialLabel = category
    ? `${category.name} (#${category.id})`
    : `#${link.categoryId}`;
  return (
    <AdminShell
      active="links"
      title="Edit link."
      crumbs={[
        { label: "Directory", href: "/" },
        { label: "Admin", href: "/admin" },
        {
          label: "Links",
          href: `/admin/links?category=${link.categoryId}`,
        },
        { label: `#${link.id}` },
      ]}
      tabCounts={adminCtx.tabCounts}
      tabsTrailing={<AdminStatusChip healthy={adminCtx.healthy} />}
    >
      <EditForm
        message={message}
        cancelHref={`/admin/links?category=${link.categoryId}`}
        hidden={[["_action", "update"]]}
        deleteAction={{
          message: "Delete this link? This cannot be undone.",
          hidden: [["_action", "delete"]],
          label: "Delete link",
        }}
      >
        <Field label="Title" htmlFor="edit-title">
          <input
            id="edit-title"
            class="input"
            type="text"
            name="title"
            value={link.title}
            required
          />
        </Field>
        <Field label="URL" htmlFor="edit-url">
          <input
            id="edit-url"
            class="input"
            type="url"
            name="url"
            value={link.url}
            required
          />
        </Field>
        <Field label="Category">
          <CategoryPicker
            name="categoryId"
            inputId="edit-category"
            initialId={link.categoryId}
            initialLabel={initialLabel}
            required
          />
        </Field>
        <Field label="Status" htmlFor="edit-status">
          <select
            id="edit-status"
            class="select"
            name="status"
            required
          >
            <option value="pending" selected={link.status === "pending"}>
              Pending
            </option>
            <option value="approved" selected={link.status === "approved"}>
              Approved
            </option>
            <option value="rejected" selected={link.status === "rejected"}>
              Rejected
            </option>
          </select>
        </Field>
        <Field label="Description" htmlFor="edit-description">
          <textarea
            id="edit-description"
            class="textarea"
            name="description"
            rows={4}
          >
            {link.description ?? ""}
          </textarea>
        </Field>
      </EditForm>
    </AdminShell>
  );
});
