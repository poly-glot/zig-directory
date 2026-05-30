import type { User } from "../../../lib/kv-users.ts";
import UserMenu from "../../../islands/UserMenu.tsx";
import styles from "./SiteHeader.module.css";

export type ActiveNav =
  | "home"
  | "search"
  | "about"
  | "submit"
  | "admin"
  | "profile"
  | "login"
  | "signup"
  | "";

interface Props {
  user: User | null;
  activeNav: ActiveNav;
  invert?: boolean;
}

const ARROW = (
  <span class={styles.arrow} aria-hidden="true">
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

const SEARCH_GLYPH = (
  <span class={styles.searchIcon} aria-hidden="true">
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.4"
    >
      <circle cx="6" cy="6" r="4.5" />
      <path d="M9.5 9.5l3 3" />
    </svg>
  </span>
);

function NavLink(
  { href, label, id, active }: {
    href: string;
    label: string;
    id: ActiveNav;
    active: ActiveNav;
  },
) {
  const cls = id === active
    ? `${styles.navLink} ${styles.active}`
    : styles.navLink;
  return <a class={cls} href={href}>{label}</a>;
}

export default function SiteHeader({ user, activeNav, invert = false }: Props) {
  // Plain class names ("site-header", "brand", "hsearch") are appended
  // alongside the module-hashed ones so the e2e suite's selectors keep
  // working. They carry no styles — they're testing hooks only.
  const headerClass = invert
    ? `${styles.header} ${styles.invert} site-header invert`
    : `${styles.header} site-header`;
  return (
    <>
      <a href="#main" class={`${styles.skipLink} skip-link`}>Skip to content</a>
      <header class={headerClass}>
        <div class={styles.wrap}>
          <a class={`${styles.brand} brand`} href="/">
            <span class={`${styles.dot} dot`} aria-hidden="true">
            </span>DMOZSTYLE
          </a>
          <form
            class={`${styles.search} hsearch`}
            action="/search"
            method="GET"
            role="search"
            aria-label="Site search"
          >
            {SEARCH_GLYPH}
            <input
              class={styles.searchInput}
              name="q"
              type="text"
              placeholder="Search the directory…"
              aria-label="Search the directory"
            />
            <span class={`${styles.kbd} kbd`} aria-hidden="true">↵</span>
          </form>
          <nav class={`${styles.nav} hnav`} aria-label="Primary">
            <NavLink
              href="/about"
              label="About"
              id="about"
              active={activeNav}
            />
            {
              /* Admin link is reachable via the UserMenu dropdown for
                admin users — no separate top-level entry to avoid two
                "Admin" affordances side-by-side in the nav. */
            }
            {user ? <UserMenu user={user} /> : (
              <NavLink
                href="/auth/login"
                label="Sign in"
                id="login"
                active={activeNav}
              />
            )}
            <a class={styles.submitBtn} href="/submit">
              Submit a link {ARROW}
            </a>
          </nav>
        </div>
      </header>
    </>
  );
}
