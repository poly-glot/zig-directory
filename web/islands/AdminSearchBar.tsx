import type { ComponentChildren } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import styles from "./AdminSearchBar.module.css";

interface Props {
  /** Page-specific placeholder. */
  placeholder: string;
  /** Initial value from the URL (so SSR + island stay in sync). */
  initialQuery: string;
  /** URL param name to write into — usually "q". */
  paramName?: string;
  /** Slot for the right-side CTA (e.g. + New link). */
  rightSlot?: ComponentChildren;
}

const DEBOUNCE_MS = 250;

/**
 * Debounced search box. On a 250 ms idle it writes the query into the URL
 * (coalesced — only when the value actually changed, to avoid history
 * pollution) and reloads, so the server re-renders the table for the query.
 * Live no-reload refetch is documented open debt (spec).
 */
export default function AdminSearchBar(
  { placeholder, initialQuery, paramName = "q", rightSlot }: Props,
) {
  const value = useSignal(initialQuery);
  const timer = useRef<number | null>(null);
  const lastSubmitted = useRef(initialQuery);

  useEffect(() => () => {
    if (timer.current) clearTimeout(timer.current);
  }, []);

  function schedule(next: string) {
    if (timer.current) clearTimeout(timer.current);
    timer.current = globalThis.setTimeout(() => {
      if (next === lastSubmitted.current) return;
      lastSubmitted.current = next;
      const url = new URL(globalThis.location.href);
      if (next.length === 0) url.searchParams.delete(paramName);
      else url.searchParams.set(paramName, next);
      // Reset paginator state on a fresh search.
      url.searchParams.delete("after_id");
      url.searchParams.delete("cursors");
      globalThis.location.href = url.toString();
    }, DEBOUNCE_MS);
  }

  return (
    <div class={`${styles.wrap} admin-search-bar`}>
      <input
        class={styles.input}
        type="search"
        value={value.value}
        placeholder={placeholder}
        aria-label={placeholder}
        onInput={(e) => {
          const v = (e.currentTarget as HTMLInputElement).value;
          value.value = v;
          schedule(v);
        }}
      />
      {rightSlot && <span class={styles.right}>{rightSlot}</span>}
    </div>
  );
}
