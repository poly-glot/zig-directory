import type { LinkStatus } from "../../../lib/dmoz-client.ts";
import styles from "./StatusBadge.module.css";

interface Props {
  id: number;
  status: LinkStatus;
  /** Category to redirect back to after the action (preserves the view). */
  selectedCategoryId: number;
}

function statusClass(s: LinkStatus): string {
  if (s === "approved") return styles.approved;
  if (s === "rejected") return styles.rejected;
  return styles.pending;
}

interface TransitionAction {
  action: "approve" | "reject";
  label: string;
  symbol: string;
}

// Only server-supported transitions. "Re-queue" (→ pending) has no server
// verb yet, so it is intentionally absent (spec open issue).
function transitionsFor(s: LinkStatus): TransitionAction[] {
  if (s === "pending") {
    return [
      { action: "approve", label: "Approve", symbol: "✓" },
      { action: "reject", label: "Reject", symbol: "✗" },
    ];
  }
  if (s === "approved") {
    return [{ action: "reject", label: "Reject", symbol: "✗" }];
  }
  return [{ action: "approve", label: "Approve", symbol: "✓" }];
}

/**
 * Status pill that reveals inline transition buttons on hover / focus
 * (CSS-only, no JS). Each transition is a tiny POST form to the current
 * page handler, which flips the status server-side and redirects back.
 */
export default function StatusBadge({ id, status, selectedCategoryId }: Props) {
  const transitions = transitionsFor(status);
  return (
    <span class={`${styles.wrap} status-badge`} tabIndex={0}>
      <span class={`${styles.badge} ${statusClass(status)}`}>{status}</span>
      <span class={styles.actions}>
        {transitions.map((t) => (
          <form method="POST" class="inline-form" key={t.action}>
            <input type="hidden" name="_action" value={t.action} />
            <input type="hidden" name="id" value={String(id)} />
            <input
              type="hidden"
              name="categoryId"
              value={String(selectedCategoryId)}
            />
            <button type="submit" class={styles.action} title={t.label}>
              {t.symbol} {t.label}
            </button>
          </form>
        ))}
      </span>
    </span>
  );
}
