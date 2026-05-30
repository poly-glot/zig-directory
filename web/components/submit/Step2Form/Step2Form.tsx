import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import {
  DESCRIPTION_MAX,
  DESCRIPTION_MIN,
  type FormState,
} from "../../../routes/submit/_lib/types.ts";
import { ErrorBanner, FieldError } from "../Banners/Banners.tsx";

interface Props {
  state: FormState;
  errors: Record<string, string>;
}

export default function Step2Form({ state, errors }: Props) {
  return (
    <form method="POST" class="form-grid">
      <input type="hidden" name="_step" value="2" />
      <input type="hidden" name="url" value={state.url} />
      <input type="hidden" name="title" value={state.title} />
      <Eyebrow muted label="Step 02 of 04" />
      <h2 class="h2">Describe the site.</h2>
      <ErrorBanner message={errors.general} />
      <div class="field">
        <label for="description">Description</label>
        <textarea
          class="textarea"
          id="description"
          name="description"
          required
          minLength={DESCRIPTION_MIN}
          maxLength={DESCRIPTION_MAX}
          placeholder="One or two sentences. Describe what visitors will find."
          value={state.description}
        />
        <span class="hint">
          Minimum {DESCRIPTION_MIN} characters. Maximum {DESCRIPTION_MAX}.
        </span>
        <FieldError message={errors.description} />
      </div>
      <button class="btn" type="submit" name="_action" value="next">
        Next →
      </button>
    </form>
  );
}
