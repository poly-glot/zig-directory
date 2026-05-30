import { define } from "../utils.ts";
import SiteHeader, {
  type ActiveNav,
} from "../components/common/SiteHeader/SiteHeader.tsx";
import SiteFooter from "../components/common/SiteFooter/SiteFooter.tsx";
import styles from "./_layout.module.css";

// Map URL pathname → header nav highlight. Replaces every route's old
// `<Layout activeNav="search">` prop — derived once from ctx.url.
function deriveActiveNav(pathname: string): ActiveNav {
  if (pathname === "/") return "home";
  if (pathname.startsWith("/search")) return "search";
  if (pathname.startsWith("/about")) return "about";
  if (pathname.startsWith("/submit")) return "submit";
  if (pathname.startsWith("/admin")) return "admin";
  if (pathname.startsWith("/dashboard")) return "profile";
  if (pathname.startsWith("/auth/login")) return "login";
  if (pathname.startsWith("/auth/register")) return "signup";
  return "";
}

export default define.page(function Layout({ Component, state, url }) {
  const activeNav = deriveActiveNav(url.pathname);
  return (
    <div class={styles.page}>
      <SiteHeader user={state.user} activeNav={activeNav} />
      <main id="main" class={styles.main}>
        <Component />
      </main>
      <SiteFooter user={state.user} />
    </div>
  );
});
