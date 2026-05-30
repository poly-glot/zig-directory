// Wizard state types — shared across the submit slice's components and
// validation. Step numbers are encoded in URL/form state, "done" is the
// terminal post-submit screen.

export type Step = 1 | 2 | 3 | 4 | "done";

export interface FormState {
  url: string;
  title: string;
  description: string;
  categoryId: number;
  subcategoryId: number;
  affiliated: boolean;
}

export const EMPTY_STATE: FormState = {
  url: "",
  title: "",
  description: "",
  categoryId: 0,
  subcategoryId: 0,
  affiliated: false,
};

export const TITLE_MAX = 128;
export const DESCRIPTION_MIN = 30;
export const DESCRIPTION_MAX = 256;
