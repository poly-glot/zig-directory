/**
 * Fluent query builder on top of `getClient()`.
 *
 * The flat client methods are still available — this layer just gives a
 * single shape to the four list ops that share a "predicate + filter +
 * page" structure:
 *
 *   await client.links.by({ category: 4 }).where({ status: "pending" }).page({ limit: 50 });
 *   await client.links.by({ submitter: userId }).where({ status: "approved" }).page();
 *   await client.links.by({ none: true }).where({ status: "pending" }).page();
 *   await client.links.subtree(catId).where({ status: "pending" }).page();
 *
 * The builder picks the right underlying client method based on which
 * `.by()` discriminator was chosen, so callers don't need to remember
 * "is it listLinks or listMySubmissions or listAllLinks?" — the
 * predicate tells you.
 */

import { type DmozClient, getClient, type LinkPage } from "./dmoz-client.ts";
import type { Link, LinkStatus } from "./dmoz-protocol.gen.ts";

interface PageArgs {
  offset?: number;
  limit?: number;
  /** Cursor: resume immediately after this link id (ignores `offset`). */
  afterId?: number;
}

interface Filter {
  status?: LinkStatus;
}

/** Per-category links via `link_by_category` (op=13). */
class CategoryQuery {
  constructor(
    private readonly client: DmozClient,
    private readonly categoryId: number,
    private readonly filter: Filter,
  ) {}
  where(f: Filter): CategoryQuery {
    return new CategoryQuery(this.client, this.categoryId, {
      ...this.filter,
      ...f,
    });
  }
  page(args: PageArgs = {}): Promise<LinkPage> {
    return this.client.listLinks(this.categoryId, {
      offset: args.offset,
      limit: args.limit,
      afterId: args.afterId,
      status: this.filter.status,
    });
  }
}

/** Per-submitter links via `link_by_submitter` (op=27). */
class SubmitterQuery {
  constructor(
    private readonly client: DmozClient,
    private readonly submitterId: number,
    private readonly filter: Filter,
  ) {}
  where(f: Filter): SubmitterQuery {
    return new SubmitterQuery(this.client, this.submitterId, {
      ...this.filter,
      ...f,
    });
  }
  page(args: PageArgs = {}): Promise<LinkPage> {
    return this.client.listMySubmissions(this.submitterId, {
      offset: args.offset,
      limit: args.limit,
      afterId: args.afterId,
      status: this.filter.status,
    });
  }
}

/** Whole-DB links via `links_by_id` (op=16). */
class AllQuery {
  constructor(
    private readonly client: DmozClient,
    private readonly filter: Filter,
  ) {}
  where(f: Filter): AllQuery {
    return new AllQuery(this.client, { ...this.filter, ...f });
  }
  page(args: PageArgs = {}): Promise<LinkPage> {
    return this.client.listAllLinks({
      offset: args.offset,
      limit: args.limit,
      afterId: args.afterId,
      status: this.filter.status,
    });
  }
}

/** Subtree links via `listSubtreeLinks` (op=17). Returns `{ links, total, nextAfterId }`. */
class SubtreeQuery {
  constructor(
    private readonly client: DmozClient,
    private readonly rootCategoryId: number,
    private readonly filter: Filter,
  ) {}
  where(f: Filter): SubtreeQuery {
    return new SubtreeQuery(this.client, this.rootCategoryId, {
      ...this.filter,
      ...f,
    });
  }
  page(
    args: PageArgs = {},
  ): Promise<{ links: Link[]; total: number; nextAfterId: number }> {
    return this.client.listSubtreeLinks(this.rootCategoryId, {
      offset: args.offset,
      limit: args.limit,
      afterId: args.afterId,
      status: this.filter.status,
    });
  }
}

type ByDiscriminator =
  | { category: number; submitter?: never; none?: never }
  | { submitter: number; category?: never; none?: never }
  | { none: true; category?: never; submitter?: never };

/** Entry point for link queries. Picks the right secondary index. */
class LinksApi {
  constructor(private readonly client: DmozClient) {}

  by(d: ByDiscriminator): CategoryQuery | SubmitterQuery | AllQuery {
    if (d.category !== undefined) {
      return new CategoryQuery(this.client, d.category, {});
    }
    if (d.submitter !== undefined) {
      return new SubmitterQuery(this.client, d.submitter, {});
    }
    return new AllQuery(this.client, {});
  }

  subtree(rootCategoryId: number): SubtreeQuery {
    return new SubtreeQuery(this.client, rootCategoryId, {});
  }
}

/** Fluent wrapper. Pass a DmozClient (defaults to the shared one). */
export function fluent(client: DmozClient = getClient()): { links: LinksApi } {
  return { links: new LinksApi(client) };
}
