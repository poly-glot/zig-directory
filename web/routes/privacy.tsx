import { page } from "fresh";
import { define } from "../utils.ts";
import Eyebrow from "../components/common/Eyebrow/Eyebrow.tsx";
import styles from "./terms.module.css";

interface TocItem {
  id: string;
  label: string;
}

const TOC: TocItem[] = [
  { id: "data-collected", label: "Data collected" },
  { id: "cookies", label: "Cookies" },
  { id: "logs-and-metrics", label: "Logs and metrics" },
  { id: "third-parties", label: "Third parties" },
  { id: "your-rights", label: "Your rights" },
  { id: "contact", label: "Contact" },
];

export const handler = define.handlers({
  GET: (ctx) => {
    ctx.state.title = "Privacy";
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
      <h2 id="data-collected">Data collected</h2>
      <p>
        DMOZSTYLE collects only what's needed to run an editorial directory. For
        editors, that's an account record: email address, hashed password,
        display name, and an optional bio. Read-only visitors are not asked to
        sign in and are not profiled.
      </p>
      <p>
        Submitted links carry the submitter's account reference so editors can
        attribute and follow up on the queue. No additional fingerprinting or
        analytics payloads are attached to a request.
      </p>

      <h2 id="cookies">Cookies</h2>
      <p>
        One session cookie is set on sign-in:{" "}
        <code>dmoz_session</code>. It is HttpOnly, SameSite=Lax, and expires
        after seven days. It exists solely to keep an editor signed in and is
        cleared on sign-out.
      </p>
      <p>
        No advertising, analytics, or third-party cookies are set by the
        directory.
      </p>

      <h2 id="logs-and-metrics">Logs and metrics</h2>
      <p>
        The server records request IPs at the application layer for one purpose:
        rejecting traffic when the directory is in protected mode. There is no
        analytics pipeline, no behavioural funnel, and no long-term log
        retention beyond what's needed to debug an outage.
      </p>

      <h2 id="third-parties">Third parties</h2>
      <p>
        The directory has no third-party data sharing. There are no embedded
        scripts, no remote fonts, no tag managers, and no advertising partners.
        The reading experience is fully served from the application binary.
      </p>

      <h2 id="your-rights">Your rights</h2>
      <p>
        Editors can sign in to update their account at any time. Account
        deletion is handled manually in this slice: contact an admin and your
        record will be removed. Automated self-service deletion is not yet
        shipped — we'd rather flag that honestly than imply otherwise.
      </p>

      <h2 id="contact">Contact</h2>
      <p>
        For privacy questions or deletion requests, email{" "}
        <a class="under" href="mailto:editorial@dmozstyle.example">
          editorial@dmozstyle.example
        </a>.
      </p>
    </article>
  );
}

export default define.page(function PrivacyPage() {
  return (
    <section class="section">
      <div class="container">
        <div class="crumbs">
          <a href="/">Directory</a>
          <span class="sep">/</span>
          <span class="here">Privacy</span>
        </div>
        <Eyebrow muted label="Privacy" />
        <h1 class="display mt-16">Privacy.</h1>
        <p class="lede mt-16 measure">
          DMOZSTYLE collects the minimum data required to operate an editorial
          directory and does not share it.
        </p>

        <div class={`${styles.legal} legal mt-64`}>
          <Toc />
          <Article />
        </div>
      </div>
    </section>
  );
});
