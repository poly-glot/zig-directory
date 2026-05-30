import type { User } from "../../../lib/kv-users.ts";
import { formatMonthYear } from "../../../lib/format.ts";
import styles from "../AccountForm/AccountForm.module.css";

interface Props {
  user: User;
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div class={styles.row}>
      <span class="label">{label}</span>
      <span>{value}</span>
    </div>
  );
}

export default function EditorRolePanel({ user }: Props) {
  if (user.role !== "editor" && user.role !== "admin") return null;
  const heading = user.role === "admin" ? "Admin role" : "Editor role";
  const dotClass = user.role === "admin" ? "status-dot" : "status-dot editor";
  return (
    <div class={styles.card}>
      <span class="eyebrow muted">— {heading}</span>
      <div class="hr-strong mt-16 mb-16"></div>
      <div class={styles.row}>
        <span class="label">Role</span>
        <span class={dotClass}>{user.role}</span>
      </div>
      <Row label="Active since" value={formatMonthYear(user.createdAt)} />
      <Row label="Stewardship" value="—" />
      <Row label="Reviews" value="—" />
      <p class="small mt-16">
        Per-category stewardship + review tracking arrive in a later slice.
      </p>
    </div>
  );
}
