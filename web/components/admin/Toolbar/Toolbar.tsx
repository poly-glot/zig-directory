import type { ComponentChildren } from "preact";
import styles from "./Toolbar.module.css";

interface Props {
  left?: ComponentChildren;
  right?: ComponentChildren;
}

export default function Toolbar({ left, right }: Props) {
  return (
    <div class={`${styles.bar} admin-toolbar`}>
      {left && <div class={styles.left}>{left}</div>}
      {right && <div class={styles.right}>{right}</div>}
    </div>
  );
}
