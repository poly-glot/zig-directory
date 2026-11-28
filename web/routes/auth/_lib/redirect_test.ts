import { assertEquals } from "jsr:@std/assert@^1";
import { safeRedirect } from "./redirect.ts";

Deno.test("same-origin paths survive the login redirect", () => {
  assertEquals(safeRedirect("/admin"), "/admin");
  assertEquals(
    safeRedirect("/auth/oauth/authorize?client_id=a&state=b"),
    "/auth/oauth/authorize?client_id=a&state=b",
  );
  assertEquals(safeRedirect(null), "/");
  assertEquals(safeRedirect(""), "/");
  assertEquals(safeRedirect("/a/../ok?x=1#h"), "/ok?x=1#h");
});

Deno.test("anything a browser could read as another host falls back to /", () => {
  assertEquals(safeRedirect("//evil.example/x"), "/");
  assertEquals(safeRedirect("/\\evil.example/x"), "/");
  assertEquals(safeRedirect("/\t/evil.example/x"), "/");
  assertEquals(safeRedirect("/\n/evil.example/x"), "/");
  assertEquals(safeRedirect("/\r\n/evil.example/x"), "/");
  assertEquals(safeRedirect("https://evil.example/x"), "/");
  assertEquals(safeRedirect("evil.example"), "/");
  assertEquals(safeRedirect("/.//evil.example/x"), "/");
  assertEquals(safeRedirect("/a/..//evil.example"), "/");
  assertEquals(safeRedirect("/..//evil.example"), "/");
  assertEquals(safeRedirect("/a/%2e%2e//evil.example"), "/");
});
