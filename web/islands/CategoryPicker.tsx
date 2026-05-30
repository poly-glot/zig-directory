import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import styles from "./CategoryPicker.module.css";

interface Result {
  id: number;
  name: string;
  slug: string;
  parentId: number;
  /** "Top / Arts / Music" — root→…→parent, empty for top-level. */
  breadcrumb: string;
}

interface Props {
  /** Form field name for the selected category ID. */
  name: string;
  /** Pre-selected category ID (0 = none). */
  initialId?: number;
  /** Display label for the pre-selected category. */
  initialLabel?: string;
  /** Required for form validation. */
  required?: boolean;
  /** Auto-submit the enclosing form when a result is picked. */
  submitOnSelect?: boolean;
  placeholder?: string;
  inputId?: string;
}

export default function CategoryPicker({
  name,
  initialId = 0,
  initialLabel = "",
  required = false,
  submitOnSelect = false,
  placeholder = "Search categories…",
  inputId,
}: Props) {
  const query = useSignal(initialLabel);
  const selectedId = useSignal(initialId);
  const selectedLabel = useSignal(initialLabel);
  const results = useSignal<Result[]>([]);
  const open = useSignal(false);
  const loading = useSignal(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const hiddenRef = useRef<HTMLSelectElement>(null);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) open.value = false;
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, []);

  let debounce = 0;
  const onInput = (e: Event) => {
    const v = (e.target as HTMLInputElement).value;
    query.value = v;
    if (selectedId.value && v !== selectedLabel.value) {
      selectedId.value = 0;
      selectedLabel.value = "";
    }
    clearTimeout(debounce);
    if (v.trim().length < 2) {
      results.value = [];
      open.value = false;
      return;
    }
    debounce = setTimeout(async () => {
      loading.value = true;
      try {
        const resp = await fetch(
          `/admin/api/category-search?q=${encodeURIComponent(v.trim())}`,
        );
        const data = await resp.json();
        results.value = data.categories ?? [];
        open.value = true;
      } catch {
        results.value = [];
      } finally {
        loading.value = false;
      }
    }, 200);
  };

  const pick = (r: Result) => {
    selectedId.value = r.id;
    const label = `${r.name} (#${r.id})`;
    selectedLabel.value = label;
    query.value = label;
    open.value = false;
    if (submitOnSelect) {
      queueMicrotask(() => hiddenRef.current?.form?.submit());
    }
  };

  const clear = () => {
    selectedId.value = 0;
    selectedLabel.value = "";
    query.value = "";
    results.value = [];
  };

  return (
    <div class={styles.wrap} ref={wrapRef}>
      <input
        type="text"
        id={inputId}
        class={`input ${styles.input}`}
        value={query.value}
        onInput={onInput}
        onFocus={(e) => {
          // Select-all so any keystroke replaces the prefilled label.
          (e.currentTarget as HTMLInputElement).select();
          open.value = true;
        }}
        placeholder={placeholder}
        autocomplete="off"
      />
      <select
        name={name}
        ref={hiddenRef}
        required={required}
        class={styles.hiddenField}
        tabindex={-1}
        aria-hidden="true"
      >
        {selectedId.value > 0
          ? (
            <option value={String(selectedId.value)} selected>
              {selectedLabel.value}
            </option>
          )
          : <option value="" selected />}
      </select>
      {open.value && (
        <ul class={styles.results}>
          {loading.value && <li class={styles.empty}>Searching…</li>}
          {!loading.value && results.value.length === 0 &&
            query.value.trim().length < 2 && (
            <li class={styles.empty}>
              Type at least 2 characters to search.
            </li>
          )}
          {!loading.value && results.value.length === 0 &&
            query.value.trim().length >= 2 && (
            <li class={styles.empty}>No matches.</li>
          )}
          {results.value.map((r) => (
            <li key={r.id}>
              <button
                type="button"
                class={styles.item}
                onClick={() => pick(r)}
              >
                {r.name}
                <span class={styles.itemMeta}>
                  {r.breadcrumb || "(root)"}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {selectedId.value > 0 && (
        <div class={styles.selected}>
          Selected: <strong>{selectedLabel.value}</strong>
          <button type="button" class={styles.clear} onClick={clear}>
            clear
          </button>
        </div>
      )}
    </div>
  );
}
