import { page } from "fresh";
import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";
import { formField, slugify } from "../../../lib/utils.ts";
import CreatePageShell from "../../../components/admin/CreatePageShell/CreatePageShell.tsx";
import {
  ErrorBanner,
  FieldError,
} from "../../../components/submit/Banners/Banners.tsx";

interface Values {
  name: string;
  slug: string;
  description: string;
}

interface Data {
  values: Values;
  errors: Record<string, string>;
  parentId: number;
  parentName: string | null;
}

const EMPTY: Values = { name: "", slug: "", description: "" };

async function parentName(
  client: ReturnType<typeof getClient>,
  parentId: number,
): Promise<string | null> {
  if (parentId <= 0) return null;
  const cat = await client.getCategory(parentId).catch(() => null);
  return cat ? cat.name : null;
}

function lede(parentId: number, name: string | null): string {
  if (parentId > 0 && name) {
    return `A new subcategory under ${name}.`;
  }
  return "A new top-level category in the directory.";
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "New category · Admin";
    const parentId = Number(ctx.url.searchParams.get("parent") || "0");
    const name = await parentName(getClient(), parentId);
    return page({ values: EMPTY, errors: {}, parentId, parentName: name });
  },

  async POST(ctx) {
    ctx.state.title = "New category · Admin";
    const form = await ctx.req.formData();
    const client = getClient();
    const parentId = Number(formField(form, "parentId") || "0");
    const values: Values = {
      name: formField(form, "name"),
      slug: formField(form, "slug"),
      description: formField(form, "description"),
    };

    const errors: Record<string, string> = {};
    if (!values.name) errors.name = "Name is required.";

    const name = await parentName(client, parentId);
    if (Object.keys(errors).length > 0) {
      return page({ values, errors, parentId, parentName: name });
    }

    try {
      await client.createCategory(
        parentId,
        values.name,
        values.slug || slugify(values.name),
        values.description,
      );
    } catch (e) {
      return page({
        values,
        errors: {
          general: `Could not create category: ${
            e instanceof Error ? e.message : String(e)
          }`,
        },
        parentId,
        parentName: name,
      });
    }

    const base = parentId
      ? `/admin/categories?parent=${parentId}`
      : "/admin/categories";
    const sep = parentId ? "&" : "?";
    return Response.redirect(
      new URL(
        `${base}${sep}msg=${
          encodeURIComponent("Category created successfully")
        }`,
        ctx.req.url,
      ),
      303,
    );
  },
});

export default define.page<typeof handler>(function NewCategory(props) {
  const { values, errors, parentId, parentName } = props.data;
  const backHref = parentId
    ? `/admin/categories?parent=${parentId}`
    : "/admin/categories";

  return (
    <CreatePageShell
      here="New category"
      eyebrow="Organise the directory"
      title="Create category."
      lede={lede(parentId, parentName)}
    >
      <form method="POST" class="form-grid">
        <input type="hidden" name="parentId" value={String(parentId)} />
        <ErrorBanner message={errors.general} />
        <div class="field">
          <label for="new-cat-name">Name</label>
          <input
            class="input"
            id="new-cat-name"
            name="name"
            type="text"
            required
            placeholder="Category name"
            value={values.name}
          />
          <FieldError message={errors.name} />
        </div>
        <div class="field">
          <label for="new-cat-slug">Slug</label>
          <input
            class="input"
            id="new-cat-slug"
            name="slug"
            type="text"
            placeholder="category-slug"
            value={values.slug}
          />
          <span class="hint">Auto-generated from the name if left blank.</span>
        </div>
        <div class="field">
          <label for="new-cat-description">Description</label>
          <textarea
            class="textarea"
            id="new-cat-description"
            name="description"
            rows={4}
          >
            {values.description}
          </textarea>
        </div>
        <div class="row between mt-16">
          <a class="btn ghost" href={backHref}>← Cancel</a>
          <button class="btn" type="submit">Create category</button>
        </div>
      </form>
    </CreatePageShell>
  );
});
