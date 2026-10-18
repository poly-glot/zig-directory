import {
  type LinkQuery,
  MATCH_NAME_MAX_BYTES,
  MATCH_NAMES_MAX,
  type NameMatch,
} from "../../../lib/dmoz-client.ts";
import type { Religion } from "../../../lib/dmoz-protocol.gen.ts";
import type { QueryVocabulary } from "../../../lib/entities.ts";
import { searchHref } from "./queryParams.ts";

type TargetKind = "site" | "country" | "category" | "religion" | "name";

export interface Target {
  kind: TargetKind;
  value: string;
  categoryId?: number;
}

export interface Understanding {
  targets: Target[];
  words: string[];
  error?: string;
}

interface Constraint {
  label: string;
  targets: Target[];
  words: string[];
}

interface Typed {
  targets: Target[];
  text: string;
  error?: string;
}

interface KindRule {
  operator: string;
  single: boolean;
  noun: string;
  example: string;
  normalise(raw: string, vocabulary: QueryVocabulary): string | undefined;
  label(target: Target, categoryLabel: string): string;
}

const HOST_SUFFIX = /^[a-z0-9-]+(\.[a-z0-9-]+)*$/;
const DOMAIN = /^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/;
const COUNTRY_CODE = /^[a-z]{2}$/i;
const EDGE_DOTS = /^\.+|\.+$/g;
const EDGE_SLASHES = /^\/+|\/+$/g;
const EDGE_PUNCTUATION = /^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu;
const POSSESSIVE = /['’]s$/;
const QUOTES = /^"|"$/g;
const MAX_HOST_BYTES = 64;
const MAX_NAME_WORDS = 4;
const MAX_PLACE_WORDS = 8;
const REGION = new Intl.DisplayNames(["en"], { type: "region" });

const STOPWORDS = new Set(
  "a about all an and any are as at be by can categories category count do does find for from get give how i in inside into is it link links list many me my number of on or page pages please section show site sites some subdomain subdomains that the there these this those to under website websites what where which who with within"
    .split(" "),
);
const CUE_BEFORE = new Set(["in", "under", "within", "inside", "into"]);
const CUE_AFTER = new Set(["category", "categories", "section"]);

function isHostSuffix(site: string): boolean {
  return site.length <= MAX_HOST_BYTES && HOST_SUFFIX.test(site);
}

function capitalised(words: string): string {
  return words.replace(
    /(^|\s)(\p{L})/gu,
    (_, gap, first) => gap + first.toUpperCase(),
  );
}

const KINDS: Record<TargetKind, KindRule> = {
  site: {
    operator: "site",
    single: true,
    noun: "domain",
    example: "site:tripod.com",
    normalise: (raw) => {
      const site = raw.toLowerCase().replace(EDGE_DOTS, "");
      return isHostSuffix(site) ? site : undefined;
    },
    label: (target) => `On ${target.value}`,
  },
  country: {
    operator: "country",
    single: true,
    noun: "country",
    example: "country:pk",
    normalise: (raw, vocabulary) =>
      COUNTRY_CODE.test(raw) ? raw.toUpperCase() : vocabulary.countryOf(raw),
    label: (target) => `Tied to ${REGION.of(target.value) ?? target.value}`,
  },
  category: {
    operator: "in",
    single: true,
    noun: "category path",
    example: "in:arts/literature",
    normalise: (raw) =>
      raw.toLowerCase().replace(EDGE_SLASHES, "") || undefined,
    label: (_, categoryLabel) => `In ${categoryLabel}`,
  },
  religion: {
    operator: "religion",
    single: false,
    noun: "religion",
    example: "religion:islam",
    normalise: (raw, vocabulary) => vocabulary.religionOf(raw),
    label: (target) => `About ${capitalised(target.value)}`,
  },
  name: {
    operator: "name",
    single: true,
    noun: "person or organisation",
    example: 'name:"moniza alvi"',
    normalise: (raw) => raw.trim() || undefined,
    label: (target) => `Naming ${capitalised(target.value)}`,
  },
};

const KIND_OF_OPERATOR = new Map(
  (Object.entries(KINDS) as Array<[TargetKind, KindRule]>).map((
    [kind, rule],
  ) => [rule.operator, kind]),
);
const OPERATOR = new RegExp(
  `(?<=^|\\s)(${[...KIND_OF_OPERATOR.keys()].join("|")}):("[^"]*"|\\S*)`,
  "gi",
);

export function unmatched(kind: TargetKind, raw: string): string {
  const rule = KINDS[kind];
  return `Nothing matches ${rule.operator}:${raw}. It takes a ${rule.noun}, such as ${rule.example}`;
}

function targetLabel(target: Target, categoryLabel = ""): string {
  return KINDS[target.kind].label(target, categoryLabel);
}

export function typedTargets(
  query: string,
  vocabulary: QueryVocabulary,
): Typed {
  const targets: Target[] = [];
  for (const [, operator, quoted] of query.matchAll(OPERATOR)) {
    const kind = KIND_OF_OPERATOR.get(operator.toLowerCase())!;
    const raw = quoted.replace(QUOTES, "");
    const value = KINDS[kind].normalise(raw, vocabulary);
    if (value === undefined) {
      return { targets, text: query, error: unmatched(kind, raw) };
    }
    targets.push({ kind, value });
  }
  return { targets, text: query.replace(OPERATOR, " ") };
}

function wordsOf(text: string): string[] {
  return text.split(/\s+/)
    .map((word) =>
      word.replace(EDGE_PUNCTUATION, "").replace(POSSESSIVE, "").toLowerCase()
    )
    .filter(Boolean);
}

function cued(words: readonly string[], start: number, end: number): boolean {
  const before = words[start - 1] === "the"
    ? words[start - 2]
    : words[start - 1];
  return CUE_BEFORE.has(before ?? "") || CUE_AFTER.has(words[end] ?? "");
}

function nameShaped(phrase: readonly string[]): boolean {
  return !STOPWORDS.has(phrase[0]) && !STOPWORDS.has(phrase.at(-1)!) &&
    !phrase.some((word) => DOMAIN.test(word));
}

function distinctive(
  phrase: readonly string[],
  vocabulary: QueryVocabulary,
): boolean {
  return phrase.length > 1 &&
    phrase.some((word) => !vocabulary.isCommon(word));
}

export function namePhrases(
  text: string,
  vocabulary: QueryVocabulary,
): string[] {
  const words = wordsOf(text);
  const encoder = new TextEncoder();
  const phrases = new Set<string>();
  for (let length = 1; length <= MAX_NAME_WORDS; length++) {
    for (let start = 0; start + length <= words.length; start++) {
      const phrase = words.slice(start, start + length);
      const worthAsking = cued(words, start, start + length) ||
        distinctive(phrase, vocabulary);
      if (!nameShaped(phrase) || !worthAsking) continue;

      const joined = phrase.join(" ");
      if (encoder.encode(joined).length <= MATCH_NAME_MAX_BYTES) {
        phrases.add(joined);
      }
    }
  }
  return [...phrases].slice(0, MATCH_NAMES_MAX);
}

function targetFor(
  words: readonly string[],
  start: number,
  end: number,
  vocabulary: QueryVocabulary,
  names: ReadonlyMap<string, NameMatch>,
): Target | undefined {
  const span = words.slice(start, end);
  const phrase = span.join(" ");
  const single = span.length === 1;
  if (single && DOMAIN.test(phrase)) return { kind: "site", value: phrase };

  const country = vocabulary.countryOf(phrase);
  if (country) return { kind: "country", value: country };

  const religion = single ? vocabulary.religionOf(phrase) : undefined;
  if (religion) return { kind: "religion", value: religion };

  const match = names.get(phrase);
  if (!match) return undefined;

  const distinct = distinctive(span, vocabulary);
  if (match.categoryId && (distinct || cued(words, start, end))) {
    return { kind: "category", value: "", categoryId: match.categoryId };
  }
  if (match.namesSomeone && distinct) return { kind: "name", value: phrase };
  return undefined;
}

function longestTargetAt(
  words: readonly string[],
  start: number,
  vocabulary: QueryVocabulary,
  names: ReadonlyMap<string, NameMatch>,
  taken: ReadonlySet<TargetKind>,
): { target: Target; length: number } | undefined {
  const longest = Math.min(MAX_PLACE_WORDS, words.length - start);
  for (let length = longest; length >= 1; length--) {
    const target = targetFor(words, start, start + length, vocabulary, names);
    if (target && !taken.has(target.kind)) return { target, length };
  }
  return undefined;
}

export function recognise(
  text: string,
  typed: readonly Target[],
  vocabulary: QueryVocabulary,
  names: ReadonlyMap<string, NameMatch>,
): Understanding {
  const words = wordsOf(text);
  const targets = [...typed];
  const taken = new Set(
    targets.filter((t) => KINDS[t.kind].single).map((t) => t.kind),
  );
  const rest: string[] = [];

  for (let start = 0; start < words.length;) {
    const found = longestTargetAt(words, start, vocabulary, names, taken);
    if (!found) {
      rest.push(words[start]);
      start += 1;
      continue;
    }

    targets.push(found.target);
    if (KINDS[found.target.kind].single) taken.add(found.target.kind);
    start += found.length;
  }

  const content = rest.filter((word) =>
    word.length > 1 && !STOPWORDS.has(word)
  );
  return { targets, words: [...new Set(content)] };
}

export function constraintsOf(
  targets: readonly Target[],
  words: readonly string[],
  categoryLabel: string,
): Constraint[] {
  const byTarget = targets.map((target, i) => ({
    label: targetLabel(target, categoryLabel),
    targets: targets.toSpliced(i, 1),
    words: [...words],
  }));
  if (words.length === 0) return byTarget;
  return [...byTarget, {
    label: `Mentioning ${words.join(" ")}`,
    targets: [...targets],
    words: [],
  }];
}

export function linkQueryFor(
  targets: readonly Target[],
  words: readonly string[],
): LinkQuery {
  const valueOf = (kind: TargetKind) =>
    targets.find((target) => target.kind === kind)?.value ?? "";
  return {
    categoryId: targets.find((target) => target.kind === "category")
      ?.categoryId ?? 0,
    domain: valueOf("site"),
    country: valueOf("country"),
    religions: targets.filter((target) => target.kind === "religion")
      .map((target) => target.value as Religion),
    entity: valueOf("name"),
    words: words.join(" "),
    allWords: true,
  };
}

function operatorText(target: Target): string {
  const value = /\s/.test(target.value) ? `"${target.value}"` : target.value;
  return `${KINDS[target.kind].operator}:${value}`;
}

export function canonicalQuery(
  targets: readonly Target[],
  words: readonly string[],
): string {
  return [...targets.map(operatorText), ...words].join(" ");
}

export function siteSearchHref(site: string): string | undefined {
  if (!isHostSuffix(site)) return undefined;
  return searchHref({
    q: canonicalQuery([{ kind: "site", value: site }], []),
  });
}
