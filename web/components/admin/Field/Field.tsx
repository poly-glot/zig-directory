import type { ComponentChildren } from "preact";
import styles from "./Field.module.css";

interface Props {
  label: string;
  htmlFor?: string;
  hint?: string;
  error?: string;
  children: ComponentChildren;
}

export default function Field(
  { label, htmlFor, hint, error, children }: Props,
) {
  return (
    <div class={`${styles.field} field`}>
      <label class={styles.label} for={htmlFor}>{label}</label>
      {children}
      {hint && !error && <span class={styles.hint}>{hint}</span>}
      {error && <span class={styles.error}>{error}</span>}
    </div>
  );
}
