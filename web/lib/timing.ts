export interface Stopwatch {
  time<T>(stage: string, work: () => Promise<T>): Promise<T>;
  stages(): Record<string, number>;
  totalMs(): number;
  serverTiming(): string;
}

export type SearchPath = "targeted" | "ranked" | "api";

export interface SearchLogEntry {
  query: string;
  path: SearchPath;
  links: number;
  categories: number;
  watch: Stopwatch;
}

export function stopwatch(): Stopwatch {
  const started = performance.now();
  const elapsed = new Map<string, number>();

  return {
    async time(stage, work) {
      const stageStarted = performance.now();
      try {
        return await work();
      } finally {
        const spent = performance.now() - stageStarted;
        elapsed.set(stage, (elapsed.get(stage) ?? 0) + spent);
      }
    },

    stages() {
      return Object.fromEntries(
        [...elapsed].map(([stage, ms]) => [stage, Math.round(ms)]),
      );
    },

    totalMs() {
      return Math.round(performance.now() - started);
    },

    serverTiming() {
      return [...elapsed, ["total", performance.now() - started] as const]
        .map(([stage, ms]) => `${stage};dur=${ms.toFixed(1)}`)
        .join(", ");
    },
  };
}

export function logSearch(entry: SearchLogEntry): void {
  console.log(JSON.stringify({
    search: entry.query,
    path: entry.path,
    links: entry.links,
    categories: entry.categories,
    ms: entry.watch.totalMs(),
    stages: entry.watch.stages(),
  }));
}
