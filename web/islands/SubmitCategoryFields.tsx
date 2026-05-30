import { useSignal } from "@preact/signals";
import type { JSX } from "preact";
import styles from "./SubmitCategoryFields.module.css";

interface CategoryOption {
  id: number;
  name: string;
}

interface Props {
  topCategories: CategoryOption[];
  initialCategoryId: number;
  initialSubcategoryId: number;
  initialSubCategories: CategoryOption[];
}

export default function SubmitCategoryFields({
  topCategories,
  initialCategoryId,
  initialSubcategoryId,
  initialSubCategories,
}: Props) {
  const subs = useSignal<CategoryOption[]>(initialSubCategories);
  const subId = useSignal<number>(initialSubcategoryId);
  const loading = useSignal<boolean>(false);
  const error = useSignal<string>("");

  const onTopChange = async (e: JSX.TargetedEvent<HTMLSelectElement>) => {
    const parentId = parseInt(e.currentTarget.value, 10) || 0;
    subId.value = 0;
    if (parentId <= 0) {
      subs.value = [];
      error.value = "";
      return;
    }
    loading.value = true;
    error.value = "";
    try {
      const resp = await fetch(
        `/api/category-children?parentId=${encodeURIComponent(parentId)}`,
      );
      const data = await resp.json();
      subs.value = data.children ?? [];
    } catch {
      subs.value = [];
      error.value = "Could not load subcategories.";
    } finally {
      loading.value = false;
    }
  };

  const hasSubs = subs.value.length > 0;
  const subDisabled = loading.value || !hasSubs;

  return (
    <>
      <div class="field">
        <label for="categoryId">Top-level category</label>
        <select
          class="select"
          id="categoryId"
          name="categoryId"
          required
          onChange={onTopChange}
        >
          <option value="0" selected={initialCategoryId <= 0}>
            — Select a category —
          </option>
          {topCategories.map((c) => (
            <option
              value={String(c.id)}
              selected={c.id === initialCategoryId}
              key={c.id}
            >
              {c.name}
            </option>
          ))}
        </select>
      </div>

      <div class="field">
        <label for="subcategoryId">
          Subcategory <span class={styles.optional}>(optional)</span>
        </label>
        <select
          class="select"
          id="subcategoryId"
          name="subcategoryId"
          disabled={subDisabled}
        >
          <option value="0">
            {loading.value
              ? "Loading…"
              : hasSubs
              ? "— None (submit at top level) —"
              : "— No subcategories available —"}
          </option>
          {subs.value.map((c) => (
            <option
              value={String(c.id)}
              selected={c.id === subId.value}
              key={c.id}
            >
              {c.name}
            </option>
          ))}
        </select>
        {error.value
          ? <span class="err">{error.value}</span>
          : (
            <span class="hint">
              Subcategories load automatically when a category is chosen.
            </span>
          )}
      </div>
    </>
  );
}
