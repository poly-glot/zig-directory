import { page } from "fresh";
import { define } from "../utils.ts";
import { type Category, getClient } from "../lib/dmoz-client.ts";
import Eyebrow from "../components/common/Eyebrow/Eyebrow.tsx";
import SectionHead from "../components/common/SectionHead/SectionHead.tsx";
import CategoryRow from "../components/common/CategoryRow/CategoryRow.tsx";
import { pad2 } from "../lib/format.ts";
import styles from "./_404.module.css";

interface Data {
  categories: Category[];
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    ctx.state.title = "Page not found";
    let categories: Category[] = [];
    try {
      categories = await getClient().listRootCategories(0, 5);
    } catch (e) {
      console.error("404 suggestions failed:", e);
    }
    return page({ categories }, { status: 404 });
  },
});

function Suggestions({ categories }: { categories: Category[] }) {
  if (categories.length === 0) return null;
  return (
    <section class="section gray">
      <div class="container">
        <SectionHead
          num="01"
          topic="Suggested"
          title="Try one of these instead."
        />
        <ul class="list">
          {categories.map((cat, i) => (
            <CategoryRow
              key={cat.id}
              num={pad2(i + 1)}
              href={`/category/${cat.slug || cat.id}`}
              name={cat.name}
              count={cat.linkCountSubtree ?? cat.linkCount ?? 0}
            />
          ))}
        </ul>
      </div>
    </section>
  );
}

export default define.page<typeof handler>(function NotFoundPage(props) {
  const categories = props.data?.categories ?? [];
  return (
    <>
      <section class="section">
        <div class="container">
          <div class={`${styles.layout} notfound`}>
            <div class={`${styles.big} big`}>404</div>
            <div class={`${styles.copy} copy`}>
              <Eyebrow muted label="Page not found" />
              <h1 class="display mt-16">We couldn't find that page.</h1>
              <p class="lede">
                The page or category you asked for doesn't exist in the index.
                The link may be stale or mistyped.
              </p>
              <div class="row mt-32">
                <a class="btn" href="/">← Back to directory</a>
                <a class="btn ghost" href="/search">Search instead →</a>
              </div>
            </div>
          </div>
        </div>
      </section>

      <Suggestions categories={categories} />
    </>
  );
});
