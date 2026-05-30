import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import styles from "./ConfirmModal.module.css";

interface Props {
  open: boolean;
  title: string;
  body: string;
  /** Phrase the user must type to enable the primary button. */
  confirmPhrase?: string;
  primaryLabel: string;
  onCancel: () => void;
  onConfirm: () => void;
}

/**
 * Modal confirm for destructive actions. Backdrop click and Escape cancel.
 * When `confirmPhrase` is set, the primary button stays disabled until the
 * user types it exactly (type-to-confirm).
 */
export default function ConfirmModal(
  { open, title, body, confirmPhrase, primaryLabel, onCancel, onConfirm }:
    Props,
) {
  const typed = useSignal("");

  useEffect(() => {
    if (!open) return;
    typed.value = "";
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onCancel();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open]);

  if (!open) return null;

  const ready = confirmPhrase ? typed.value === confirmPhrase : true;
  return (
    <div
      class={`${styles.backdrop} confirm-modal`}
      role="dialog"
      aria-modal="true"
      aria-label={title}
      onClick={(e) => {
        if (e.target === e.currentTarget) onCancel();
      }}
    >
      <div class={styles.dialog}>
        <h3 class={styles.title}>{title}</h3>
        <p class={styles.body}>{body}</p>
        {confirmPhrase && (
          <input
            class={styles.input}
            type="text"
            placeholder={confirmPhrase}
            value={typed.value}
            onInput={(e) => {
              typed.value = (e.currentTarget as HTMLInputElement).value;
            }}
          />
        )}
        <div class={styles.actions}>
          <button type="button" class="btn ghost" onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            class={`btn ${styles.danger} ${ready ? "" : styles.disabled}`}
            disabled={!ready}
            onClick={onConfirm}
          >
            {primaryLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
