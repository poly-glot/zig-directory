import type { ComponentChildren } from "preact";
import styles from "./Breadcrumb.module.css";

export interface Crumb {
  label: string;
  href?: string;
}

interface Props {
  crumbs: Crumb[];
  trailing?: ComponentChildren;
}

/**
 * In-body drill-down breadcrumb for /admin/categories. Distinct from
 * PageHeader.crumbs (navigation lineage) — this reflects the position in the
 * category tree the table is currently showing. Each crumb with an href is a
 * link; the last (current) crumb is bold and inert.
 */
export default function Breadcrumb({ crumbs, trailing }: Props) {
  return (
    <nav class={`${styles.bar} admin-breadcrumb`} aria-label="Drill-down">
      {crumbs.map((c, i) => (
        <span key={i}>
          {c.href
            ? <a class={styles.crumb} href={c.href}>{c.label}</a>
            : <span class={styles.current}>{c.label}</span>}
          {i < crumbs.length - 1 && <span class={styles.sep}>›</span>}
        </span>
      ))}
      {trailing && <span class={styles.trailing}>{trailing}</span>}
    </nav>
  );
}
