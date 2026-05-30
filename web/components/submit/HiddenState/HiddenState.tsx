import type { FormState } from "../../../routes/submit/_lib/types.ts";

interface Props {
  state: FormState;
  includeSub?: boolean;
}

export default function HiddenState({ state, includeSub = false }: Props) {
  return (
    <>
      <input type="hidden" name="url" value={state.url} />
      <input type="hidden" name="title" value={state.title} />
      <input type="hidden" name="description" value={state.description} />
      <input type="hidden" name="categoryId" value={String(state.categoryId)} />
      {includeSub
        ? (
          <input
            type="hidden"
            name="subcategoryId"
            value={String(state.subcategoryId)}
          />
        )
        : null}
      <input
        type="hidden"
        name="affiliated"
        value={state.affiliated ? "1" : "0"}
      />
    </>
  );
}
