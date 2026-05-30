import type { Link } from "../../../lib/dmoz-client.ts";
import LinkCard from "../../common/LinkCard/LinkCard.tsx";
import { truncate } from "../../../lib/format.ts";
import { highlight } from "../../../routes/search/_lib/highlight.tsx";

const DESC_LIMIT = 240;

interface Props {
  link: Link;
  tokens: string[];
}

export default function ResultArticle({ link, tokens }: Props) {
  const desc = truncate(link.description ?? "", DESC_LIMIT);
  return (
    <LinkCard
      href={`/link/${link.id}`}
      title={highlight(link.title, tokens)}
      url={link.url}
      description={desc ? highlight(desc, tokens) : undefined}
      monoSeed={String(link.id)}
    />
  );
}
