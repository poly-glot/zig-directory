import { page } from "fresh";
import { define } from "../../utils.ts";
import {
  type BrowseResult,
  getClient,
  type Link,
} from "../../lib/dmoz-client.ts";
import Crumbs from "../../components/common/Crumbs/Crumbs.tsx";
import { formatCategoryName } from "../../lib/format.ts";
import CatHero from "../../components/category/CatHero/CatHero.tsx";
import SubcategoriesList from "../../components/category/SubcategoriesList/SubcategoriesList.tsx";
import ListingsSection, {
  type LinkWithCategory,
} from "../../components/category/ListingsSection/ListingsSection.tsx";
import EmptyState from "../../components/category/EmptyState/EmptyState.tsx";
import {
  ErrorBanner,
  OffsetCapBanner,
} from "../../components/category/Banners/Banners.tsx";
import styles from "./[...path].module.css";
import {
  buildToolbarHref,
  MAX_PAGES,
  OFFSET_CAP,
  PAGE_SIZE,
  parseSort,
  type Sort,
  type TagChip,
} from "./_lib/queryParams.ts";
import {
  applySort,
  applyTagFilter,
  computeTagChips,
} from "./_lib/listingShape.ts";

interface Data {
  result: BrowseResult | null;
  currentPath: string;
  page: number;
  pageLinks: LinkWithCategory[];
  pageTotal: number;
  offsetCapHit: boolean;
  sort: Sort;
  activeTag: string;
  tagChips: TagChip[];
  clearTagHref: string;
  rawCount: number;
  error?: string;
}

async function annotateLinks(
  client: ReturnType<typeof getClient>,
  links: Link[],
  fallbackName: string,
  fallbackCount: number,
  seedCategoryId?: number,
): Promise<LinkWithCategory[]> {
  const cache = new Map<number, { name: string; linkCountSubtree: number }>();
  // The page's own category — most subtree links share it; pre-populate
  // so the batched fetch only needs to look up cousins.
  if (seedCategoryId !== undefined) {
    cache.set(seedCategoryId, {
      name: fallbackName,
      linkCountSubtree: fallbackCount,
    });
  }
  const uniqueIds = [...new Set(links.map((l) => l.categoryId))]
    .filter((id) => id > 0 && !cache.has(id));
  if (uniqueIds.length > 0) {
    try {
      const cats = await client.getCategoriesByIds(uniqueIds);
      for (const c of cats) {
        cache.set(c.id, { name: c.name, linkCountSubtree: c.linkCountSubtree });
      }
    } catch (e) {
      console.error("annotateLinks: getCategoriesByIds failed:", e);
    }
  }
  return links.map((link) => {
    const entry = cache.get(link.categoryId) ??
      { name: fallbackName, linkCountSubtree: fallbackCount };
    return {
      ...link,
      categoryName: entry.name,
      categoryLinkCountSubtree: entry.linkCountSubtree,
    };
  });
}

function emptyData(
  currentPath: string,
  sort: Sort,
  activeTag: string,
  error?: string,
): Data {
  return {
    result: null,
    currentPath,
    page: 1,
    pageLinks: [],
    pageTotal: 0,
    offsetCapHit: false,
    sort,
    activeTag,
    tagChips: [],
    clearTagHref: buildToolbarHref(currentPath, 1, sort, ""),
    rawCount: 0,
    error,
  };
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const currentPath = ctx.params.path;
    const url = ctx.url;
    const pageRaw = parseInt(url.searchParams.get("page") ?? "1", 10);
    const pageNum = Number.isFinite(pageRaw) && pageRaw >= 1 ? pageRaw : 1;
    const offset = (pageNum - 1) * PAGE_SIZE;
    const sort = parseSort(url.searchParams.get("sort"));
    const activeTag = (url.searchParams.get("tag") ?? "").trim();

    try {
      const client = getClient();
      const result = await client.browsePath(currentPath);

      ctx.state.title = result.category.name;
      if (result.category.description) {
        ctx.state.description = result.category.description;
      }

      if (offset > OFFSET_CAP) {
        return page({
          ...emptyData(currentPath, sort, activeTag),
          result,
          page: pageNum,
          pageTotal: result.totalLinksInSubtree,
          offsetCapHit: true,
        });
      }

      const linksPage = await client.listSubtreeLinks(result.category.id, {
        offset,
        limit: PAGE_SIZE,
      });
      const annotated = await annotateLinks(
        client,
        linksPage.links,
        result.category.name,
        result.category.linkCountSubtree,
        result.category.id,
      );

      const tagChips = computeTagChips(
        annotated,
        currentPath,
        pageNum,
        sort,
        activeTag,
      );
      const sorted = applySort(applyTagFilter(annotated, activeTag), sort);

      return page({
        result,
        currentPath,
        page: pageNum,
        pageLinks: sorted,
        pageTotal: linksPage.total,
        offsetCapHit: false,
        sort,
        activeTag,
        tagChips,
        clearTagHref: buildToolbarHref(currentPath, pageNum, sort, ""),
        rawCount: annotated.length,
      });
    } catch (e) {
      console.error("Failed to browse category path:", e);
      return page(
        emptyData(currentPath, sort, activeTag, "Category not found"),
      );
    }
  },
});

export default define.page<typeof handler>(function CategoryPage(props) {
  const {
    result,
    currentPath,
    page: pageNum,
    pageLinks,
    pageTotal,
    offsetCapHit,
    sort,
    activeTag,
    tagChips,
    clearTagHref,
    rawCount,
    error,
  } = props.data;
  const category = result?.category;
  const ancestors = result?.ancestors ?? [];
  const children = result?.children ?? [];

  const totalPages = Math.min(
    Math.ceil(pageTotal / PAGE_SIZE) || 1,
    MAX_PAGES,
  );
  const showListings = !offsetCapHit && rawCount > 0;
  const isEmpty = Boolean(category) && !error && !offsetCapHit &&
    children.length === 0 && rawCount === 0;

  return (
    <>
      <div class={`container ${styles.page} ${isEmpty ? styles.flush : ""}`}>
        {category
          ? (() => {
            // Skip the canonical "Top" root — it isn't a navigable page;
            // `Directory` already represents the index root.
            const visible = ancestors[0]?.slug === "top"
              ? ancestors.slice(1)
              : ancestors;
            return (
              <Crumbs
                crumbs={visible.map((a, i) => ({
                  name: formatCategoryName(a.name),
                  href: `/category/${
                    visible.slice(0, i + 1).map((x) => x.slug || String(x.id))
                      .join("/")
                  }`,
                }))}
                title={formatCategoryName(category.name)}
              />
            );
          })()
          : null}
        {error ? <ErrorBanner message={error} /> : null}
        {category
          ? (
            <CatHero
              category={category}
              ancestors={ancestors}
              childrenCount={children.length}
            />
          )
          : null}
        {offsetCapHit ? <OffsetCapBanner maxPages={MAX_PAGES} /> : null}
      </div>

      {children.length > 0
        ? <SubcategoriesList items={children} currentPath={currentPath} />
        : null}

      {showListings
        ? (
          <ListingsSection
            pageLinks={pageLinks}
            page={pageNum}
            pageTotal={pageTotal}
            totalPages={totalPages}
            currentPath={currentPath}
            hasSubcategories={children.length > 0}
            sort={sort}
            activeTag={activeTag}
            tagChips={tagChips}
            clearTagHref={clearTagHref}
            rawCount={rawCount}
          />
        )
        : null}

      {isEmpty ? <EmptyState /> : null}
    </>
  );
});
