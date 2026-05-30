import styles from "./TagChipRow.module.css";

interface Chip {
  tag: string;
  count: number;
  href: string;
  active: boolean;
}

interface Props {
  chips: Chip[];
  clearHref: string;
  hasActiveTag: boolean;
}

export default function TagChipRow(
  { chips, clearHref, hasActiveTag }: Props,
) {
  if (chips.length === 0 && !hasActiveTag) return null;
  return (
    <div class={styles.row}>
      <span class={styles.label}>Tags</span>
      {hasActiveTag
        ? <a class={styles.chip} href={clearHref}>Clear ×</a>
        : null}
      {chips.map((c) => (
        <a
          key={c.tag}
          class={c.active ? `${styles.chip} ${styles.solid}` : styles.chip}
          href={c.href}
        >
          {c.tag} <span class={styles.count}>{c.count}</span>
        </a>
      ))}
    </div>
  );
}
