import { page } from "fresh";
import { define } from "../../utils.ts";
import { DmozError, getClient, type Link } from "../../lib/dmoz-client.ts";
import { formatLongDateOrDash, pad7, safeHostname } from "../../lib/format.ts";
import { safeHref } from "../../lib/url.ts";
import Eyebrow from "../../components/common/Eyebrow/Eyebrow.tsx";
import Hostname from "../../components/common/Hostname/Hostname.tsx";
import Crumbs, { type Crumb } from "../../components/common/Crumbs/Crumbs.tsx";
import HeroChips from "../../components/link/HeroChips/HeroChips.tsx";
import RecordAside from "../../components/link/RecordAside/RecordAside.tsx";
import Adjacent from "../../components/link/Adjacent/Adjacent.tsx";
import styles from "./[id].module.css";

interface Data {
  link: Link;
  crumbs: Crumb[];
  categoryPath: string;
  adjacent: Link[];
}

const ADJACENT_LIMIT = 3;

async function buildCrumbs(
  client: ReturnType<typeof getClient>,
  startCategoryId: number,
): Promise<{ crumbs: Crumb[]; categoryPath: string }> {
  const chains = await client.breadcrumbsByIds([startCategoryId]);
  const chain = chains.get(startCategoryId) ?? [];
  const slugs = chain.map((a) => a.slug || String(a.id));
  const crumbs = chain.map((a, i) => ({
    name: a.name,
    href: `/category/${slugs.slice(0, i + 1).join("/")}`,
  }));
  return { crumbs, categoryPath: slugs.join("/") };
}

async function loadAdjacent(
  client: ReturnType<typeof getClient>,
  categoryId: number,
  excludeId: number,
): Promise<Link[]> {
  // Fetch ADJACENT_LIMIT + 1 so that if the current link itself falls
  // inside the prefix, dropping it still leaves enough rows. Used to
  // pull SIBLING_FETCH=12 and slice — pure over-fetch.
  const { links: peers } = await client.listLinks(categoryId, {
    limit: ADJACENT_LIMIT + 1,
  });
  return peers.filter((p) => p.id !== excludeId).slice(0, ADJACENT_LIMIT);
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const id = Number(ctx.params.id);
    if (!Number.isFinite(id) || id <= 0) {
      return new Response("Not found", { status: 404 });
    }

    const client = getClient();
    let link: Link;
    try {
      link = await client.getLink(id);
    } catch (e) {
      if (e instanceof DmozError && e.status === 1) {
        return new Response("Not found", { status: 404 });
      }
      throw e;
    }

    let crumbs: Crumb[] = [];
    let categoryPath = "";
    let adjacent: Link[] = [];
    try {
      const [built, adj] = await Promise.all([
        buildCrumbs(client, link.categoryId),
        loadAdjacent(client, link.categoryId, link.id),
      ]);
      crumbs = built.crumbs;
      categoryPath = built.categoryPath;
      adjacent = adj;
    } catch (e) {
      console.error("link page: crumbs/adjacent load failed:", e);
    }

    ctx.state.title = link.title;
    if (link.description) ctx.state.description = link.description;
    return page({ link, crumbs, categoryPath, adjacent });
  },
});

function EditorNote(
  { note, added, reviewed, url }: {
    note: string;
    added: string;
    reviewed: string;
    url: string;
  },
) {
  if (note.length > 0) {
    return <p class="body mt-16 measure">{note}</p>;
  }
  return (
    <p class="body mt-16 measure">
      Indexed on {added}, last reviewed on {reviewed}. Domain:{" "}
      <Hostname url={url} />. No editor note has been added yet.
    </p>
  );
}

export default define.page<typeof handler>(function LinkDetailPage(props) {
  const { link, crumbs, categoryPath, adjacent } = props.data;
  const added = formatLongDateOrDash(link.createdAt);
  const reviewed = formatLongDateOrDash(link.updatedAt);
  const crumbText = crumbs.map((c) => c.name).join(" › ");
  const backHref = categoryPath ? `/category/${categoryPath}` : "/";

  return (
    <>
      <div class="container">
        <Crumbs crumbs={crumbs} title={link.title} />
      </div>
      <div class="container">
        <div class={styles.shell}>
          <article>
            <Eyebrow muted label={`No. ${pad7(link.id)}`} />
            <h1 class="display mt-16">{link.title}</h1>
            <HeroChips
              hostname={safeHostname(link.url)}
              crumbText={crumbText}
              added={added}
            />
            {link.description ? <p class="lede">{link.description}</p> : null}
            <div class="row gap-16 mt-32 flex-wrap">
              <a
                class="btn"
                href={safeHref(link.url)}
                target="_blank"
                rel="noopener noreferrer"
              >
                Visit site →
              </a>
              <a class="btn ghost" href={backHref}>Back to listings</a>
            </div>
            <div class="hr mt-48 mb-32"></div>
            <Eyebrow muted label="Editor's note" />
            <EditorNote
              note={link.editorNote}
              added={added}
              reviewed={reviewed}
              url={link.url}
            />
          </article>
          <RecordAside
            id={link.id}
            reviewed={reviewed}
            status={link.status}
            submitterId={link.submitterId}
            language={link.language}
            region={link.region}
            license={link.license}
            tags={link.tags}
          />
        </div>
      </div>
      <Adjacent links={adjacent} />
    </>
  );
});
