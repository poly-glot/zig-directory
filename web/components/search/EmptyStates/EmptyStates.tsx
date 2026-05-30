import styles from "../../common/ListRow/ListRow.module.css";

export function EmptyPrompt() {
  return (
    <div class={styles.row} data-kind="empty">
      <div class={styles.num}>—</div>
      <div>
        <span class={styles.title}>Start typing to search</span>
        <p class={`${styles.meta} mt-8`}>
          AND-of-tokens, ID-ordered. Try one of these queries:
        </p>
        <div class="row mt-16 gap-8 flex-wrap">
          <a class="chip" href="/search?q=archive">archive</a>
          <a class="chip" href="/search?q=open+data">open data</a>
          <a class="chip" href="/search?q=encyclopedia">encyclopedia</a>
        </div>
      </div>
      <div class={styles.right} />
    </div>
  );
}

export function NoResults({ query }: { query: string }) {
  return (
    <div class={styles.row} data-kind="empty">
      <div class={styles.num}>00</div>
      <div>
        <span class={styles.title}>No results for "{query}"</span>
        <p class={`${styles.meta} mt-8`}>
          Try a broader keyword, or <a href="/">browse the directory</a>.
        </p>
      </div>
      <div class={styles.right} />
    </div>
  );
}
