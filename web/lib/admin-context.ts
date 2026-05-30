import { getClient } from "./dmoz-client.ts";
import { getUserCount } from "./kv-users.ts";
import type { TabCounts } from "../components/admin/AdminTabs/AdminTabs.tsx";

export interface AdminContext {
  tabCounts: TabCounts;
  healthy: boolean;
}

export async function loadAdminContext(): Promise<AdminContext> {
  const [statsResult, countResult] = await Promise.allSettled([
    getClient().stats(),
    getUserCount(),
  ]);
  const stats = statsResult.status === "fulfilled" ? statsResult.value : null;
  const userCount = countResult.status === "fulfilled" ? countResult.value : 0;
  return {
    tabCounts: {
      categories: stats?.categoryCount,
      links: stats?.linkCount,
      users: userCount,
    },
    healthy: statsResult.status === "fulfilled",
  };
}
