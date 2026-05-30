import type { Link } from "../../../lib/dmoz-client.ts";
import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import LinkCard from "../../common/LinkCard/LinkCard.tsx";
import { formatLongDate } from "../../../lib/format.ts";
import CategoryToolbar, {
  type Sort,
  type TagChip,
} from "../CategoryToolbar/CategoryToolbar.tsx";
import Pagination from "../Pagination/Pagination.tsx";

const PAGE_SIZE = 50;

export interface LinkWithCategory extends Link {
  categoryName: string;
  categoryLinkCountSubtree: number;
}

interface Props {
  pageLinks: LinkWithCategory[];
  page: number;
  pageTotal: number;
  totalPages: number;
  currentPath: string;
  hasSubcategories: boolean;
  sort: Sort;
  activeTag: string;
  tagChips: TagChip[];
  clearTagHref: string;
  rawCount: number;
}

function ledeText(page: number, count: number, total: number): string {
  const startIdx = (page - 1) * PAGE_SIZE + 1;
  const endIdx = (page - 1) * PAGE_SIZE + count;
  return `Showing ${startIdx.toLocaleString()}–${endIdx.toLocaleString()} of ${total.toLocaleString()} editor-approved links.`;
}

function ListingItem({ link }: { link: LinkWithCategory }) {
  return (
    <LinkCard
      key={link.id}
      href={`/link/${link.id}`}
      title={link.title}
      url={link.url}
      description={link.description}
      crumb={link.categoryName}
      added={formatLongDate(link.createdAt)}
      monoSeed={String(link.id)}
    />
  );
}

function EmptyTagFilter({ clearTagHref }: { clearTagHref: string }) {
  return (
    <div class="banner mt-32">
      No links match the active tag filter.{" "}
      <a href={clearTagHref} class="under">Clear filter</a>.
    </div>
  );
}

export default function ListingsSection(props: Props) {
  const {
    pageLinks,
    page,
    pageTotal,
    totalPages,
    currentPath,
    hasSubcategories,
    sort,
    activeTag,
    tagChips,
    clearTagHref,
    rawCount,
  } = props;
  return (
    <section class="section gray">
      <div class="container">
        <SectionHead
          num={hasSubcategories ? "02" : "01"}
          topic="Listings"
          title="All links in this category."
          lede={ledeText(page, pageLinks.length, pageTotal)}
        />
        <CategoryToolbar
          currentPath={currentPath}
          page={page}
          sort={sort}
          activeTag={activeTag}
          tagChips={tagChips}
          clearTagHref={clearTagHref}
          rawCount={rawCount}
          filteredCount={pageLinks.length}
        />
        {pageLinks.length === 0
          ? <EmptyTagFilter clearTagHref={clearTagHref} />
          : (
            <div class="cards fluid mt-32">
              {pageLinks.map((link) => (
                <ListingItem
                  key={link.id}
                  link={link}
                />
              ))}
            </div>
          )}
        <Pagination path={currentPath} page={page} totalPages={totalPages} />
      </div>
    </section>
  );
}
