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

const GITHUB_MARK = (
  <svg
    width="18"
    height="18"
    viewBox="0 0 16 16"
    fill="currentColor"
    aria-hidden="true"
  >
    <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82A7.6 7.6 0 018 4.07c.68 0 1.36.09 2 .27 1.53-1.03 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.28.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.74.54 1.49 0 1.07-.01 1.94-.01 2.2 0 .21.15.46.55.38A8 8 0 0016 8c0-4.42-3.58-8-8-8z" />
  </svg>
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
            <a
              class={styles.github}
              href="https://github.com/poly-glot/zig-directory"
              target="_blank"
              rel="noopener noreferrer"
              aria-label="View source on GitHub"
              title="View source on GitHub"
            >
              {GITHUB_MARK}
            </a>
          </nav>
        </div>
      </header>
    </>
  );
}
