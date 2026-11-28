import { assert, assertEquals } from "jsr:@std/assert@^1";
import { CACHE_ENTRIES_MAX, resolveCimdClient } from "./cimd.ts";

const realResolveDns = Deno.resolveDns;
const realFetch = globalThis.fetch;

function stubNetwork(serve: (url: URL) => Response): string[] {
  const fetched: string[] = [];
  Object.assign(Deno, {
    resolveDns: (_hostname: string, type: string) =>
      Promise.resolve(type === "A" ? ["93.184.215.14"] : []),
  });
  globalThis.fetch = ((input: URL) => {
    fetched.push(String(input));
    return Promise.resolve(serve(new URL(String(input))));
  }) as typeof fetch;
  return fetched;
}

function restoreNetwork(): void {
  Object.assign(Deno, { resolveDns: realResolveDns });
  globalThis.fetch = realFetch;
}

function clientDocument(url: URL): Response {
  return Response.json({
    client_id: url.toString(),
    client_name: "Client",
    redirect_uris: ["https://client.example/cb"],
  });
}

Deno.test("an endless CIMD document stops being read past 64 KiB", async () => {
  const chunk = new Uint8Array(16 * 1024).fill(0x20);
  const unlimitedBytes = 64 * 1024 * 1024;
  let pulledBytes = 0;
  stubNetwork(() =>
    new Response(
      new ReadableStream({
        pull(controller) {
          if (pulledBytes >= unlimitedBytes) return controller.close();
          pulledBytes += chunk.byteLength;
          controller.enqueue(chunk);
        },
      }),
    )
  );

  try {
    assertEquals(
      await resolveCimdClient("https://endless.example/client"),
      null,
    );
    assert(pulledBytes < 256 * 1024, `pulled ${pulledBytes} bytes`);
  } finally {
    restoreNetwork();
  }
});

Deno.test("the CIMD cache holds at most its maximum and evicts the oldest", async () => {
  const fetched = stubNetwork(clientDocument);
  const idOf = (n: number) => `https://cache.example/client/${n}`;

  try {
    for (let n = 0; n <= CACHE_ENTRIES_MAX; n++) {
      assert(await resolveCimdClient(idOf(n)));
    }
    const fetchesAfterFill = fetched.length;

    assert(await resolveCimdClient(idOf(CACHE_ENTRIES_MAX)));
    assertEquals(fetched.length, fetchesAfterFill);

    assert(await resolveCimdClient(idOf(0)));
    assertEquals(fetched.length, fetchesAfterFill + 1);
  } finally {
    restoreNetwork();
  }
});

Deno.test("a CIMD document with a wildcard redirect host is refused", async () => {
  const wildcardHosts = ["https://*.co.uk/cb", "https://*/cb", "app://*/cb"];

  try {
    for (const redirectUri of wildcardHosts) {
      stubNetwork((url) =>
        Response.json({
          client_id: url.toString(),
          redirect_uris: ["https://client.example/cb", redirectUri],
        })
      );
      const clientId = `https://wildcard.example/${
        encodeURIComponent(redirectUri)
      }`;
      assertEquals(await resolveCimdClient(clientId), null, redirectUri);
    }
  } finally {
    restoreNetwork();
  }
});
