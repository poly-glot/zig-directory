import { assertEquals } from "jsr:@std/assert@^1";
import { linkDocumentText } from "./embedder.ts";
import { categoryNames } from "./format.ts";

Deno.test("a link embeds under its category path, with the root hidden and underscores as spaces", () => {
  const chain = [
    { id: 1, slug: "top", name: "Top" },
    { id: 2, slug: "arts", name: "Arts" },
    { id: 3, slug: "music", name: "Music" },
    { id: 4, slug: "bands_and_artists", name: "Bands_and_Artists" },
  ];
  assertEquals(categoryNames(chain), ["Arts", "Music", "Bands and Artists"]);
  assertEquals(
    linkDocumentText(
      categoryNames(chain),
      "Miles Davis",
      "Discography and photos.",
    ),
    "Arts > Music > Bands and Artists. Miles Davis. Discography and photos.",
  );
  assertEquals(linkDocumentText([], "Miles Davis", ""), "Miles Davis");
});
