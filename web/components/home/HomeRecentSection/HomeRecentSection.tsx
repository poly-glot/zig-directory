import type { Link } from "../../../lib/dmoz-client.ts";
import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import LinkCard from "../../common/LinkCard/LinkCard.tsx";
import { formatLongDate } from "../../../lib/format.ts";

export interface LinkWithCategory extends Link {
  categoryName: string;
  categoryLinkCountSubtree: number;
}

interface Props {
  featuredLinks: LinkWithCategory[];
  totalLinks: number;
}

const ARROW = (
  <span class="arrow" aria-hidden="true">
    <svg
      width="10"
      height="8"
      viewBox="0 0 10 8"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
    >
      <path d="M1 4h8M6 1l3 3-3 3" />
    </svg>
  </span>
);

export default function HomeRecentSection(
  { featuredLinks, totalLinks }: Props,
) {
  const featured = featuredLinks.slice(0, 6);
  const totalLabel = totalLinks > 0
    ? `See all ${totalLinks.toLocaleString()} links`
    : "See all links";
  return (
    <section class="section">
      <div class="container">
        <SectionHead
          num="02"
          topic="Recently added"
          title="New to the index."
          lede="A rolling window of the most recent editor-approved submissions. Click through for the full record."
        />
        {featured.length > 0
          ? (
            <div class="cards">
              {featured.map((link) => (
                <LinkCard
                  key={link.id}
                  href={`/link/${link.id}`}
                  title={link.title}
                  url={link.url}
                  description={link.description}
                  crumb={link.categoryName || undefined}
                  added={formatLongDate(link.createdAt)}
                />
              ))}
            </div>
          )
          : <p class="lede">No recent submissions to show.</p>}
        <div class="text-center mt-48">
          <a class="btn ghost" href="/search">
            {totalLabel} {ARROW}
          </a>
        </div>
      </div>
    </section>
  );
}
