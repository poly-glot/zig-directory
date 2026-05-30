import type { User } from "../../../lib/kv-users.ts";
import styles from "./SiteFooter.module.css";

interface Props {
  user: User | null;
}

function AccountList({ user }: Props) {
  if (user) {
    return (
      <ul>
        <li>
          <a href="/dashboard">Dashboard</a>
        </li>
        {user.role === "admin"
          ? (
            <li>
              <a href="/admin">Admin</a>
            </li>
          )
          : null}
        <li>
          <a href="/auth/logout">Sign out</a>
        </li>
      </ul>
    );
  }
  return (
    <ul>
      <li>
        <a href="/auth/login">Sign in</a>
      </li>
      <li>
        <a href="/auth/register">Create account</a>
      </li>
    </ul>
  );
}

export default function SiteFooter({ user }: Props) {
  return (
    <footer class={`${styles.footer} site-footer`}>
      <div class={styles.container}>
        <div class={`${styles.grid} footer-grid`}>
          <div>
            <span class={styles.brand}>
              <span class={styles.dot}></span>DMOZSTYLE
            </span>
            <p class={styles.tagline}>
              A hand-curated directory of the open web — a reference
              implementation built in Zig with an embedded database.
            </p>
          </div>
          <div>
            <h4>Browse</h4>
            <ul>
              <li>
                <a href="/">All categories</a>
              </li>
              <li>
                <a href="/search">Search</a>
              </li>
              <li>
                <a href="/submit">Submit a link</a>
              </li>
            </ul>
          </div>
          <div>
            <h4>Account</h4>
            <AccountList user={user} />
          </div>
          <div>
            <h4>Project</h4>
            <ul>
              <li>
                <a href="/about">About</a>
              </li>
              <li>
                <a href="/privacy">Privacy</a>
              </li>
              <li>
                <a href="/terms">Terms</a>
              </li>
            </ul>
          </div>
        </div>
        <div class={styles.bottom}>
          <span>© {new Date().getFullYear()} DMOZSTYLE</span>
          <span>Built in Zig · Open directory tradition</span>
        </div>
      </div>
    </footer>
  );
}
