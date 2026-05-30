import { page } from "fresh";
import { define } from "../utils.ts";
import Eyebrow from "../components/common/Eyebrow/Eyebrow.tsx";
import styles from "./terms.module.css";

interface TocItem {
  id: string;
  label: string;
}

const TOC: TocItem[] = [
  { id: "acceptable-use", label: "Acceptable use" },
  { id: "editor-responsibilities", label: "Editor responsibilities" },
  { id: "submission-policy", label: "Submission policy" },
  { id: "intellectual-property", label: "Intellectual property" },
  { id: "disclaimers", label: "Disclaimers" },
  { id: "modifications", label: "Modifications" },
];

export const handler = define.handlers({
  GET: (ctx) => {
    ctx.state.title = "Terms";
    return page({});
  },
});

function Toc() {
  return (
    <nav class={`${styles.toc} toc`} aria-label="On this page">
      <h4>Contents</h4>
      <ul>
        {TOC.map((item) => (
          <li key={item.id}>
            <a href={`#${item.id}`}>{item.label}</a>
          </li>
        ))}
      </ul>
    </nav>
  );
}

function Article() {
  return (
    <article class={`${styles.article} article`}>
      <h2 id="acceptable-use">Acceptable use</h2>
      <p>
        Read, search, link, and submit. Don't scrape in ways that interfere with
        the service, attempt to bypass authentication, or use the directory to
        distribute malware, illegal content, or harassment.
      </p>

      <h2 id="editor-responsibilities">Editor responsibilities</h2>
      <p>
        Editors are responsible for what happens under their account. Tell us if
        you suspect a credential is compromised. Editorial accounts that violate
        these terms or the editorial guidelines may be suspended.
      </p>

      <h2 id="submission-policy">Submission policy</h2>
      <p>
        Submissions become part of the index under attribution to the submitter.
        The reviewing editor may decline a submission, re-categorise it, edit
        the description, or remove it later — those decisions are part of
        running an editorial directory.
      </p>

      <h2 id="intellectual-property">Intellectual property</h2>
      <p>
        The DMOZSTYLE codebase is a reference implementation. Site names and
        brands referenced in listings belong to their respective owners.
        Submitting a link grants the directory a non-exclusive licence to
        display the URL, name, and description.
      </p>

      <h2 id="disclaimers">Disclaimers</h2>
      <p>
        The service is provided as-is, without warranties. Outbound links are
        external and not endorsed by the directory; an editor's decision to list
        a site is not a recommendation of its content. We aren't liable for
        indirect or consequential damages arising from use.
      </p>

      <h2 id="modifications">Modifications</h2>
      <p>
        These terms may change. Material changes will be reflected on this page.
        Continued use after a change means you accept the updated terms.
      </p>
    </article>
  );
}

export default define.page(function TermsPage() {
  return (
    <section class="section">
      <div class="container">
        <div class="crumbs">
          <a href="/">Directory</a>
          <span class="sep">/</span>
          <span class="here">Terms</span>
        </div>
        <Eyebrow muted label="Terms" />
        <h1 class="display mt-16">Terms of use.</h1>
        <p class="lede mt-16 measure">
          By using DMOZSTYLE you agree to these terms. They are short on
          purpose.
        </p>

        <div class={`${styles.legal} legal mt-64`}>
          <Toc />
          <Article />
        </div>
      </div>
    </section>
  );
});
