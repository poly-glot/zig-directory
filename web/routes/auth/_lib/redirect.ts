const SAME_ORIGIN_BASE = "http://same-origin.invalid";

function isUnsafeRedirectCharacter(character: string): boolean {
  const code = character.charCodeAt(0);
  return character === "\\" || code < 0x20 || code === 0x7f;
}

export function safeRedirect(raw: string | null): string {
  if (!raw || !raw.startsWith("/")) return "/";
  if ([...raw].some(isUnsafeRedirectCharacter)) return "/";

  const target = URL.parse(raw, SAME_ORIGIN_BASE);
  if (target?.origin !== SAME_ORIGIN_BASE) return "/";

  const path = target.pathname + target.search + target.hash;
  return path.startsWith("//") ? "/" : path;
}
