import type { Category } from "../../../lib/dmoz-client.ts";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import type { FormState } from "../../../routes/submit/_lib/types.ts";
import { ErrorBanner, FieldError } from "../Banners/Banners.tsx";
import HiddenState from "../HiddenState/HiddenState.tsx";
import styles from "./Step4Review.module.css";

interface Props {
  state: FormState;
  errors: Record<string, string>;
  topCategories: Category[];
  subCategories: Category[];
}

function categoryName(list: Category[], id: number): string {
  return list.find((c) => c.id === id)?.name ?? "—";
}

function ReviewRow({ label, value }: { label: string; value: string }) {
  return (
    <div class={styles.row}>
      <span class="micro muted">{label}</span>
      <span class={styles.value}>{value || "—"}</span>
    </div>
  );
}

export default function Step4Review(
  { state, errors, topCategories, subCategories }: Props,
) {
  const top = categoryName(topCategories, state.categoryId);
  const sub = state.subcategoryId > 0
    ? categoryName(subCategories, state.subcategoryId)
    : "(top-level)";
  return (
    <form method="POST" class="form-grid">
      <input type="hidden" name="_step" value="4" />
      <HiddenState state={state} includeSub />
      <Eyebrow muted label="Step 04 of 04" />
      <h2 class="h2">Review &amp; submit.</h2>
      <ErrorBanner message={errors.submit ?? errors.general} />
      <div>
        <ReviewRow label="URL" value={state.url} />
        <ReviewRow label="Title" value={state.title} />
        <ReviewRow label="Description" value={state.description} />
        <ReviewRow label="Category" value={`${top} › ${sub}`} />
        <ReviewRow
          label="Affiliation"
          value={state.affiliated ? "Yes — submitter is owner" : "No"}
        />
      </div>
      <label class="checkbox mt-16">
        <input type="checkbox" name="_confirm" required />
        <span>I confirm the information above is accurate.</span>
      </label>
      <FieldError message={errors.confirm} />
      <div class="row between mt-16">
        <button
          class="btn ghost"
          type="submit"
          name="_action"
          value="back"
          formNoValidate
        >
          ← Back
        </button>
        <button class="btn" type="submit" name="_action" value="next">
          Submit for review →
        </button>
      </div>
    </form>
  );
}
