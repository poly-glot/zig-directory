import type { Link } from "../../../lib/dmoz-client.ts";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import LinkCard from "../../common/LinkCard/LinkCard.tsx";
import { formatLongDateOrDash } from "../../../lib/format.ts";

interface Props {
  links: Link[];
}

export default function Adjacent({ links }: Props) {
  if (links.length === 0) return null;
  return (
    <section class="section gray">
      <div class="container">
        <Eyebrow muted label="Adjacent in this subcategory" />
        <div class="cards mt-32">
          {links.map((l) => (
            <LinkCard
              key={l.id}
              href={`/link/${l.id}`}
              title={l.title}
              url={l.url}
              description={l.description}
              added={formatLongDateOrDash(l.createdAt)}
            />
          ))}
        </div>
      </div>
    </section>
  );
}
