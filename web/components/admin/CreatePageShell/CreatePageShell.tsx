import type { ComponentChildren } from "preact";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import styles from "./CreatePageShell.module.css";

interface Props {
  /** Final breadcrumb segment (e.g. "New link"); Directory / Admin precede it. */
  here: string;
  eyebrow: string;
  title: string;
  lede: string;
  children: ComponentChildren;
}

// Standalone editorial page chrome for admin "create" forms — the same layout
// as /submit (crumbs, eyebrow, display heading, lede, centred form column),
// deliberately OUTSIDE AdminShell so creating a record is a focused full page
// rather than a panel wedged into a list view.
export default function CreatePageShell(
  { here, eyebrow, title, lede, children }: Props,
) {
  return (
    <>
      <section class="section tight">
        <div class="container">
          <nav class={`crumbs ${styles.crumbs}`}>
            <a href="/">Directory</a>
            <span class="sep">/</span>
            <a href="/admin">Admin</a>
            <span class="sep">/</span>
            <span class="here">{here}</span>
          </nav>
          <div class={styles.heroInner}>
            <Eyebrow muted label={eyebrow} />
            <h1 class="display mt-16">{title}</h1>
            <p class="lede mt-16">{lede}</p>
          </div>
        </div>
      </section>

      <section class="section">
        <div class="container">
          <div class={styles.formInner}>{children}</div>
        </div>
      </section>
    </>
  );
}
