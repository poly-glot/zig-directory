import type { Category } from "../../../lib/dmoz-client.ts";
import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import CategoryRow from "../../common/CategoryRow/CategoryRow.tsx";
import { pad2 } from "../../../lib/format.ts";

interface Props {
  categories: Category[];
}

// `lost-and-found` is the canonical bucket for categories whose original
// parent couldn't be resolved (created by Database.bootstrapRootCategories).
// It's a recovery sink, not a user-facing topic — hide it from the index.
const HIDDEN_TOPLEVEL_SLUGS = new Set<string>(["lost-and-found"]);

export default function HomeCategoriesSection({ categories }: Props) {
  const visible = categories.filter((c) => !HIDDEN_TOPLEVEL_SLUGS.has(c.slug));
  return (
    <section class="section gray">
      <div class="container">
        <SectionHead
          num="01"
          topic="The index"
          title={
            <>
              Sixteen categories.<br />One open archive.
            </>
          }
          lede="Every link is reviewed by a human editor before it enters the index. Categories follow the original ODP taxonomy; subcategories are curated by topic stewards."
        />
        {visible.length > 0
          ? (
            <ul class="list list-bleed-borders">
              {visible.map((cat, i) => (
                <CategoryRow
                  key={cat.id}
                  num={pad2(i + 1)}
                  href={`/category/${cat.slug || cat.id}`}
                  name={cat.name}
                  count={cat.linkCountSubtree ?? 0}
                />
              ))}
            </ul>
          )
          : <p class="lede">No categories available right now.</p>}
      </div>
    </section>
  );
}
