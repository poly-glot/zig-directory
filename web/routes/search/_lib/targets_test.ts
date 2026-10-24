import { assertEquals } from "jsr:@std/assert@^1";
import type { NameMatch } from "../../../lib/dmoz-client.ts";
import type { Religion } from "../../../lib/dmoz-protocol.gen.ts";
import type { QueryVocabulary } from "../../../lib/entities.ts";
import {
  canonicalQuery,
  contentWords,
  linkQueryFor,
  namePhrases,
  rankedQuery,
  recognise,
  type Target,
  typedTargets,
  unmatched,
} from "./targets.ts";

const COUNTRIES: Record<string, string> = {
  pakistan: "PK",
  pakistani: "PK",
  india: "IN",
  usa: "US",
  "united states": "US",
};
const RELIGIONS: Record<string, Religion> = { islam: "islam", muslim: "islam" };
const COMMON = new Set(["web", "design", "rock", "band", "new", "york"]);
const vocabulary: QueryVocabulary = {
  countryOf: (phrase) => COUNTRIES[phrase.toLowerCase()],
  religionOf: (word) => RELIGIONS[word.toLowerCase()],
  isCommon: (word) => COMMON.has(word),
};

const ARTS = 3;
const JAZZ = 5;
const NEW_YORK = 9;

function known(entries: Record<string, Partial<NameMatch>>) {
  return new Map(
    Object.entries(entries).map(([phrase, match]) => [phrase, {
      categoryId: 0,
      namesSomeone: false,
      ...match,
    }]),
  );
}

function understand(query: string, names = known({})) {
  const typed = typedTargets(query, vocabulary);
  return recognise(typed.text, typed.targets, vocabulary, names);
}

Deno.test("a sentence naming a category, a country and a religion targets all three", () => {
  const sentence = "show me links in art category under Pakistan for islam";
  assertEquals(namePhrases(sentence, vocabulary).includes("art"), true);
  assertEquals(understand(sentence, known({ art: { categoryId: ARTS } })), {
    targets: [
      { kind: "category", value: "", categoryId: ARTS },
      { kind: "country", value: "PK" },
      { kind: "religion", value: "islam" },
    ],
    words: [],
  });
});

Deno.test("a domain in a question is the site to count", () => {
  assertEquals(understand("how many sites are subdomains of tripod.com?"), {
    targets: [{ kind: "site", value: "tripod.com" }],
    words: [],
  });
});

Deno.test("a category of common words stays words unless the sentence points at it", () => {
  const names = known({
    jazz: { categoryId: JAZZ },
    "rock band": { categoryId: 7 },
  });
  assertEquals(
    namePhrases("learn jazz piano online", vocabulary).includes("jazz"),
    false,
  );
  assertEquals(understand("rock band songs", names).targets, []);
  assertEquals(understand("links in the rock band category", names).targets, [
    { kind: "category", value: "", categoryId: 7 },
  ]);
  assertEquals(understand("learn jazz piano online", names), {
    targets: [],
    words: ["learn", "jazz", "piano", "online"],
  });
  assertEquals(understand("links in jazz", names).targets, [
    { kind: "category", value: "", categoryId: JAZZ },
  ]);
});

Deno.test("a name needs a distinctive word, so a generic phrase some link names stays words", () => {
  const names = known({
    "web design": { namesSomeone: true },
    "moniza alvi": { namesSomeone: true },
  });
  assertEquals(understand("web design tips", names), {
    targets: [],
    words: ["web", "design", "tips"],
  });
  assertEquals(understand("poems by Moniza Alvi", names), {
    targets: [{ kind: "name", value: "moniza alvi" }],
    words: ["poems"],
  });
});

Deno.test("a distinctive category name is targeted without a cue and wins over a name", () => {
  const names = known({
    "pink floyd": { categoryId: 11, namesSomeone: true },
  });
  assertEquals(understand("pink floyd lyrics", names), {
    targets: [{ kind: "category", value: "", categoryId: 11 }],
    words: ["lyrics"],
  });
});

Deno.test("the longest phrase wins and a second country stays a word", () => {
  const names = known({
    "new york": { categoryId: NEW_YORK },
    "new york times": { namesSomeone: true },
  });
  assertEquals(
    understand("New York Times articles about India and Pakistan", names),
    {
      targets: [
        { kind: "name", value: "new york times" },
        { kind: "country", value: "IN" },
      ],
      words: ["articles", "pakistan"],
    },
  );
});

Deno.test("typed operators take any value the vocabulary knows and explain the rest", () => {
  const typed = typedTargets(
    'country:pakistan religion:muslim name:"Moniza Alvi" poems',
    vocabulary,
  );
  assertEquals(typed.targets, [
    { kind: "country", value: "PK" },
    { kind: "religion", value: "islam" },
    { kind: "name", value: "Moniza Alvi" },
  ]);
  assertEquals(typed.text.trim(), "poems");
  assertEquals(
    typedTargets("country:atlantis", vocabulary).error,
    unmatched("country", "atlantis"),
  );
});

Deno.test("targets round-trip through a canonical query and become one query_links request", () => {
  const targets: Target[] = [
    { kind: "site", value: "tripod.com" },
    { kind: "name", value: "moniza alvi" },
    { kind: "religion", value: "islam" },
  ];
  const canonical = canonicalQuery(targets, ["anime"]);
  assertEquals(
    canonical,
    'site:tripod.com name:"moniza alvi" religion:islam anime',
  );
  assertEquals(understand(canonical), { targets, words: ["anime"] });
  assertEquals(linkQueryFor(targets, ["anime"]), {
    categoryId: 0,
    domain: "tripod.com",
    country: "",
    religions: ["islam"],
    entity: "moniza alvi",
    words: "anime",
    allWords: true,
  });
});

Deno.test("a sentence ranks by its content words only, and an all-stopword query ranks as typed", () => {
  assertEquals(contentWords("show me site about ali"), ["ali"]);
  assertEquals(
    contentWords("what are the links about biography about politicians"),
    ["biography", "politicians"],
  );
  assertEquals(rankedQuery("What are the links about Ali's site?"), "ali");
  assertEquals(rankedQuery("what is"), "what is");
});
