import { page } from "fresh";
import { define } from "../../utils.ts";
import { getClient, type Link } from "../../lib/dmoz-client.ts";
import { fluent } from "../../lib/dmoz-fluent.ts";
import { updateUser, type User } from "../../lib/kv-users.ts";
import { formField, userIdToSubmitterId } from "../../lib/utils.ts";
import Crumbs from "../../components/common/Crumbs/Crumbs.tsx";
import HeaderRow from "../../components/dashboard/HeaderRow/HeaderRow.tsx";
import TabStrip, {
  type Stats,
  type Tab,
} from "../../components/dashboard/TabStrip/TabStrip.tsx";
import SubmissionsList from "../../components/dashboard/SubmissionsList/SubmissionsList.tsx";
import AccountForm from "../../components/dashboard/AccountForm/AccountForm.tsx";
import EditorRolePanel from "../../components/dashboard/EditorRolePanel/EditorRolePanel.tsx";

interface Data {
  user: User;
  tab: Tab;
  links: Link[];
  stats: Stats;
  saveSuccess?: string;
  saveError?: string;
}

function parseTab(raw: string | null): Tab {
  if (raw === "pending" || raw === "approved" || raw === "rejected") return raw;
  if (raw === "account") return "account";
  return "all";
}

function loginRedirect(req: Request): Response {
  const url = new URL(req.url);
  const target = url.pathname + url.search;
  const dest = `/auth/login?redirect=${encodeURIComponent(target)}`;
  return new Response(null, { status: 303, headers: { Location: dest } });
}

interface Submissions {
  pending: Link[];
  approved: Link[];
  rejected: Link[];
}

function computeStats(s: Submissions): Stats {
  return {
    pending: s.pending.length,
    approved: s.approved.length,
    rejected: s.rejected.length,
    total: s.pending.length + s.approved.length + s.rejected.length,
  };
}

function linksForTab(s: Submissions, tab: Tab): Link[] {
  if (tab === "pending") return s.pending;
  if (tab === "approved") return s.approved;
  if (tab === "rejected") return s.rejected;
  // "all" / "account" share the same listing — most recent first.
  const all = [...s.pending, ...s.approved, ...s.rejected];
  all.sort((a, b) => b.id - a.id);
  return all;
}

async function loadSubmissions(user: User): Promise<Submissions> {
  // Three parallel per-status calls so per-tab counts and listings are
  // accurate up to 100/status (vs. the old 100-total ceiling that
  // silently under-counted heavy submitters).
  const submitter = userIdToSubmitterId(user.id);
  const links = fluent(getClient()).links;
  const by = links.by({ submitter });
  try {
    const [pending, approved, rejected] = await Promise.all([
      by.where({ status: "pending" }).page(),
      by.where({ status: "approved" }).page(),
      by.where({ status: "rejected" }).page(),
    ]);
    return {
      pending: pending.links,
      approved: approved.links,
      rejected: rejected.links,
    };
  } catch (e) {
    console.error("dashboard: failed to load submissions:", e);
    return { pending: [], approved: [], rejected: [] };
  }
}

async function applyAccountUpdate(
  user: User,
  form: FormData,
): Promise<{ user: User; saveSuccess?: string; saveError?: string }> {
  const displayName = formField(form, "displayName");
  const bio = formField(form, "bio");
  if (!displayName) return { user, saveError: "Display name is required." };
  try {
    const updated = await updateUser(user.id, { displayName, bio });
    if (!updated) return { user, saveError: "Could not update account." };
    return { user: updated, saveSuccess: "Account updated." };
  } catch (e) {
    console.error("dashboard: update user failed:", e);
    return { user, saveError: "An error occurred." };
  }
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const user = ctx.state.user;
    if (!user) return loginRedirect(ctx.req);
    ctx.state.title = "Dashboard";
    const tab = parseTab(ctx.url.searchParams.get("tab"));
    const all = await loadSubmissions(user);
    const stats = computeStats(all);
    const links = linksForTab(all, tab);
    return page({ user, tab, links, stats });
  },

  async POST(ctx) {
    const user = ctx.state.user;
    if (!user) return loginRedirect(ctx.req);
    const form = await ctx.req.formData();
    const all = await loadSubmissions(user);
    const stats = computeStats(all);
    const links = linksForTab(all, "account");
    const result = await applyAccountUpdate(user, form);
    return page({ ...result, tab: "account", links, stats });
  },
});

function AccountTab(
  { user, saveSuccess, saveError }: {
    user: User;
    saveSuccess?: string;
    saveError?: string;
  },
) {
  return (
    <>
      <AccountForm
        user={user}
        saveSuccess={saveSuccess}
        saveError={saveError}
      />
      <EditorRolePanel user={user} />
    </>
  );
}

export default define.page<typeof handler>(function DashboardPage(props) {
  const { user, tab, links, saveSuccess, saveError, stats } = props.data;
  return (
    <div class="container">
      <Crumbs crumbs={[]} title="Dashboard" />
      <HeaderRow user={user} />
      <TabStrip active={tab} stats={stats} />
      {tab === "account"
        ? (
          <AccountTab
            user={user}
            saveSuccess={saveSuccess}
            saveError={saveError}
          />
        )
        : <SubmissionsList tab={tab} links={links} />}
    </div>
  );
});
