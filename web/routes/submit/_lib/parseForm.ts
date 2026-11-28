import type { FormState } from "./types.ts";

function readString(form: FormData, key: string): string {
  const v = form.get(key);
  return typeof v === "string" ? v.trim() : "";
}

function readInt(form: FormData, key: string): number {
  const raw = form.get(key);
  if (typeof raw !== "string") return 0;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

export function parseFormState(form: FormData): FormState {
  return {
    url: readString(form, "url"),
    title: readString(form, "title"),
    description: readString(form, "description"),
    categoryId: readInt(form, "categoryId"),
    subcategoryId: readInt(form, "subcategoryId"),
    affiliated: form.get("affiliated") === "1",
  };
}

export function parseStep(form: FormData): 1 | 2 | 3 | 4 {
  const raw = form.get("_step");
  if (raw === "1" || raw === "2" || raw === "3" || raw === "4") {
    return parseInt(raw, 10) as 1 | 2 | 3 | 4;
  }
  return 1;
}
