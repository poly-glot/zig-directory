import styles from "./AdminPaginator.module.css";

interface Props {
  /** Current page URL (typically ctx.url). Used to merge cursor params. */
  baseUrl: URL;
  /** Page size (used to compute the "Showing X–Y" label). */
  pageSize: number;
  /** 1-indexed page number derived from the cursor stack length. */
  pageNum: number;
  /** Server-supplied: id to put in `after_id` for the next page. 0 = no more. */
  nextAfterId: number;
  /** Number of items actually on this page (for the X–Y label). */
  itemsOnPage: number;
}

/**
 * Cursor-driven Prev/Next paginator (pure SSR, no JS). The `cursors` URL
 * param is a comma-separated stack of the after_id used for each page;
 * Next pushes the server's next_after_id, Prev pops the stack.
 */
export default function AdminPaginator(
  { baseUrl, pageSize, pageNum, nextAfterId, itemsOnPage }: Props,
) {
  const start = (pageNum - 1) * pageSize + 1;
  const end = start + itemsOnPage - 1;

  const cursors = (baseUrl.searchParams.get("cursors") ?? "").split(",").filter(
    Boolean,
  );

  // Prev: pop the last cursor.
  const prevUrl = new URL(baseUrl);
  if (cursors.length > 0) {
    const popped = cursors.slice(0, -1);
    if (popped.length === 0) {
      prevUrl.searchParams.delete("cursors");
      prevUrl.searchParams.delete("after_id");
    } else {
      prevUrl.searchParams.set("cursors", popped.join(","));
      prevUrl.searchParams.set("after_id", popped[popped.length - 1]);
    }
  }

  // Next: push next_after_id.
  const nextUrl = new URL(baseUrl);
  if (nextAfterId > 0) {
    const newStack = [...cursors, String(nextAfterId)];
    nextUrl.searchParams.set("cursors", newStack.join(","));
    nextUrl.searchParams.set("after_id", String(nextAfterId));
  }

  const prevDisabled = cursors.length === 0;
  const nextDisabled = nextAfterId === 0;
  return (
    <nav class={`${styles.bar} admin-paginator`} aria-label="Pagination">
      <span class={styles.range}>
        Showing {itemsOnPage > 0 ? `${start}–${end}` : "0"}
      </span>
      <span class={styles.spacer} />
      <a
        href={prevUrl.toString()}
        class={`btn small ghost ${prevDisabled ? styles.disabled : ""}`}
        aria-disabled={prevDisabled}
      >
        ‹ Prev
      </a>
      <a
        href={nextUrl.toString()}
        class={`btn small ${nextDisabled ? `ghost ${styles.disabled}` : ""}`}
        aria-disabled={nextDisabled}
      >
        Next ›
      </a>
    </nav>
  );
}
