import type { DmozClient } from "./dmoz-client.ts";
import { storeLinkVector } from "./embedder.ts";
import { storeLinkEntities } from "./entities.ts";

export async function enrichLink(
  client: DmozClient,
  linkId: number,
): Promise<void> {
  await Promise.all([
    storeLinkVector(client, linkId),
    storeLinkEntities(client, linkId),
  ]);
}
