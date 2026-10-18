import { COUNTRY_NAME_WEIGHT, foldPlaceName } from "../lib/entities.ts";

const REGION_WEIGHT = 1e9;
const COMMON_WORD_MIN = 25;

const [geonamesDir, countriesTsv, linksJsonl] = Deno.args;
if (!geonamesDir || !countriesTsv || !linksJsonl) {
  console.error(
    "usage: build-entity-data.ts <geonames dir> <countries.tsv> <links.jsonl>",
  );
  Deno.exit(1);
}
const outDir = new URL("../lib/data/", import.meta.url);

const places = new Map<string, Map<string, number>>();
const countryRows = lines(countriesTsv).map((line) => line.split("\t"));
const assignedCodes = new Set(countryRows.map(([code]) => code));

function add(name: string, country: string, weight: number): void {
  const key = foldPlaceName(name);
  if (!key || !assignedCodes.has(country)) return;
  const weights = places.get(key) ?? new Map<string, number>();
  weights.set(country, Math.max(weight, weights.get(country) ?? 0));
  places.set(key, weights);
}

function lines(path: string): string[] {
  return Deno.readTextFileSync(path).split("\n").filter((line) => line);
}

for (const [code, name] of countryRows) {
  add(name, code, COUNTRY_NAME_WEIGHT);
}
for (const line of lines(`${geonamesDir}/admin1CodesASCII.txt`)) {
  const [key, name, asciiName] = line.split("\t");
  const country = key.split(".")[0];
  add(name, country, REGION_WEIGHT);
  add(asciiName, country, REGION_WEIGHT);
}
for (const line of lines(`${geonamesDir}/cities15000.txt`)) {
  const cols = line.split("\t");
  const population = Number(cols[14] || 0);
  add(cols[1], cols[8], population);
  add(cols[2], cols[8], population);
}

const gazetteer = [...places.entries()]
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([name, weights]) =>
    `${name}\t${
      [...weights.entries()].map(([c, w]) => `${c}:${Math.round(w)}`).join(",")
    }`
  );

const counts = new Map<string, number>();
for (const line of lines(linksJsonl)) {
  const link = JSON.parse(line);
  const text = `${link.title} ${link.description}`;
  for (const word of text.match(/\b[a-z][a-z'-]+\b/g) ?? []) {
    counts.set(word, (counts.get(word) ?? 0) + 1);
  }
}
const common = [...counts.entries()]
  .filter(([, n]) => n >= COMMON_WORD_MIN)
  .map(([word]) => word)
  .sort();

await Deno.mkdir(outDir, { recursive: true });
await Deno.writeTextFile(
  new URL("gazetteer.tsv", outDir),
  gazetteer.join("\n") + "\n",
);
await Deno.writeTextFile(
  new URL("common-words.txt", outDir),
  common.join("\n") + "\n",
);
console.log(
  JSON.stringify({ places: gazetteer.length, commonWords: common.length }),
);
