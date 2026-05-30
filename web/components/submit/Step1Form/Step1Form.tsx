import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import {
  type FormState,
  TITLE_MAX,
} from "../../../routes/submit/_lib/types.ts";
import { ErrorBanner, FieldError } from "../Banners/Banners.tsx";

interface Props {
  state: FormState;
  errors: Record<string, string>;
}

export default function Step1Form({ state, errors }: Props) {
  return (
    <form method="POST" class="form-grid">
      <input type="hidden" name="_step" value="1" />
      <Eyebrow muted label="Step 01 of 04" />
      <h2 class="h2">The site you're submitting.</h2>
      <ErrorBanner message={errors.general} />
      <div class="field">
        <label for="url">URL</label>
        <input
          class="input"
          id="url"
          name="url"
          type="url"
          required
          placeholder="https://example.org"
          value={state.url}
        />
        <span class="hint">
          Canonical URL. Editors will follow it to verify.
        </span>
        <FieldError message={errors.url} />
      </div>
      <div class="field">
        <label for="title">Title</label>
        <input
          class="input"
          id="title"
          name="title"
          required
          maxLength={TITLE_MAX}
          placeholder="The name as it appears on the site"
          value={state.title}
        />
        <FieldError message={errors.title} />
      </div>
      <div class="row between mt-16">
        <a class="btn ghost" href="/">← Cancel</a>
        <button class="btn" type="submit">Next →</button>
      </div>
    </form>
  );
}
