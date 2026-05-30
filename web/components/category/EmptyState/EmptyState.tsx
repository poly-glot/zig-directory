import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";

export default function EmptyState() {
  return (
    <section class="section">
      <div class="container text-center">
        <Eyebrow muted label="Empty" />
        <h2 class="h1 mt-16">Nothing listed here yet.</h2>
        <p class="lede mt-16 mx-auto">
          This category has no subcategories or editor-approved links indexed
          yet. Submit a site to help fill it in.
        </p>
        <div class="row center mt-32">
          <a class="btn" href="/submit">Submit a link →</a>
          <a class="btn link" href="/">Back to directory →</a>
        </div>
      </div>
    </section>
  );
}
