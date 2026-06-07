import {
  DESCRIPTION_MAX,
  DESCRIPTION_MIN,
  type FormState,
  TITLE_MAX,
} from "./types.ts";
import { isHttpUrl } from "../../../lib/url.ts";

export function validateStep1(state: FormState): Record<string, string> {
  const errors: Record<string, string> = {};
  if (!state.url) errors.url = "URL is required.";
  else if (!isHttpUrl(state.url)) {
    errors.url = "Enter a valid http:// or https:// URL.";
  }
  if (!state.title) errors.title = "Title is required.";
  else if (state.title.length > TITLE_MAX) {
    errors.title = `Title must be ${TITLE_MAX} characters or fewer.`;
  }
  return errors;
}

export function validateStep2(state: FormState): Record<string, string> {
  const errors: Record<string, string> = {};
  const len = state.description.length;
  if (len < DESCRIPTION_MIN) {
    errors.description =
      `Description must be at least ${DESCRIPTION_MIN} characters.`;
  } else if (len > DESCRIPTION_MAX) {
    errors.description =
      `Description must be ${DESCRIPTION_MAX} characters or fewer.`;
  }
  return errors;
}

export function validateStep3(state: FormState): Record<string, string> {
  const errors: Record<string, string> = {};
  if (state.categoryId <= 0) {
    errors.categoryId = "Select a top-level category.";
  }
  return errors;
}

export function validateStep4(
  state: FormState,
  confirmed: boolean,
): Record<string, string> {
  const errors: Record<string, string> = {
    ...validateStep1(state),
    ...validateStep2(state),
    ...validateStep3(state),
  };
  if (!confirmed) {
    errors.confirm = "You must confirm the information is accurate.";
  }
  return errors;
}

export function validateForStep(
  step: 1 | 2 | 3 | 4,
  state: FormState,
  form: FormData,
): Record<string, string> {
  if (step === 1) return validateStep1(state);
  if (step === 2) return validateStep2(state);
  if (step === 3) return validateStep3(state);
  return validateStep4(state, form.get("_confirm") === "on");
}
