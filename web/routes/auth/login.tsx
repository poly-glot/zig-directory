import { page } from "fresh";
import { define } from "../../utils.ts";
import { authenticateUser } from "../../lib/kv-users.ts";
import { createSession } from "../../lib/session.ts";
import Eyebrow from "../../components/common/Eyebrow/Eyebrow.tsx";
import styles from "./login.module.css";

interface Data {
  error?: string;
  email?: string;
}

export const handler = define.handlers<Data>({
  GET(ctx) {
    ctx.state.title = "Sign in";
    return page({});
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const email = form.get("email")?.toString() ?? "";
    const password = form.get("password")?.toString() ?? "";

    if (!email || !password) {
      return page({ error: "Email and password are required", email });
    }

    const user = await authenticateUser(email, password);
    if (!user) {
      return page({ error: "Invalid email or password", email });
    }

    const { cookie } = await createSession(user.id);
    return new Response(null, {
      status: 303,
      headers: { Location: "/", "Set-Cookie": cookie },
    });
  },
});

export default define.page<typeof handler>(function LoginPage(props) {
  const { error, email } = props.data;
  return (
    <div class="container">
      <div class={styles.card}>
        <div class={`${styles.panel} ${styles.ink}`}>
          <Eyebrow muted label="For editors" />
          <h2 class="h2 mt-16">Welcome back.</h2>
          <p class="lede mt-16">
            Editors keep the directory honest — vetting submissions,
            re-categorising, and pruning broken links.
          </p>
          <ul>
            <li>Review submissions in your stewarded category</li>
            <li>Suggest re-categorisations and corrections</li>
            <li>Flag broken or rotten links</li>
          </ul>
        </div>
        <div class={styles.panel}>
          <Eyebrow num="01" label="Sign in" />
          <h2 class="h2 mt-16">Editor sign-in.</h2>
          <p class="lede mt-16">Public browsing doesn't require an account.</p>
          {error ? <div class="banner error mt-24">{error}</div> : null}
          <form method="POST" class={styles.form}>
            <div class="field">
              <label for="email">Email</label>
              <input
                class="input"
                id="email"
                name="email"
                type="email"
                required
                autocomplete="email"
                value={email ?? ""}
              />
            </div>
            <div class="field">
              <label for="password">Password</label>
              <input
                class="input"
                id="password"
                name="password"
                type="password"
                required
                autocomplete="current-password"
              />
            </div>
            <div class="row between">
              <button type="submit" class="btn">Sign in →</button>
              <a class="btn link" href="/auth/register">Create account</a>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
});
