import { isTooBroad } from "../../../lib/dmoz-client.ts";

export interface SearchFailure {
  error: string;
  status: number;
}

const TOO_BROAD_MESSAGE =
  "Narrow your search: a word in it matches too many links to rank. " +
  "Try rarer words, or add a category or a country.";

export function searchFailure(e: unknown): SearchFailure {
  if (isTooBroad(e)) return { error: TOO_BROAD_MESSAGE, status: 400 };

  console.error("Search failed:", e);
  return { error: "Search unavailable", status: 200 };
}
