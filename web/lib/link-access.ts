import { type DmozClient, DmozError, Status } from "./dmoz-client.ts";
import type { Link } from "./dmoz-protocol.gen.ts";
import type { User } from "./kv-users.ts";
import { parseEntityId, userIdToSubmitterId } from "./utils.ts";

export function canViewLink(link: Link, viewer: User | null): boolean {
  if (link.status === "approved") return true;
  if (!viewer) return false;
  if (viewer.role === "admin" || viewer.role === "editor") return true;
  return link.submitterId === userIdToSubmitterId(viewer.id);
}

function notFound(): Response {
  return new Response("Not found", { status: 404 });
}

export async function loadVisibleLink(
  client: DmozClient,
  rawId: string,
  viewer: User | null,
): Promise<Link | Response> {
  const id = parseEntityId(rawId);
  if (id === undefined) return notFound();

  try {
    const link = await client.getLink(id);
    return canViewLink(link, viewer) ? link : notFound();
  } catch (e) {
    if (e instanceof DmozError && e.status === Status.NotFound) {
      return notFound();
    }
    throw e;
  }
}
