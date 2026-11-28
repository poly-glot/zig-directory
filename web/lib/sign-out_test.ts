import { assertEquals } from "jsr:@std/assert@^1";

const SIGN_OUT_LINK = /<a\b[^>]*href=["']\/auth\/logout["']/;

async function* sourceFiles(directory: string): AsyncGenerator<string> {
  for await (const entry of Deno.readDir(directory)) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory) yield* sourceFiles(path);
    if (entry.isFile && path.endsWith(".tsx")) yield path;
  }
}

Deno.test("no component links to /auth/logout, which a GET cannot sign out of", async () => {
  const linking: string[] = [];

  for (const directory of ["components", "islands", "routes"]) {
    for await (const path of sourceFiles(directory)) {
      if (SIGN_OUT_LINK.test(await Deno.readTextFile(path))) linking.push(path);
    }
  }

  assertEquals(linking, []);
});
