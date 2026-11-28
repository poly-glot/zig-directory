import { assertEquals } from "jsr:@std/assert@^1";
import { parseFormState } from "./parseForm.ts";
import { validateStep1, validateStep2 } from "./validate.ts";
import { DESCRIPTION_MAX, TITLE_MAX, URL_MAX_BYTES } from "./types.ts";

function form(fields: Record<string, string>): FormData {
  const data = new FormData();
  for (const [name, value] of Object.entries(fields)) data.set(name, value);
  return data;
}

Deno.test("a URL over the stored limit is refused, not cut to a different shorter URL", () => {
  const url = `https://example.org/${"a".repeat(89)}`;
  const state = parseFormState(form({ url, title: "Example" }));

  assertEquals(state.url, url);
  assertEquals(
    validateStep1(state).url,
    `URL must be ${URL_MAX_BYTES} bytes or fewer.`,
  );
});

Deno.test("a URL at the stored limit is accepted", () => {
  const url = `https://example.org/${"a".repeat(URL_MAX_BYTES - 20)}`;
  const state = parseFormState(form({ url, title: "Example" }));

  assertEquals(url.length, URL_MAX_BYTES);
  assertEquals(validateStep1(state), {});
});

Deno.test("an over-long title and description are reported, not silently cut", () => {
  const state = parseFormState(form({
    url: "https://example.org",
    title: "t".repeat(TITLE_MAX + 1),
    description: "d".repeat(DESCRIPTION_MAX + 1),
  }));

  assertEquals(state.title.length, TITLE_MAX + 1);
  assertEquals(
    validateStep1(state).title,
    `Title must be ${TITLE_MAX} characters or fewer.`,
  );
  assertEquals(
    validateStep2(state).description,
    `Description must be ${DESCRIPTION_MAX} characters or fewer.`,
  );
});
