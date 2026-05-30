import styles from "../ListRow/ListRow.module.css";
import { formatCategoryName } from "../../../lib/format.ts";

interface Props {
  num: string;
  href: string;
  name: string;
  childrenPreview?: string[];
  count?: number;
}

const ARROW_GLYPH = (
  <svg
    width="10"
    height="8"
    viewBox="0 0 10 8"
    fill="none"
    stroke="currentColor"
    stroke-width="1.5"
    aria-hidden="true"
  >
    <path d="M1 4h8M6 1l3 3-3 3" />
  </svg>
);

export default function CategoryRow(
  { num, href, name, childrenPreview, count }: Props,
) {
  const previewText = childrenPreview && childrenPreview.length > 0
    ? childrenPreview.slice(0, 5).join(" · ")
    : null;
  return (
    <li class={`${styles.row} list-row`} data-kind="category">
      <div class={`${styles.num} num`}>{num}</div>
      <div>
        <a href={href}>
          <span class={`${styles.title} ttl`}>{formatCategoryName(name)}</span>
        </a>
        {previewText
          ? <div class={`${styles.meta} meta`}>{previewText}</div>
          : null}
      </div>
      <div class={`${styles.right} right`}>
        {typeof count === "number"
          ? (
            <span class={`${styles.count} small`}>
              {count.toLocaleString()} links
            </span>
          )
          : null}
        <a class={styles.browseLink} href={href}>
          <span>Browse</span>
          {ARROW_GLYPH}
        </a>
      </div>
    </li>
  );
}
