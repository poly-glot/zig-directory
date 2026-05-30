import { page } from "fresh";
import { define } from "../../utils.ts";
import {
  deleteUser,
  getKv,
  listUsers,
  type User,
  type UserRole,
} from "../../lib/kv-users.ts";
import AdminShell from "../../components/admin/AdminShell/AdminShell.tsx";
import AdminStatusChip from "../../components/admin/AdminStatusChip/AdminStatusChip.tsx";
import Banner from "../../components/admin/Banner/Banner.tsx";
import AdminTable from "../../components/admin/AdminTable/AdminTable.tsx";
import {
  type AdminContext,
  loadAdminContext,
} from "../../lib/admin-context.ts";
import { formField, pluralize } from "../../lib/utils.ts";
import UserRow from "../../components/admin/UserRow/UserRow.tsx";

const ROLE_CYCLE: Record<UserRole, UserRole> = {
  user: "editor",
  editor: "admin",
  admin: "user",
};

interface Data {
  users: User[];
  currentUser: User;
  message?: string;
  adminCtx: AdminContext;
}

async function toggleRole(
  userId: string,
  currentUserId: string,
): Promise<string> {
  if (userId === currentUserId) return "Error: You cannot change your own role";
  const kv = await getKv();
  const entry = await kv.get<User>(["users", userId]);
  if (!entry.value) return "Error: User not found";
  const newRole = ROLE_CYCLE[entry.value.role];
  const result = await kv
    .atomic()
    .check(entry)
    .set(["users", userId], {
      ...entry.value,
      role: newRole,
      updatedAt: new Date().toISOString(),
    })
    .commit();
  return result.ok
    ? `User "${entry.value.username}" role changed to ${newRole}`
    : "Error: Failed to update role (concurrent modification)";
}

async function applyAction(
  form: FormData,
  action: string,
  currentUserId: string,
): Promise<string> {
  const userId = formField(form, "userId");
  if (action === "toggle_role") return toggleRole(userId, currentUserId);
  if (action === "delete") {
    if (userId === currentUserId) {
      return "Error: You cannot delete your own account";
    }
    const success = await deleteUser(userId);
    return success ? "User deleted successfully" : "Error: User not found";
  }
  return "";
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "Users · Admin";
    const message = ctx.url.searchParams.get("msg") || undefined;
    let users: User[] = [];
    try {
      users = await listUsers();
    } catch (e) {
      console.error("Failed to list users:", e);
    }
    const adminCtx = await loadAdminContext();
    return page({
      users,
      currentUser: ctx.state.user as User,
      message,
      adminCtx,
    });
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const action = formField(form, "_action");
    const currentUser = ctx.state.user as User;
    let message = "";
    try {
      message = await applyAction(form, action, currentUser.id);
    } catch (e) {
      message = `Error: ${e instanceof Error ? e.message : String(e)}`;
    }
    const target = `/admin/users${
      message ? `?msg=${encodeURIComponent(message)}` : ""
    }`;
    return Response.redirect(new URL(target, ctx.req.url), 303);
  },
});

export default define.page<typeof handler>(function AdminUsers(props) {
  const { users, currentUser, message, adminCtx } = props.data;
  return (
    <AdminShell
      active="users"
      title="Users."
      crumbs={[
        { label: "Directory", href: "/" },
        { label: "Admin", href: "/admin" },
        { label: "Users" },
      ]}
      tabCounts={adminCtx.tabCounts}
      tabsTrailing={<AdminStatusChip healthy={adminCtx.healthy} />}
    >
      <p class="lede mt-16">
        {pluralize(users.length, "registered user")}. Toggle roles or remove
        accounts.
      </p>

      <Banner message={message} />

      <AdminTable
        columns={["Email", "Username", "Role", "Created", "Actions"]}
        emptyMessage="No users yet."
      >
        {users.map((u) => (
          <UserRow
            key={u.id}
            u={u}
            currentUser={currentUser}
          />
        ))}
      </AdminTable>
    </AdminShell>
  );
});
