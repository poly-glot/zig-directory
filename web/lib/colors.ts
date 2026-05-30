/** Deterministic pastel background + text color pairs for company logo placeholders. */

export interface LogoPalette {
  bg: string;
  text: string;
}

const LOGO_PALETTES: LogoPalette[] = [
  { bg: "#F0FDF4", text: "#10B981" }, // green pastel
  { bg: "#F5F3FF", text: "#8B5CF6" }, // purple pastel
  { bg: "#FFFBEB", text: "#D97706" }, // amber pastel
  { bg: "#F9FAFB", text: "#1F2937" }, // gray
  { bg: "#FEF2F2", text: "#EF4444" }, // red pastel
  { bg: "#F0F9FF", text: "#0284C7" }, // blue pastel
  { bg: "#F3F4F6", text: "#374151" }, // dark gray
  { bg: "#111827", text: "#FFFFFF" }, // dark/inverted
];

export function logoColor(title: string): LogoPalette {
  const hash = [...title].reduce(
    (h, c) => (h * 37 + c.charCodeAt(0)) | 0,
    0,
  );
  return LOGO_PALETTES[Math.abs(hash) % LOGO_PALETTES.length];
}

/** Generate smart initials from a company name using word-initial letters. */
export function getInitials(name: string): string {
  const words = name.split(/\s+/).filter((w) => w.length > 0);
  if (words.length === 1) return words[0].substring(0, 2).toUpperCase();
  return words.map((w) => w[0]).join("").substring(0, 4).toUpperCase();
}
