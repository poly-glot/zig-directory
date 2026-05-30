import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";

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

export default function HomeContributeSection() {
  return (
    <section class="section">
      <div class="container text-center">
        <Eyebrow muted label="Contribute" />
        <h2 class="h1 mt-16">Submit a site to the index.</h2>
        <p class="lede mt-16 mx-auto">
          Editors review submissions weekly. You'll be notified when your link
          is approved, declined, or moved to a more appropriate category.
        </p>
        <div class="row center mt-32">
          <a class="btn" href="/submit">Submit a link {ARROW}</a>
          <a class="btn link" href="/auth/register">Become an editor →</a>
        </div>
      </div>
    </section>
  );
}
