import { page } from "fresh";
import { define } from "../../utils.ts";
import { createUser, updateUser } from "../../lib/kv-users.ts";
import { createSession } from "../../lib/session.ts";
import Eyebrow from "../../components/common/Eyebrow/Eyebrow.tsx";
import styles from "./login.module.css";

interface Values {
  email?: string;
  username?: string;
  displayName?: string;
}

interface Data {
  errors?: Record<string, string>;
  values?: Values;
}

function validate(
  form: FormData,
): { errors: Record<string, string>; values: Values } {
  const email = form.get("email")?.toString()?.trim() ?? "";
  const username = form.get("username")?.toString()?.trim() ?? "";
  const displayName = form.get("displayName")?.toString()?.trim() ?? "";
  const password = form.get("password")?.toString() ?? "";
  const confirmPassword = form.get("confirmPassword")?.toString() ?? "";

  const values: Values = { email, username, displayName };
  const errors: Record<string, string> = {};

  if (!email) errors.email = "Email is required";
  else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    errors.email = "Please enter a valid email address";
  }

  if (!username) errors.username = "Username is required";
  else if (username.length < 3) {
    errors.username = "Username must be at least 3 characters";
  } else if (!/^[a-zA-Z0-9_-]+$/.test(username)) {
    errors.username =
      "Username may only contain letters, numbers, hyphens, and underscores";
  }

  if (!password) errors.password = "Password is required";
  else if (password.length < 8) {
    errors.password = "Password must be at least 8 characters";
  }

  if (password !== confirmPassword) {
    errors.confirmPassword = "Passwords do not match";
  }

  return { errors, values };
}

export const handler = define.handlers<Data>({
  GET(ctx) {
    ctx.state.title = "Create account";
    return page({});
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const { errors, values } = validate(form);
    if (Object.keys(errors).length > 0) return page({ errors, values });

    const email = values.email!;
    const username = values.username!;
    const displayName = values.displayName!;
    const password = form.get("password")!.toString();

    try {
      const user = await createUser(email, username, password);
      if (displayName) await updateUser(user.id, { displayName });
      const { cookie } = await createSession(user.id);
      return new Response(null, {
        status: 303,
        headers: { Location: "/", "Set-Cookie": cookie },
      });
    } catch (err) {
      const msg = (err as Error).message;
      const map: Record<string, string> = {};
      if (msg.includes("email")) map.email = msg;
      else if (msg.includes("username")) map.username = msg;
      else map.general = msg;
      return page({ errors: map, values });
    }
  },
});

function FieldError(
  { errors, key }: { errors?: Record<string, string>; key: string },
) {
  if (!errors?.[key]) return null;
  return <span class="err">{errors[key]}</span>;
}

export default define.page<typeof handler>(function RegisterPage(props) {
  const { errors, values } = props.data;
  return (
    <div class="container">
      <div class={`${styles.card} ${styles.single}`}>
        <div class={styles.panel}>
          <Eyebrow num="02" label="Create account" />
          <h2 class="h2 mt-16">Create your editor account.</h2>
          <p class="lede mt-16">
            Account creation is open. Stewardship of a category requires an
            additional editor application — that comes later.
          </p>
          {errors?.general
            ? <div class="banner error mt-24">{errors.general}</div>
            : null}
          <form method="POST" class={styles.form}>
            <div class="form-grid two">
              <div class="field">
                <label for="displayName">Display name</label>
                <input
                  class="input"
                  id="displayName"
                  name="displayName"
                  value={values?.displayName ?? ""}
                />
              </div>
              <div class="field">
                <label for="username">Handle</label>
                <input
                  class="input"
                  id="username"
                  name="username"
                  required
                  autocomplete="username"
                  value={values?.username ?? ""}
                />
                <FieldError errors={errors} key="username" />
              </div>
            </div>
            <div class="field">
              <label for="email">Email</label>
              <input
                class="input"
                id="email"
                name="email"
                type="email"
                required
                autocomplete="email"
                value={values?.email ?? ""}
              />
              <FieldError errors={errors} key="email" />
            </div>
            <div class="form-grid two">
              <div class="field">
                <label for="password">Password</label>
                <input
                  class="input"
                  id="password"
                  name="password"
                  type="password"
                  required
                  minLength={8}
                  autocomplete="new-password"
                />
                <FieldError errors={errors} key="password" />
              </div>
              <div class="field">
                <label for="confirmPassword">Confirm password</label>
                <input
                  class="input"
                  id="confirmPassword"
                  name="confirmPassword"
                  type="password"
                  required
                  autocomplete="new-password"
                />
                <FieldError errors={errors} key="confirmPassword" />
              </div>
            </div>
            <p class="hint">Minimum 8 characters.</p>
            <div class="row between">
              <button type="submit" class="btn">Create account →</button>
              <a class="btn link" href="/auth/login">Already have one?</a>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
});
