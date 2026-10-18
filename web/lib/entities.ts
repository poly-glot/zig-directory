import { Tokenizer } from "@huggingface/tokenizers";
import {
  type DmozClient,
  type LinkEntities,
  linkTextFingerprint,
  MAX_ENTITY_NAME_BYTES,
  MAX_ENTITY_NAMES,
} from "./dmoz-client.ts";
import type { Religion } from "./dmoz-protocol.gen.ts";
import { onnxRuntime } from "./onnx-runtime.ts";

export const NER_MODEL_REPO = "Xenova/bert-base-NER";
export const NER_MODEL_REVISION = "8e892123e8b7c2c0c2bd1dcb598b7d244c4e53aa";
export const NER_MODEL_FILES: Record<string, string> = {
  "onnx/model_quantized.onnx":
    "caaee70a5518ec7f9e46e5308fcc9263a8c227703a9ce46cf61c69a552349648",
  "tokenizer.json":
    "343989712a36cd8b253efeaf8baf6a08b9d2583f78e395e83832e8ee9f8d8ee1",
  "tokenizer_config.json":
    "5be1a180e9badb4811a6c31502d70fb35a085af5457982937419c42d7530bae6",
  "config.json":
    "a73a2eccc921bbdea95a94b49a157d3694b5c2abbae7a6f3000e14404a9c31a8",
};
export const NER_MODEL_DIR = Deno.env.get("NER_MODEL_DIR") ??
  "data/models/bert-base-NER";
const ENTITY_DATA_DIR = Deno.env.get("ENTITY_DATA_DIR") ?? "lib/data";
export const COUNTRY_NAME_WEIGHT = 1e10;

