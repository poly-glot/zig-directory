import type { Link } from "../../../lib/dmoz-client.ts";
import LinkCard from "../../common/LinkCard/LinkCard.tsx";
import { truncate } from "../../../lib/format.ts";
import { highlight } from "../../../routes/search/_lib/highlight.tsx";
import { siteSearchHref } from "../../../routes/search/_lib/targets.ts";
import styles from "./ResultArticle.module.css";

const DESC_LIMIT = 240;

interface Props {
  link: Link;
  tokens: string[];
  moreFromSite?: number;
  site?: string;
}

function MoreFromSite({ count, site }: { count: number; site: string }) {
  const href = siteSearchHref(site);
  return (
    <p class={styles.more}>
      {count} more from {href ? <a class="under" href={href}>{site}</a> : site}
    </p>
  );
}

export default function ResultArticle(
  { link, tokens, moreFromSite = 0, site = "" }: Props,
) {
  const desc = truncate(link.description ?? "", DESC_LIMIT);
  const folded = moreFromSite > 0
    ? <MoreFromSite count={moreFromSite} site={site} />
    : undefined;
  return (
    <LinkCard
      href={`/link/${link.id}`}
      title={highlight(link.title, tokens)}
      url={link.url}
      description={desc ? highlight(desc, tokens) : undefined}
      monoSeed={String(link.id)}
      footer={folded}
    />
  );
}
