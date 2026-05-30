import type { Category } from "../../../lib/dmoz-client.ts";
import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import CategoryRow from "../../common/CategoryRow/CategoryRow.tsx";
import { pad2 } from "../../../lib/format.ts";

interface Props {
  items: Category[];
  currentPath: string;
}

export default function SubcategoriesList({ items, currentPath }: Props) {
  return (
    <section class="section">
      <div class="container">
        <SectionHead
          num="01"
          topic="Subcategories"
          title="Browse by subcategory."
        />
        <ul class="list list-bleed-borders mt-32">
          {items.map((child, i) => (
            <CategoryRow
              key={child.id}
              num={pad2(i + 1)}
              href={`/category/${currentPath}/${child.slug || child.id}`}
              name={child.name}
              count={child.linkCountSubtree ?? 0}
            />
          ))}
        </ul>
      </div>
    </section>
  );
}
