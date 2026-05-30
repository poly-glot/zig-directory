import type { ComponentChildren } from "preact";
import styles from "./AdminTabs.module.css";

export type AdminTab =
  | "dashboard"
  | "categories"
  | "links"
  | "users"
  | "integrity";

export type TabCounts = Partial<Record<AdminTab, number>>;

const TABS: { id: AdminTab; label: string; href: string }[] = [
  { id: "dashboard", label: "Dashboard", href: "/admin" },
  { id: "categories", label: "Categories", href: "/admin/categories" },
  { id: "links", label: "Links", href: "/admin/links" },
  { id: "users", label: "Users", href: "/admin/users" },
  { id: "integrity", label: "Integrity", href: "/admin/integrity" },
];

interface Props {
  active: AdminTab;
  counts?: TabCounts;
  trailing?: ComponentChildren;
}

export default function AdminTabs({ active, counts, trailing }: Props) {
  return (
    <nav class={`${styles.bar} admin-tabs`} aria-label="Admin sections">
      <div class={styles.inner}>
        {TABS.map((t) => {
          const n = counts?.[t.id];
          return (
            <a
              key={t.id}
              href={t.href}
              class={`${styles.tab} ${active === t.id ? styles.active : ""}`}
              aria-current={active === t.id ? "page" : undefined}
            >
              {t.label}
              {typeof n === "number"
                ? (
                  <span class={styles.count}>
                    ({n.toLocaleString()})
                  </span>
                )
                : null}
            </a>
          );
        })}
        {trailing ? <span class={styles.trailing}>{trailing}</span> : null}
      </div>
    </nav>
  );
}
