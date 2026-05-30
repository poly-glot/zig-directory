import type { Category } from "../../../lib/dmoz-client.ts";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import { formatCategoryName, pad2 } from "../../../lib/format.ts";
import styles from "./CatHero.module.css";

interface Props {
  category: Category;
  ancestors: Category[];
  childrenCount: number;
}

function MetaRow({ label, value }: { label: string; value: string }) {
  return (
    <div class={styles.metaRow}>
      <span class="label">{label}</span>
      <span class="value">{value}</span>
    </div>
  );
}

export default function CatHero({ category, ancestors, childrenCount }: Props) {
  const sectionLabel = `SEC. ${pad2(ancestors.length + 1)}`;
  const displayName = formatCategoryName(category.name);
  return (
    <section class={`${styles.hero} cat-hero`}>
      <div>
        <Eyebrow muted label={`${sectionLabel} — ${displayName}`} />
        <h1 class="display mt-16">{displayName}</h1>
        {category.description
          ? <p class="lede mt-24">{category.description}</p>
          : null}
      </div>
      <div class={styles.metaStack}>
        <MetaRow label="Subcategories" value={String(childrenCount)} />
        <MetaRow
          label="Indexed links"
          value={category.linkCountSubtree.toLocaleString()}
        />
        <MetaRow
          label="Direct links"
          value={category.linkCount.toLocaleString()}
        />
        <MetaRow
          label="Total subtree"
          value={category.childCountSubtree.toLocaleString()}
        />
      </div>
    </section>
  );
}
