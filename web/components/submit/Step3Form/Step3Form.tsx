import type { Category } from "../../../lib/dmoz-client.ts";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import type { FormState } from "../../../routes/submit/_lib/types.ts";
import { ErrorBanner } from "../Banners/Banners.tsx";
import SubmitCategoryFields from "../../../islands/SubmitCategoryFields.tsx";

interface Props {
  state: FormState;
  errors: Record<string, string>;
  topCategories: Category[];
  subCategories: Category[];
}

function toOptions(list: Category[]): { id: number; name: string }[] {
  return list.map((c) => ({ id: c.id, name: c.name }));
}

export default function Step3Form(
  { state, errors, topCategories, subCategories }: Props,
) {
  return (
    <form method="POST" class="form-grid">
      <input type="hidden" name="_step" value="3" />
      <input type="hidden" name="url" value={state.url} />
      <input type="hidden" name="title" value={state.title} />
      <input type="hidden" name="description" value={state.description} />
      <Eyebrow muted label="Step 03 of 04" />
      <h2 class="h2">Choose a category.</h2>
      <p class="small muted">
        An editor may move it to a more appropriate one.
      </p>
      <ErrorBanner message={errors.general} />

      <SubmitCategoryFields
        topCategories={toOptions(topCategories)}
        initialCategoryId={state.categoryId}
        initialSubcategoryId={state.subcategoryId}
        initialSubCategories={toOptions(subCategories)}
      />

      <label class="checkbox">
        <input
          type="checkbox"
          name="affiliated"
          value="1"
          checked={state.affiliated}
        />
        <span>I am the owner or affiliated with this site.</span>
      </label>

      <div class="row between flex-wrap gap-16 mt-16">
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
          Next →
        </button>
      </div>
    </form>
  );
}
