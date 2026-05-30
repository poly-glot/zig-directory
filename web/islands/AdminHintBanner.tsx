import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import styles from "./AdminHintBanner.module.css";

interface Props {
  id: string;
  message: string;
}

/**
 * Dismissable first-visit hint. Dismissal persists per-browser via
 * localStorage (`admin_hint_<id>`) — cheap, no server round-trip. Renders
 * nothing once dismissed. SSR renders the banner; the island hides it on
 * mount if already dismissed (so it never flashes for returning users
 * beyond the initial paint).
 */
export default function AdminHintBanner({ id, message }: Props) {
  const dismissed = useSignal(false);
  useEffect(() => {
    try {
      if (localStorage.getItem(`admin_hint_${id}`) === "1") {
        dismissed.value = true;
      }
    } catch { /* ignore */ }
  }, []);
  if (dismissed.value) return null;
  return (
    <div class={`${styles.hint} admin-hint`}>
      <span>{message}</span>
      <button
        type="button"
        class={styles.close}
        aria-label="Dismiss"
        onClick={() => {
          try {
            localStorage.setItem(`admin_hint_${id}`, "1");
          } catch { /* ignore */ }
          dismissed.value = true;
        }}
      >
        ×
      </button>
    </div>
  );
}
