import type { ComponentChildren } from "preact";
import styles from "./AdminShell.module.css";
import AdminTabs, {
  type AdminTab,
  type TabCounts,
} from "../AdminTabs/AdminTabs.tsx";
import PageHeader, { type Crumb } from "../PageHeader/PageHeader.tsx";

interface Props {
  active: AdminTab;
  title: string;
  crumbs?: Crumb[];
  tabCounts?: TabCounts;
  tabsTrailing?: ComponentChildren;
  children?: ComponentChildren;
}

export default function AdminShell(
  { active, title, crumbs, tabCounts, tabsTrailing, children }: Props,
) {
  return (
    <div class={`${styles.body} admin-shell`}>
      <PageHeader title={title} crumbs={crumbs} />
      <AdminTabs
        active={active}
        counts={tabCounts}
        trailing={tabsTrailing}
      />
      <div class="container">{children}</div>
    </div>
  );
}
