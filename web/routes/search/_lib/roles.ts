const ROLE_CATEGORIES: Record<string, readonly string[]> = {
  politicians: [
    "politicians",
    "presidents",
    "vice presidents",
    "prime ministers",
    "mps",
    "ex-senators",
    "chancellors",
  ],
  presidents: ["presidents", "vice presidents"],
  "prime ministers": ["prime ministers"],
  writers: [
    "writers",
    "authors",
    "poets",
    "novelists",
    "playwrights",
    "screenwriters",
    "journalists",
    "historians",
  ],
  authors: ["authors", "novelists"],
  poets: ["poets"],
  novelists: ["novelists"],
  playwrights: ["playwrights"],
  journalists: ["journalists"],
  historians: ["historians"],
  philosophers: ["philosophers", "political philosophers"],
  theologians: ["theologians"],
  composers: ["composers", "authors and composers"],
  musicians: [
    "composers",
    "conductors",
    "pianists",
    "guitarists",
    "saxophonists",
    "bassists",
    "trumpet players",
    "songwriters",
    "sopranos",
    "tenors",
    "baritones",
    "mezzo-sopranos",
    "countertenors",
  ],
  singers: [
    "sopranos",
    "tenors",
    "baritones",
    "mezzo-sopranos",
    "countertenors",
  ],
  pianists: ["pianists"],
  guitarists: ["guitarists"],
  saxophonists: ["saxophonists"],
  conductors: ["conductors"],
  songwriters: ["songwriters"],
  actors: ["actors and actresses", "voice actors"],
  actresses: ["actors and actresses"],
  comedians: ["comedians"],
  magicians: ["magicians"],
  scientists: ["mathematicians", "physicists", "chemists", "astronomers"],
  mathematicians: ["mathematicians"],
  physicists: ["physicists"],
  astronauts: ["astronauts"],
  explorers: ["explorers"],
  painters: ["painters"],
  sculptors: ["sculptors"],
  athletes: ["athletes", "boxers", "gymnasts", "golfers"],
  boxers: ["boxers"],
  gymnasts: ["gymnasts"],
  golfers: ["golfers"],
  chefs: ["chefs"],
};

const SINGULAR_ROLE: Record<string, string> = { actress: "actresses" };

export const ROLE_CUES: ReadonlySet<string> = new Set(
  "biographies biography bios famous notable".split(" "),
);

export function roleOf(phrase: string): string | undefined {
  const folded = phrase.trim().toLowerCase().replace(/\s+/g, " ");
  if (folded === "") return undefined;

  const candidates = [folded, `${folded}s`, SINGULAR_ROLE[folded] ?? ""];
  return candidates.find((candidate) => candidate in ROLE_CATEGORIES);
}

export function roleCategories(role: string): readonly string[] {
  return ROLE_CATEGORIES[role] ?? [];
}
