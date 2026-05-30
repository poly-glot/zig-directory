import type { ComponentChildren } from "preact";
import styles from "./EmptyState.module.css";

interface Props {
  title: string;
  body?: string;
  action?: ComponentChildren;
}

export default function EmptyState({ title, body, action }: Props) {
  return (
    <div class={`${styles.wrap} empty-state`}>
      <div class={styles.title}>{title}</div>
      {body && <p class={styles.body}>{body}</p>}
      {action}
    </div>
  );
}
