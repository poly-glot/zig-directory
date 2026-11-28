import { assertEquals } from "jsr:@std/assert@^1";
import { canViewLink } from "./link-access.ts";
import type { Link, LinkStatus } from "./dmoz-protocol.gen.ts";
import type { User, UserRole } from "./kv-users.ts";
import { parseEntityId, userIdToSubmitterId } from "./utils.ts";

const SUBMITTER = "11111111-1111-4111-8111-111111111111";

function linkWith(status: LinkStatus): Link {
  return { status, submitterId: userIdToSubmitterId(SUBMITTER) } as Link;
}

function viewer(id: string, role: UserRole): User {
  return { id, role } as User;
}

Deno.test("approved links are public, pending and rejected ones are not", () => {
  assertEquals(canViewLink(linkWith("approved"), null), true);
  assertEquals(canViewLink(linkWith("pending"), null), false);
  assertEquals(canViewLink(linkWith("rejected"), null), false);
  assertEquals(canViewLink(linkWith("unknown"), null), false);
});

Deno.test("a stranger signed in as a plain user cannot see a non-approved link", () => {
  const stranger = viewer("22222222-2222-4222-8222-222222222222", "user");

  assertEquals(canViewLink(linkWith("pending"), stranger), false);
});

Deno.test("the submitter, an editor and an admin can see a non-approved link", () => {
  const link = linkWith("rejected");

  assertEquals(canViewLink(link, viewer(SUBMITTER, "user")), true);
  assertEquals(canViewLink(link, viewer("other", "editor")), true);
  assertEquals(canViewLink(link, viewer("other", "admin")), true);
});

Deno.test("entity ids are plain positive integers and nothing else", () => {
  assertEquals(parseEntityId("16"), 16);
  for (const raw of ["1.5", "1e3", "0x10", "0", "-1", "", " 7", "7 ", "007"]) {
    assertEquals(parseEntityId(raw), undefined, raw);
  }
});
