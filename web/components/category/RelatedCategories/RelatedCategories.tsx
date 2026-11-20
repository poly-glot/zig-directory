import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import CategoryRow from "../../common/CategoryRow/CategoryRow.tsx";
import { pad2 } from "../../../lib/format.ts";

export interface RelatedCategory {
  id: number;
  label: string;
  href: string;
  linkCountSubtree: number;
}

interface Props {
  items: RelatedCategory[];
  num: string;
}

export default function RelatedCategories({ items, num }: Props) {
  return (
    <section class="section" data-related-categories>
      <div class="container">
        <SectionHead
          num={num}
          topic="See also"
          title="Related categories."
        />
        <ul class="list list-bleed-borders mt-32">
          {items.map((item, i) => (
            <CategoryRow
              key={item.id}
              num={pad2(i + 1)}
              href={item.href}
              name={item.label}
              count={item.linkCountSubtree}
            />
          ))}
        </ul>
      </div>
    </section>
  );
}
