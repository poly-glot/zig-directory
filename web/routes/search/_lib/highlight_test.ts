import { assertEquals } from "jsr:@std/assert@^1";
import { highlight, tokensFor } from "./highlight.tsx";

Deno.test("highlight marks whole words of the content tokens, never stopwords inside other words", () => {
  const tokens = tokensFor("show me site about ali");
  assertEquals(tokens, ["ali"]);
  const parts = highlight("Ali's homepage from AskMen", tokens) as unknown[];
  assertEquals(parts.length, 3);
  assertEquals(parts[0], "");
  assertEquals(parts[2], "'s homepage from AskMen");
  assertEquals(highlight("Alice in Wonderland", tokens), [
    "Alice in Wonderland",
  ]);
});
