import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import styles from "./DensityToggle.module.css";

type Density = "balanced" | "dense" | "spacious";

const STORAGE_KEY = "dmoz_density";
// Density classes still apply globally to <html> so any descendant can read
// `--row-pad`. They live in assets/base.css as :global rules.
const CLASS_PREFIX = "density-";
const OPTIONS: { id: Density; label: string }[] = [
  { id: "balanced", label: "Balanced" },
  { id: "dense", label: "Dense" },
  { id: "spacious", label: "Spacious" },
];

function readStored(): Density {
  try {
    const raw = globalThis.localStorage?.getItem(STORAGE_KEY);
    if (raw === "dense" || raw === "spacious" || raw === "balanced") return raw;
  } catch {
    // localStorage may be unavailable.
  }
  return "balanced";
}

function applyClass(d: Density) {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  for (const opt of OPTIONS) root.classList.remove(CLASS_PREFIX + opt.id);
  root.classList.add(CLASS_PREFIX + d);
}

export default function DensityToggle() {
  const density = useSignal<Density>("balanced");

  useEffect(() => {
    const stored = readStored();
    density.value = stored;
    applyClass(stored);
  }, []);

  const set = (d: Density) => {
    density.value = d;
    applyClass(d);
    try {
      globalThis.localStorage?.setItem(STORAGE_KEY, d);
    } catch {
      // ignore
    }
  };

  return (
    <div class={styles.seg} role="group" aria-label="Row density">
      {OPTIONS.map((opt) => (
        <button
          key={opt.id}
          type="button"
          class={density.value === opt.id
            ? `${styles.btn} ${styles.active}`
            : styles.btn}
          onClick={() => set(opt.id)}
        >
          {opt.label}
        </button>
      ))}
    </div>
  );
}