const NER_MAX_TOKENS = 256;
const MAX_NGRAM = 4;
const MAX_COUNTRIES = 8;
const MIN_LONE_PLACE_WEIGHT = 1e5;
const AMBIGUITY_RATIO = 0.5;
const SPECIAL_TOKENS = new Set(["[CLS]", "[SEP]", "[PAD]"]);
const WORD = /[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'.-]*/g;
const STATE_AFTER_COMMA = /,\s*([A-Z]{2})\b/g;
const RELIGION_WORD = /[A-Za-z']+/g;
const ATTACHED_GAP = /^\S?$/;
const ABBREVIATION = /^\p{Lu}\p{L}{0,2}\.?$/u;
const AFTER_ABBREVIATION_GAP = /^\.?\s$/;
const LEADING_PUNCTUATION = /^[^\p{L}\p{N}]+/u;
const TWO_LETTERS = /\p{L}.*\p{L}/su;
const LETTER = /\p{L}/u;
const RELIGIOUS_FIGURES = new Set([
  "jesus",
  "christ",
  "allah",
  "krishna",
  "shiva",
  "vishnu",
]);

const RELIGION_NAMES: Record<Religion, string> = {
  islam: "islam islamic muslim muslims",
  christianity: "christian christians christianity",
  judaism: "jewish judaism jews",
  hinduism: "hindu hindus hinduism",
  buddhism: "buddhism buddhist buddhists",
  sikhism: "sikh sikhs sikhism",
  taoism: "taoism taoist daoism daoist",
  jainism: "jains jainism",
  bahai: "bahai baha'i",
  shinto: "shinto",
  paganism: "pagan pagans paganism",
};
const RELIGION_RELATED_TERMS: Partial<Record<Religion, string>> = {
  islam:
    "mosque mosques quran koran sufi sufism sufis halal imam hadith ramadan sharia madrasa allah",
  christianity:
    "church churches catholic catholics protestant baptist methodist lutheran presbyterian anglican episcopal bible biblical gospel jesus christ pope bishop archbishop diocese archdiocese parish priest pastor evangelical pentecostal nazarene seminary sermons sermon ecclesiastical jesuit benedictine franciscan liturgy testament epistle apostle rosary eucharist sacrament sacraments baptism congregational theology theologian monastery nuns",
  judaism:
    "synagogue torah talmud rabbi rebbe hasidic chassidic chasidic kosher rosh hashana hashanah yom kippur passover tanakh kabbalah",
  hinduism: "vedic vedas krishna shiva vishnu bhagavad",
  buddhism: "dharma sangha theravada mahayana zen vipassana nichiren",
  sikhism: "gurdwara",
  paganism: "wicca wiccan druidry",
};

function termReligions(
  terms: Partial<Record<Religion, string>>,
): Array<[string, Religion]> {
  return (Object.entries(terms) as Array<[Religion, string]>).flatMap((
    [religion, words],
  ) => words.split(" ").map((word) => [word, religion] as [string, Religion]));
}

const RELIGION_NAMED = new Map(termReligions(RELIGION_NAMES));
const TERM_RELIGION = new Map([
  ...RELIGION_NAMED,
  ...termReligions(RELIGION_RELATED_TERMS),
]);

const DEMONYMS = new Map<string, string>(Object.entries({
  Afghan: "AF",
  Albanian: "AL",
  Algerian: "DZ",
  American: "US",
  Argentine: "AR",
  Argentinian: "AR",
  Armenian: "AM",
  Australian: "AU",
  Austrian: "AT",
  Bangladeshi: "BD",
  Belgian: "BE",
  Bolivian: "BO",
  Brazilian: "BR",
  British: "GB",
  Bulgarian: "BG",
  Cambodian: "KH",
  Canadian: "CA",
  Chilean: "CL",
  Chinese: "CN",
  Colombian: "CO",
  Croatian: "HR",
  Cuban: "CU",
  Czech: "CZ",
  Danish: "DK",
  Dutch: "NL",
  Egyptian: "EG",
  English: "GB",
  Estonian: "EE",
  Ethiopian: "ET",
  Filipino: "PH",
  Finnish: "FI",
  Flemish: "BE",
  French: "FR",
  German: "DE",
  Ghanaian: "GH",
  Greek: "GR",
  Hungarian: "HU",
  Icelandic: "IS",
  Indian: "IN",
  Indonesian: "ID",
  Iranian: "IR",
  Iraqi: "IQ",
  Irish: "IE",
  Israeli: "IL",
  Italian: "IT",
  Jamaican: "JM",
  Japanese: "JP",
  Jordanian: "JO",
  Kenyan: "KE",
  Korean: "KR",
  Latvian: "LV",
  Lebanese: "LB",
  Lithuanian: "LT",
  Malaysian: "MY",
  Maltese: "MT",
  Mexican: "MX",
  Mongolian: "MN",
  Moroccan: "MA",
  Nepalese: "NP",
  Nigerian: "NG",
  Norwegian: "NO",
  Pakistani: "PK",
  Palestinian: "PS",
  Peruvian: "PE",
  Pinoy: "PH",
  Pinay: "PH",
  Polish: "PL",
  Portuguese: "PT",
  Romanian: "RO",
  Russian: "RU",
  Saudi: "SA",
  Scottish: "GB",
  Serbian: "RS",
  Singaporean: "SG",
  Slovak: "SK",
  Slovenian: "SI",
  Spanish: "ES",
  Swedish: "SE",
  Swiss: "CH",
  Syrian: "SY",
  Taiwanese: "TW",
  Thai: "TH",
  Turkish: "TR",
  Ukrainian: "UA",
  Venezuelan: "VE",
  Vietnamese: "VN",
  Welsh: "GB",
}));
const LANGUAGE_CONTEXT_BEFORE = new Set(["in", "into"]);
const LANGUAGE_CONTEXT_AFTER = new Set([
  "text",
  "texts",
  "version",
  "translation",
  "translations",
  "language",
  "languages",
  "subtitles",
  "type",
  "style",
  "revival",
  "rite",
]);
const US_STATES = new Set(
  "AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC"
    .split(" "),
);
const CA_PROVINCES = new Set(
  "AB BC MB NB NL NS NT NU ON PE QC SK YT".split(" "),
);
const CAPITALISED_STOPWORDS = new Set(
  "The A An And Of In On For With From By To At Includes Offers Features Provides Information Official Home Page Online Contact News Services Union Liberty Independence Victoria Reading Mobile Bath Nice Hope Orange Florence Phoenix Normal March Commerce Enterprise Paradise Mission Dream Fever Trinity Mesa Rochester Lincoln Washington Jackson Columbus Franklin Clinton"
    .split(" "),
);
const CONNECTORS = new Set(
  "of de la le du del da am an im upon sur on".split(" "),
);

type Kind = "PER" | "ORG" | "LOC" | "MISC";
interface Span {
  kind: Kind;
  start: number;
  end: number;
}
type Weights = Map<string, number>;

interface Resources {
  tokenizer: Tokenizer;
  run: (ids: number[]) => Promise<number[]>;
  labels: string[];
  gazetteer: Map<string, Weights>;
  common: Set<string>;
}

export interface QueryVocabulary {
  countryOf(phrase: string): string | undefined;
  religionOf(word: string): Religion | undefined;
  isCommon(word: string): boolean;
}

let loading: Promise<Resources> | undefined;
let places: Promise<Map<string, Weights>> | undefined;
let commonWords: Promise<Set<string>> | undefined;
let vocabulary: Promise<QueryVocabulary> | undefined;

function common(): Promise<Set<string>> {
  commonWords ??= Deno.readTextFile(`${ENTITY_DATA_DIR}/common-words.txt`)
    .then((text) => new Set(text.split("\n")));
  return commonWords;
}

function gazetteer(): Promise<Map<string, Weights>> {
  places ??= Deno.readTextFile(`${ENTITY_DATA_DIR}/gazetteer.tsv`).then(
    parseGazetteer,
  );
  return places;
}

function countryNames(
  gazetteer: Map<string, Weights>,
): Array<[string, string]> {
  return [...gazetteer].flatMap(([name, weights]) => {
    const named = [...weights].filter(([, weight]) =>
      weight >= COUNTRY_NAME_WEIGHT
    );
    return named.length === 1 ? [[name, named[0][0]] as [string, string]] : [];
  });
}

export function queryVocabulary(): Promise<QueryVocabulary> {
  vocabulary ??= Promise.all([gazetteer(), common()]).then(
    ([places, words]) => {
      const countries = new Map([
        ...countryNames(places),
        ...[...DEMONYMS].map(([word, code]) =>
          [foldPlaceName(word), code] as [string, string]
        ),
      ]);
      return {
        countryOf: (phrase) => countries.get(foldPlaceName(phrase)),
        religionOf: (word) => RELIGION_NAMED.get(word.toLowerCase()),
        isCommon: (word) => words.has(word.toLowerCase()),
      };
    },
  );
  return vocabulary;
}

function resources(): Promise<Resources> {
  loading ??= loadResources().catch((e) => {
    console.error("entity extractor unavailable:", e);
    throw e;
  });
  return loading;
}

async function loadResources(): Promise<Resources> {
  const ort = await onnxRuntime();
  const readJson = async (file: string) =>
    JSON.parse(await Deno.readTextFile(`${NER_MODEL_DIR}/${file}`));
  const config = await readJson("config.json");
  const session = await ort.InferenceSession.create(
    await Deno.readFile(`${NER_MODEL_DIR}/onnx/model_quantized.onnx`),
    { intraOpNumThreads: 1, interOpNumThreads: 1 },
  );
  const labelCount = Object.keys(config.id2label).length;

  const run = async (ids: number[]) => {
    const shape = [1, ids.length];
    const out = await session.run({
      input_ids: new ort.Tensor(
        "int64",
        BigInt64Array.from(ids, BigInt),
        shape,
      ),
      attention_mask: new ort.Tensor(
        "int64",
        new BigInt64Array(ids.length).fill(1n),
        shape,
      ),
      token_type_ids: new ort.Tensor(
        "int64",
        new BigInt64Array(ids.length),
        shape,
      ),
    });
    const logits = out.logits.data as Float32Array;
    return ids.map((_, t) => {
      const row = logits.subarray(t * labelCount, (t + 1) * labelCount);
      return row.indexOf(Math.max(...row));
    });
  };

  return {
    tokenizer: new Tokenizer(
      await readJson("tokenizer.json"),
      await readJson("tokenizer_config.json"),
    ),
    run,
    labels: Array.from({ length: labelCount }, (_, i) => config.id2label[i]),
    gazetteer: await gazetteer(),
    common: await common(),
  };
}

function parseGazetteer(tsv: string): Map<string, Weights> {
  const gazetteer = new Map<string, Weights>();
  for (const line of tsv.split("\n")) {
    const [name, entries] = line.split("\t");
    if (!entries) continue;
    gazetteer.set(
      name,
      new Map(
        entries.split(",").map((entry) => {
          const [country, weight] = entry.split(":");
          return [country, Number(weight)];
        }),
      ),
    );
  }
  return gazetteer;
}

export function foldPlaceName(name: string): string {
  return name.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase()
    .replace(/^[\s.,'-]+|[\s.,'-]+$/g, "");
}

function tokenOffsets(
  text: string,
  tokens: string[],
): Array<[number, number] | null> {
  let cursor = 0;
  return tokens.map((token) => {
    if (SPECIAL_TOKENS.has(token)) return null;
    if (token === "[UNK]") {
      const start = text.slice(cursor).search(/\S/) + cursor;
      cursor = start + 1;
      return [start, cursor];
    }
    const piece = token.startsWith("##") ? token.slice(2) : token;
    const start = text.indexOf(piece, cursor);
    if (start < 0) return null;
    cursor = start + piece.length;
    return [start, cursor];
  });
}

async function nerSpans(r: Resources, text: string): Promise<Span[]> {
  const encoded = r.tokenizer.encode(text);
  const keep = Math.min(encoded.ids.length, NER_MAX_TOKENS) - 1;
  const ids = [...encoded.ids.slice(0, keep), encoded.ids.at(-1)!];
  const tokens = [...encoded.tokens.slice(0, keep), encoded.tokens.at(-1)!];
  const offsets = tokenOffsets(text, tokens);
  const labels = await r.run(ids);

  const found: Span[] = [];
  let current: Span | null = null;
  tokens.forEach((token, t) => {
    const offset = offsets[t];
    if (!offset) {
      current = null;
      return;
    }
    if (token.startsWith("##") && current) {
      current.end = offset[1];
      return;
    }
    const label = r.labels[labels[t]];
    if (label === "O") {
      current = null;
      return;
    }
    const kind = label.slice(2) as Kind;
    if (current && current.kind === kind && label.startsWith("I-")) {
      current.end = offset[1];
      return;
    }
    current = { kind, start: offset[0], end: offset[1] };
    found.push(current);
  });
  return mergeSpans(text, found);
}

function continues(text: string, left: Span, right: Span): boolean {
  if (left.kind !== right.kind || left.kind === "LOC") return false;
  const gap = text.slice(left.end, right.start);
  if (ATTACHED_GAP.test(gap)) return true;
  return ABBREVIATION.test(text.slice(left.start, left.end)) &&
    AFTER_ABBREVIATION_GAP.test(gap);
}

function mergeSpans(text: string, spans: Span[]): Span[] {
  const merged: Span[] = [];
  const worded = spans.filter((s) => LETTER.test(text.slice(s.start, s.end)));
  for (const span of worded) {
    const last = merged.at(-1);
    if (last && continues(text, last, span)) last.end = span.end;
    else merged.push(span);
  }
  return merged;
}

function isCapitalised(word: string): boolean {
  const first = word[0];
  return first !== first.toLowerCase() && first === first.toUpperCase();
}

function capitalisedPlaces(
  r: Resources,
  text: string,
  people: Span[],
): string[] {
  const words = [...text.matchAll(WORD)].map((m) => ({
    word: m[0],
    start: m.index,
    end: m.index + m[0].length,
  }));
  const places: string[] = [];
  let i = 0;
  while (i < words.length) {
    let matched = 0;
    for (let n = MAX_NGRAM; n >= 1; n--) {
      const chunk = words.slice(i, i + n);
      if (chunk.length < n) continue;
      const parts = chunk.map((w) => w.word);
      if (!isCapitalised(parts[0]) || !isCapitalised(parts[n - 1])) continue;
      if (parts.some((w) => !isCapitalised(w) && !CONNECTORS.has(w))) continue;
      const span = parts.join(" ");
      if (
        n === 1 &&
        (CAPITALISED_STOPWORDS.has(span) || r.common.has(foldPlaceName(span)))
      ) continue;
      const start = chunk[0].start;
      const end = chunk[n - 1].end;
      if (within(people, start, end)) continue;
      const weights = r.gazetteer.get(foldPlaceName(span));
      if (!weights) continue;
      if (n > 1 || Math.max(...weights.values()) >= MIN_LONE_PLACE_WEIGHT) {
        places.push(span);
      }
      matched = n;
      break;
    }
    i += matched || 1;
  }
  return places;
}

function resolve(weights: Weights, context: Set<string>): string | null {
  const inContext = [...weights].filter(([country]) => context.has(country));
  const ranked = (inContext.length ? inContext : [...weights]).sort((a, b) =>
    b[1] - a[1]
  );
  if (ranked.length > 1 && ranked[1][1] >= AMBIGUITY_RATIO * ranked[0][1]) {
    return null;
  }
  return ranked[0]?.[0] ?? null;
}

function resolvePlaces(r: Resources, names: string[]): Set<string> {
  const unambiguous = new Set<string>();
  for (const name of names) {
    const weights = r.gazetteer.get(foldPlaceName(name));
    if (weights?.size === 1) unambiguous.add([...weights.keys()][0]);
  }
  const resolved = new Set<string>();
  for (const name of names) {
    const parts = [
      name,
      ...name.split(",").map((p) => p.trim()).filter(Boolean),
    ];
    for (const part of parts) {
      const weights = r.gazetteer.get(foldPlaceName(part));
      const country = weights && resolve(weights, unambiguous);
      if (country) {
        resolved.add(country);
        break;
      }
    }
  }
  return resolved;
}

function stateCountries(text: string): string[] {
  return [...text.matchAll(STATE_AFTER_COMMA)].flatMap(([, code]) =>
    US_STATES.has(code) ? ["US"] : CA_PROVINCES.has(code) ? ["CA"] : []
  );
}

function demonymCountries(text: string, locations: Span[]): string[] {
  const matches = [...text.matchAll(WORD)];
  const words = matches.map((m) => m[0]);
  const bare = words.map((w) => w.replace(/[.,]+$/, ""));
  return bare.flatMap((word, i) => {
    const code = DEMONYMS.get(word);
    if (!code) return [];
    const start = matches[i].index;
    if (insideLongerPlace(locations, start, start + word.length)) return [];
    const before = (words[i - 1] ?? "").toLowerCase();
    const after = (bare[i + 1] ?? "").toLowerCase();
    if (LANGUAGE_CONTEXT_BEFORE.has(before)) return [];
    if (LANGUAGE_CONTEXT_AFTER.has(after)) return [];
    const neighbours = bare.slice(Math.max(0, i - 3), i + 4).filter((_, j) =>
      j !== Math.min(i, 3)
    );
    return neighbours.some((w) => DEMONYMS.has(w)) ? [] : [code];
  });
}

function within(spans: Span[], start: number, end: number): boolean {
  return spans.some((s) => s.start <= start && end <= s.end);
}

function insideLongerPlace(
  locations: Span[],
  start: number,
  end: number,
): boolean {
  return locations.some((l) =>
    l.start <= start && end <= l.end && l.end - l.start > end - start
  );
}

function religionsIn(text: string, people: Span[]): Religion[] {
  const evidence = [...text.matchAll(RELIGION_WORD)].flatMap((m) => {
    const word = m[0].toLowerCase();
    const partOfAPersonName = within(people, m.index, m.index + m[0].length);
    return partOfAPersonName && !RELIGIOUS_FIGURES.has(word) ? [] : [word];
  });
  return [
    ...new Set(evidence.flatMap((word) => TERM_RELIGION.get(word) ?? [])),
  ];
}

function names(text: string, spans: Span[], kind: Kind): string[] {
  const encoder = new TextEncoder();
  const unique = new Set(
    spans.filter((s) => s.kind === kind).map((s) =>
      text.slice(s.start, s.end).trim().replace(LEADING_PUNCTUATION, "")
    ).filter((name) =>
      TWO_LETTERS.test(name) &&
      encoder.encode(name).length <= MAX_ENTITY_NAME_BYTES
    ),
  );
  return [...unique].slice(0, MAX_ENTITY_NAMES);
}

export async function extractEntities(
  title: string,
  description: string,
): Promise<LinkEntities> {
  const r = await resources();
  const text = `${title}. ${description}`;
  const spans = await nerSpans(r, text);
  const people = spans.filter((s) => s.kind === "PER");
  const locations = spans.filter((s) => s.kind === "LOC");

  const places = [
    ...locations.map((s) => text.slice(s.start, s.end)),
    ...capitalisedPlaces(r, text, people),
  ];
  const countries = new Set([
    ...resolvePlaces(r, places),
    ...stateCountries(text),
    ...demonymCountries(text, locations),
  ]);

  return {
    religions: religionsIn(text, people),
    countries: [...countries].sort().slice(0, MAX_COUNTRIES),
    people: names(text, spans, "PER"),
    orgs: names(text, spans, "ORG"),
  };
}

export async function storeLinkEntities(
  client: DmozClient,
  linkId: number,
): Promise<void> {
  try {
    const link = await client.getLink(linkId);
    const entities = await extractEntities(link.title, link.description);
    const [result] = await client.putLinkEntities([{
      linkId,
      textFingerprint: linkTextFingerprint(link.title, link.description),
      entities,
    }]);
    if (result.code !== "ok") {
      console.error(`storeLinkEntities ${linkId}: ${result.code}`);
    }
  } catch (e) {
    console.error(`storeLinkEntities ${linkId}: no entity facts:`, e);
  }
}
