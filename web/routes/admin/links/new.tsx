import { page } from "fresh";
import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";
import { isHttpUrl } from "../../../lib/url.ts";
import { formField } from "../../../lib/utils.ts";
import CreatePageShell from "../../../components/admin/CreatePageShell/CreatePageShell.tsx";
import CategoryPicker from "../../../islands/CategoryPicker.tsx";
import {
  ErrorBanner,
  FieldError,
} from "../../../components/submit/Banners/Banners.tsx";

interface Values {
  categoryId: number;
  categoryLabel: string;
  url: string;
  title: string;
  description: string;
}

interface Data {
  values: Values;
  errors: Record<string, string>;
}

const EMPTY: Values = {
  categoryId: 0,
  categoryLabel: "",
  url: "",
  title: "",
  description: "",
};

/** Resolve "Name (#id)" for the CategoryPicker's initial label, or "" if the
 * id is unset/unknown. */
async function categoryLabel(
  client: ReturnType<typeof getClient>,
  id: number,
): Promise<string> {
  if (id <= 0) return "";
  const cat = await client.getCategory(id).catch(() => null);
  return cat ? `${cat.name} (#${cat.id})` : "";
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "New link · Admin";
    const categoryId = Number(ctx.url.searchParams.get("category") || "0");
    const label = await categoryLabel(getClient(), categoryId);
    return page({
      values: { ...EMPTY, categoryId, categoryLabel: label },
      errors: {},
    });
  },

  async POST(ctx) {
    ctx.state.title = "New link · Admin";
    const form = await ctx.req.formData();
    const client = getClient();
    const values: Values = {
      categoryId: Number(formField(form, "categoryId")),
      categoryLabel: "",
      url: formField(form, "url"),
      title: formField(form, "title"),
      description: formField(form, "description"),
    };
    // Re-resolve the label so the picker stays populated if we re-render.
    values.categoryLabel = await categoryLabel(client, values.categoryId);

    const errors: Record<string, string> = {};
    if (!values.categoryId) {
      errors.categoryId = "Pick a category.";
    } else {
      const cat = await client.getCategory(values.categoryId).catch(() => null);
      if (cat && cat.parentId === 0) {
        errors.categoryId =
          "Links can't live in a root category — pick a subcategory.";
      }
    }
    if (!values.url) {
      errors.url = "URL is required.";
    } else if (!isHttpUrl(values.url)) {
      errors.url = "Enter a valid http:// or https:// URL.";
    }
    if (!values.title) errors.title = "Title is required.";

    if (Object.keys(errors).length > 0) {
      return page({ values, errors });
    }

    try {
      await client.createLink(
        values.categoryId,
        values.url,
        values.title,
        values.description,
      );
    } catch (e) {
      return page({
        values,
        errors: {
          general: `Could not create link: ${
            e instanceof Error ? e.message : String(e)
          }`,
        },
      });
    }

    return Response.redirect(
      new URL(
        `/admin/links?category=${values.categoryId}&msg=${
          encodeURIComponent("Link created successfully")
        }`,
        ctx.req.url,
      ),
      303,
    );
  },
});

export default define.page<typeof handler>(function NewLink(props) {
  const { values, errors } = props.data;
  const backHref = values.categoryId
    ? `/admin/links?category=${values.categoryId}`
    : "/admin/links";

  return (
    <CreatePageShell
      here="New link"
      eyebrow="Add a listing"
      title="Create link."
      lede="Add a link to the directory. Admin-created links go live immediately — no moderation queue."
    >
      <form method="POST" class="form-grid">
        <ErrorBanner message={errors.general} />
        <div class="field">
          <label for="new-link-category">Category</label>
          <CategoryPicker
            name="categoryId"
            inputId="new-link-category"
            initialId={values.categoryId}
            initialLabel={values.categoryLabel}
            required
          />
          <span class="hint">
            Pick a subcategory — links can't live in a root category.
          </span>
          <FieldError message={errors.categoryId} />
        </div>
        <div class="field">
          <label for="new-link-url">URL</label>
          <input
            class="input"
            id="new-link-url"
            name="url"
            type="url"
            required
            placeholder="https://example.com"
            value={values.url}
          />
          <FieldError message={errors.url} />
        </div>
        <div class="field">
          <label for="new-link-title">Title</label>
          <input
            class="input"
            id="new-link-title"
            name="title"
            type="text"
            required
            placeholder="The name as it appears on the site"
            value={values.title}
          />
          <FieldError message={errors.title} />
        </div>
        <div class="field">
          <label for="new-link-description">Description</label>
          <textarea
            class="textarea"
            id="new-link-description"
            name="description"
            rows={4}
          >
            {values.description}
          </textarea>
        </div>
        <div class="row between mt-16">
          <a class="btn ghost" href={backHref}>← Cancel</a>
          <button class="btn" type="submit">Create link</button>
        </div>
      </form>
    </CreatePageShell>
  );
});
