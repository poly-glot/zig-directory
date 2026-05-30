# Architecture Conventions

## The server owns hierarchy semantics; the client renders

When a feature aggregates across the category tree (all links under Arts, paginated; subtree counts; search within a subtree; breadcrumbs), put the work in **dmozdb** as a single operation over the binary protocol and B+Tree walks. Don't fan out N requests from the Deno route layer and merge them client-side.

- NEVER: **Walk the tree client-side or `Promise.allSettled` over children** to assemble a hierarchical answer. That band-aids the symptom in the route layer. The user's words: *"I am seeing lazy/hacky way of fixing things where we are just adding code to solve the problem but do not understand the intent — e.g. Arts should naturally return all the links (paginated of course) in all the subcategories without the client needing to figure out to query their descendants."*
- DO: **Add a server op** for hierarchical queries: `list_subtree_links(cat_id, after_id, limit)`, `subtree_stats(cat_id)`, `search_within_subtree(cat_id, query, limit)`, `breadcrumb(cat_id)`. One call per page.
- DO: **Use true cursor or offset pagination.** Never sample N from each of the first M children.
- DO: **Write dual indexes atomically on the server.** Update `links_by_id` and `link_by_category` together inside the server's mutex, not from the client.

## Smallest change first; no abstraction without migration

- DO: **State the minimal fix.** After naming a root cause, name the smallest change that makes the bug impossible, and justify any machinery beyond it against the current data scale rather than hypothetical load. A missing `delete()` is fixed by adding the `delete()`, not by a background worker plus a new index plus a migration.
- DO: **No abstraction without migration.** When you extract a shared primitive, the same change deletes every copy it replaces. A primitive adopted in one of seven call sites is dead weight stacked on the debt it was meant to remove.
