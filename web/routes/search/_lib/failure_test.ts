import { assertEquals, assertStringIncludes } from "jsr:@std/assert@^1";
import { DmozError, Status, SubStatus } from "../../../lib/dmoz-client.ts";
import { searchFailure } from "./failure.ts";

Deno.test("a too-broad refusal becomes a narrow-your-search message, not an error page", () => {
  const refused = new DmozError(
    Status.Invalid,
    SubStatus.TooBroad,
    "dmozdb error: invalid / too broad (status=3 sub=12)",
  );
  const failure = searchFailure(refused);

  assertEquals(failure.status, 400);
  assertStringIncludes(failure.error, "Narrow your search");
  assertEquals(failure.error.includes("dmozdb"), false);
});

Deno.test("any other failure stays a generic unavailable message", () => {
  const quiet = console.error;
  console.error = () => {};
  try {
    const invalid = new DmozError(Status.Invalid, SubStatus.None, "invalid");

    assertEquals(searchFailure(invalid).error, "Search unavailable");
    assertEquals(searchFailure(new Error("boom")).error, "Search unavailable");
  } finally {
    console.error = quiet;
  }
});
