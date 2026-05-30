import { pad2 } from "../../../lib/format.ts";
import styles from "./TabStrip.module.css";

export type Tab = "all" | "pending" | "approved" | "rejected" | "account";

export interface Stats {
  total: number;
  approved: number;
  pending: number;
  rejected: number;
}

const TABS: { id: Tab; label: string }[] = [
  { id: "all", label: "All" },
  { id: "pending", label: "Pending" },
  { id: "approved", label: "Approved" },
  { id: "rejected", label: "Rejected" },
  { id: "account", label: "Account" },
];

interface Props {
  active: Tab;
  stats: Stats;
}

function countFor(id: Tab, stats: Stats): number | null {
  if (id === "all") return stats.total;
  if (id === "pending") return stats.pending;
  if (id === "approved") return stats.approved;
  if (id === "rejected") return stats.rejected;
  return null;
}

export default function TabStrip({ active, stats }: Props) {
  return (
    <nav class={styles.tabs} aria-label="Dashboard tabs">
      {TABS.map((t) => {
        const count = countFor(t.id, stats);
        return (
          <a
            key={t.id}
            href={`/dashboard?tab=${t.id}`}
            class={t.id === active ? styles.active : ""}
          >
            {t.label}
            {count !== null
              ? <span class={styles.count}>({pad2(count)})</span>
              : null}
          </a>
        );
      })}
    </nav>
  );
}
