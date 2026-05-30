import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import styles from "./RecentQueries.module.css";

const STORAGE_KEY = "dmoz_recent_q";
const MAX = 5;

function readStored(): string[] {
  try {
    const raw = globalThis.localStorage?.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((s): s is string => typeof s === "string").slice(
      0,
      MAX,
    );
  } catch {
    return [];
  }
}

function writeStored(items: string[]): void {
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(items));
  } catch {
    // localStorage may be unavailable (privacy mode); silently ignore.
  }
}

function dedupePrepend(items: string[], q: string): string[] {
  const cleaned = [q, ...items.filter((i) => i !== q)];
  return cleaned.slice(0, MAX);
}

function readCurrentQ(): string {
  try {
    const params = new URLSearchParams(globalThis.location?.search ?? "");
    return params.get("q")?.trim() ?? "";
  } catch {
    return "";
  }
}

export default function RecentQueries() {
  const items = useSignal<string[]>([]);

  useEffect(() => {
    const existing = readStored();
    const current = readCurrentQ();
    const next = current ? dedupePrepend(existing, current) : existing;
    items.value = next;
    if (current) writeStored(next);
  }, []);

  if (items.value.length === 0) return null;

  return (
    <div class={styles.row}>
      <span class={styles.label}>Recent</span>
      {items.value.map((q) => (
        <a
          key={q}
          class={styles.chip}
          href={`/search?q=${encodeURIComponent(q)}`}
        >
          {q}
        </a>
      ))}
    </div>
  );
}
