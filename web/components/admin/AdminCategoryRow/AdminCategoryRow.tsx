import type { Category } from "../../../lib/dmoz-client.ts";
import { truncateText } from "../../../lib/utils.ts";
import ConfirmForm from "../../../islands/ConfirmForm.tsx";
import RowActions from "../RowActions/RowActions.tsx";

interface Props {
  cat: Category;
  parentId: number;
  /** Render the bulk-select checkbox cell (default true). */
  selectable?: boolean;
}

export default function CategoryRow(
  { cat, parentId, selectable = true }: Props,
) {
  // Bulk-delete is zero-descendants only: a category with links or children
  // can't be selected (the server would reject it anyway).
  const hasDescendants = (cat.childCount ?? 0) > 0 || (cat.linkCount ?? 0) > 0;
  return (
    <tr key={cat.id}>
      {selectable && (
        <td>
          <input
            type="checkbox"
            data-bulk-id={cat.id}
            disabled={hasDescendants}
            title={hasDescendants
              ? "Has descendants — empty before bulk-deleting"
              : undefined}
            aria-label={`Select category ${cat.name}`}
          />
        </td>
      )}
      <td>
        <strong>{cat.name}</strong>
        {cat.description
          ? (
            <div class="micro sublabel">
              {truncateText(cat.description, 80)}
            </div>
          )
          : null}
      </td>
      <td>
        <code>{cat.slug}</code>
      </td>
      <td>
        {(cat.linkCount ?? 0).toLocaleString()} /{" "}
        {(cat.childCount ?? 0).toLocaleString()}
      </td>
      <td>{(cat.linkCountSubtree ?? 0).toLocaleString()}</td>
      <td>
        <RowActions>
          <a href={`/admin/categories?parent=${cat.id}`} class="text-action">
            Open
          </a>
          <a
            href={`/admin/categories/${cat.id}/edit?parent=${parentId}`}
            class="text-action"
          >
            Edit
          </a>
          <ConfirmForm message="Delete this category? This cannot be undone.">
            <input type="hidden" name="_action" value="delete" />
            <input type="hidden" name="id" value={String(cat.id)} />
            <input type="hidden" name="parentId" value={String(parentId)} />
            <button type="submit" class="text-action danger">Delete</button>
          </ConfirmForm>
        </RowActions>
      </td>
    </tr>
  );
}
