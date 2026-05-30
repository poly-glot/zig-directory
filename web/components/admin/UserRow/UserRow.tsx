import type { User, UserRole } from "../../../lib/kv-users.ts";
import UserActions from "../UserActions/UserActions.tsx";

interface Props {
  u: User;
  currentUser: User;
}

function roleDotClass(role: UserRole): string {
  if (role === "admin") return "status-dot";
  if (role === "editor") return "status-dot editor";
  return "status-dot pending";
}

export default function UserRow({ u, currentUser }: Props) {
  return (
    <tr key={u.id}>
      <td>
        {u.email}
        {u.id === currentUser.id
          ? <span class="status-dot ml-8">you</span>
          : null}
      </td>
      <td>
        <strong>{u.username}</strong>
        {u.displayName
          ? (
            <div class="micro sublabel">
              {u.displayName}
            </div>
          )
          : null}
      </td>
      <td>
        <span class={roleDotClass(u.role)}>{u.role}</span>
      </td>
      <td>
        {u.createdAt ? new Date(u.createdAt).toLocaleDateString() : "—"}
      </td>
      <td>
        <UserActions u={u} currentUser={currentUser} />
      </td>
    </tr>
  );
}
