import type { User } from "../../../lib/kv-users.ts";
import { formatMonthYear } from "../../../lib/format.ts";
import styles from "./AccountForm.module.css";

interface Props {
  user: User;
  saveSuccess?: string;
  saveError?: string;
}

function ReadOnlyRow({ label, value }: { label: string; value: string }) {
  return (
    <div class={styles.row}>
      <span class="label">{label}</span>
      <span>{value}</span>
    </div>
  );
}

export default function AccountForm({ user, saveSuccess, saveError }: Props) {
  return (
    <div class={styles.card}>
      {saveSuccess ? <div class="banner success">{saveSuccess}</div> : null}
      {saveError ? <div class="banner error">{saveError}</div> : null}
      <form method="POST" class={styles.form}>
        <ReadOnlyRow label="Email" value={user.email} />
        <ReadOnlyRow label="Username" value={user.username} />
        <ReadOnlyRow label="Role" value={user.role} />
        <ReadOnlyRow
          label="Member since"
          value={formatMonthYear(user.createdAt)}
        />
        <div class={styles.row}>
          <span class="label">Display name</span>
          <input
            class="input"
            name="displayName"
            required
            value={user.displayName ?? user.username}
          />
        </div>
        <div class={styles.row}>
          <span class="label">Bio</span>
          <textarea class="textarea" name="bio" rows={4}>
            {user.bio ?? ""}
          </textarea>
        </div>
        <div class="row mt-16">
          <button class="btn" type="submit">Save changes →</button>
        </div>
      </form>
    </div>
  );
}
