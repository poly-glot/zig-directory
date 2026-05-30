import { useEffect } from "preact/hooks";
import styles from "./Toast.module.css";

export interface ToastMessage {
  id: number;
  message: string;
  variant: "success" | "error" | "info";
}

interface Props {
  messages: ToastMessage[];
  onDismiss: (id: number) => void;
}

const AUTO_DISMISS_MS = 8000;

/** Sticky bottom-right toasts for bulk-op outcomes. Auto-dismiss after 8s;
 *  click to dismiss. Used as a child of AdminBulkBar (same island bundle),
 *  so the function `onDismiss` prop crosses no serialization boundary. */
export default function Toast({ messages, onDismiss }: Props) {
  useEffect(() => {
    const timers = messages.map((m) =>
      globalThis.setTimeout(() => onDismiss(m.id), AUTO_DISMISS_MS)
    );
    return () => {
      for (const t of timers) clearTimeout(t);
    };
  }, [messages]);
  return (
    <div class={`${styles.host} admin-toast-host`} aria-live="polite">
      {messages.map((m) => (
        <div
          key={m.id}
          class={`${styles.toast} ${styles[m.variant]} toast ${m.variant}`}
          onClick={() => onDismiss(m.id)}
          role="status"
        >
          {m.message}
        </div>
      ))}
    </div>
  );
}
