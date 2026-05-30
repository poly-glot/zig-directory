import type { ComponentChildren } from "preact";
import Banner from "../Banner/Banner.tsx";
import FormGrid from "../FormGrid/FormGrid.tsx";
import FormFooter from "../FormFooter/FormFooter.tsx";
import ConfirmForm from "../../../islands/ConfirmForm.tsx";

interface Props {
  /**
   * Hidden form fields included with the primary submit. Useful for the
   * action discriminator (`["_action","update"]`) plus any contextual
   * IDs (parentId, categoryId).
   */
  hidden: ReadonlyArray<readonly [string, string]>;
  /** Optional success/error banner shown above the form. */
  message?: string;
  /** Grid column count for the field children. Defaults to 2. */
  cols?: 1 | 2;
  /** Field children — typically `<Field>`s inside the FormGrid. */
  children: ComponentChildren;
  /** Where the Cancel link goes. */
  cancelHref: string;
  /** Cancel link label. Defaults to "Back to list". */
  cancelLabel?: string;
  /** Primary submit button label. Defaults to "Save changes". */
  primaryLabel?: string;
  /**
   * Confirm-and-delete block rendered below the save form. The same
   * `cancelHref` would lead back to the list; the delete posts to the
   * same endpoint via `hidden` fields here.
   */
  deleteAction?: {
    message: string;
    hidden: ReadonlyArray<readonly [string, string]>;
    label: string;
  };
}

function Hidden(
  { fields }: { fields: ReadonlyArray<readonly [string, string]> },
) {
  return (
    <>
      {fields.map(([name, value]) => (
        <input key={name} type="hidden" name={name} value={value} />
      ))}
    </>
  );
}

export default function EditForm(
  {
    hidden,
    message,
    cols = 2,
    children,
    cancelHref,
    cancelLabel = "Back to list",
    primaryLabel = "Save changes",
    deleteAction,
  }: Props,
) {
  return (
    <>
      <Banner message={message} />
      <form method="POST" class="admin-form mt-24">
        <Hidden fields={hidden} />
        <FormGrid cols={cols}>{children}</FormGrid>
        <FormFooter
          cancel={<a href={cancelHref} class="btn ghost">{cancelLabel}</a>}
          primary={<button type="submit" class="btn">{primaryLabel}</button>}
        />
      </form>
      {deleteAction
        ? (
          <div class="mt-24">
            <ConfirmForm message={deleteAction.message}>
              <Hidden fields={deleteAction.hidden} />
              <button type="submit" class="btn danger">
                {deleteAction.label}
              </button>
            </ConfirmForm>
          </div>
        )
        : null}
    </>
  );
}
