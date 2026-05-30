import Hostname from "../Hostname/Hostname.tsx";
import styles from "../ListRow/ListRow.module.css";

interface Props {
  num: string;
  href: string;
  title: string;
  url?: string;
  description?: string;
  crumb?: string;
  added?: string;
}

function MetaLine(
  { url, crumb }: { url?: string; crumb?: string },
) {
  if (url) {
    return (
      <div class={styles.meta}>
        <Hostname url={url} />
        {crumb ? <>· {crumb}</> : null}
      </div>
    );
  }
  if (crumb) return <div class={styles.meta}>{crumb}</div>;
  return null;
}

export default function LinkRow(
  { num, href, title, url, description, crumb, added }: Props,
) {
  return (
    <li class={`${styles.row} list-row`} data-kind="link">
      <div class={`${styles.num} num`}>{num}</div>
      <div>
        <a href={href}>
          <span class={`${styles.title} ttl`}>{title}</span>
        </a>
        <MetaLine url={url} crumb={crumb} />
        {description
          ? <p class={`${styles.meta} meta mt-8`}>{description}</p>
          : null}
      </div>
      <div class={`${styles.right} right`}>
        {added ? <span class="small">{added}</span> : null}
      </div>
    </li>
  );
}
