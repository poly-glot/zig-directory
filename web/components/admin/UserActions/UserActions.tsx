import type { User, UserRole } from "../../../lib/kv-users.ts";
import ConfirmForm from "../../../islands/ConfirmForm.tsx";
import RowActions from "../RowActions/RowActions.tsx";

interface Props {
  u: User;
  currentUser: User;
}

const ROLE_CYCLE: Record<UserRole, UserRole> = {
  user: "editor",
  editor: "admin",
  admin: "user",
};

export function nextRoleLabel(current: UserRole): string {
  const next = ROLE_CYCLE[current];
  return next === "user" ? "Reset to user" : `Promote → ${next}`;
}

export default function UserActions({ u, currentUser }: Props) {
  if (u.id === currentUser.id) {
    return <span class="muted">—</span>;
  }
  return (
    <RowActions>
      <form method="POST" class="inline-form">
        <input type="hidden" name="_action" value="toggle_role" />
        <input type="hidden" name="userId" value={u.id} />
        <button
          type="submit"
          class="text-action"
          title="Cycle role: user → editor → admin → user"
        >
          {nextRoleLabel(u.role)}
        </button>
      </form>
      <ConfirmForm message="Delete this user? This cannot be undone.">
        <input type="hidden" name="_action" value="delete" />
        <input type="hidden" name="userId" value={u.id} />
        <button type="submit" class="text-action danger">Delete</button>
      </ConfirmForm>
    </RowActions>
  );
}
