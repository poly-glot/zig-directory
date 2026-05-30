import type { Link } from "../../../lib/dmoz-client.ts";
import Hostname from "../../common/Hostname/Hostname.tsx";
import { truncateText } from "../../../lib/utils.ts";
import RowActions from "../RowActions/RowActions.tsx";
import StatusBadge from "../StatusBadge/StatusBadge.tsx";
import ConfirmForm from "../../../islands/ConfirmForm.tsx";

interface Props {
  link: Link;
  selectedCategoryId: number;
  /** Render the bulk-select checkbox cell (default true). */
  selectable?: boolean;
  /** Leaf category name for the Category cell (resolved by the page). */
  categoryName?: string;
  /** Full "Top / … / leaf" path, shown as the Category cell's tooltip. */
  categoryPath?: string;
}

export default function LinkRow(
  {
    link,
    selectedCategoryId,
    selectable = true,
    categoryName,
    categoryPath,
  }: Props,
) {
  const categoryForForm = selectedCategoryId > 0
    ? selectedCategoryId
    : link.categoryId;
  return (
    <tr key={link.id}>
      {selectable && (
        <td>
          <input
            type="checkbox"
            data-bulk-id={link.id}
            aria-label={`Select link ${link.title}`}
          />
        </td>
      )}
      <td>
        <a href={`/admin/links/${link.id}/edit`}>
          <strong>{truncateText(link.title, 60)}</strong>
        </a>
      </td>
      <td>
        <Hostname url={link.url} />
      </td>
      <td>
        {categoryName
          ? (
            <a
              href={`/admin/links?category=${link.categoryId}`}
              title={categoryPath ?? categoryName}
              class="text-action"
            >
              {categoryName}
            </a>
          )
          : <span class="muted">—</span>}
      </td>
      <td>
        <StatusBadge
          id={link.id}
          status={link.status}
          selectedCategoryId={categoryForForm}
        />
      </td>
      <td>
        <RowActions>
          <a href={`/admin/links/${link.id}/edit`} class="text-action">Edit</a>
          <ConfirmForm message="Delete this link?">
            <input type="hidden" name="_action" value="delete" />
            <input type="hidden" name="id" value={String(link.id)} />
            <input
              type="hidden"
              name="categoryId"
              value={String(categoryForForm)}
            />
            <button type="submit" class="text-action danger">Delete</button>
          </ConfirmForm>
        </RowActions>
      </td>
    </tr>
  );
}
