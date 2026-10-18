import { assertEquals } from "jsr:@std/assert@^1";
import { extractEntities } from "./entities.ts";

const lines = async (url: URL) =>
  (await Deno.readTextFile(url)).split("\n").filter((line) => line);

Deno.test("every country the gazetteer can name is one dmozdb accepts", async () => {
  const assigned = new Set(
    (await lines(new URL("../../src/facts/countries.tsv", import.meta.url)))
      .map((line) => line.split("\t")[0]),
  );
  const gazetteer = await lines(
    new URL("./data/gazetteer.tsv", import.meta.url),
  );

  const unassigned = gazetteer.flatMap((line) =>
    line.split("\t")[1].split(",").map((weight) => weight.split(":")[0])
  ).filter((code) => !assigned.has(code));

  assertEquals([...new Set(unassigned)], []);
});

Deno.test("a word naming an Object.prototype member is not a nationality", async () => {
  const { countries } = await extractEntities(
    "San Juan Yachts",
    "Washington USA constructor of high-end composite yachts.",
  );

  assertEquals(countries, ["US"]);
});

Deno.test("a name the model splits at a dot or after an abbreviation comes back whole", async () => {
  const site = await extractEntities(
    "Kurokumo.com",
    "General image gallery, Sailor Moon fan fiction, convention reports, and links.",
  );
  const saints = await extractEntities(
    "All about Santa Claus",
    "Historical data about the origins of Santa Claus and St. Nicholas.",
  );

  assertEquals(site.orgs, ["Kurokumo.com"]);
  assertEquals(saints.people, ["Santa Claus", "St. Nicholas"]);
});

Deno.test("a nationality word inside a longer place name is part of the place", async () => {
  const { countries } = await extractEntities(
    "Mockingbird",
    "Located near the British Columbia-Washington border.",
  );

  assertEquals(countries, ["CA", "US"]);
});
