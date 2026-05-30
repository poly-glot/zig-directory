import type { ComponentChildren } from "preact";
import styles from "./FormFooter.module.css";

interface Props {
  cancel?: ComponentChildren;
  primary: ComponentChildren;
}

export default function FormFooter({ cancel, primary }: Props) {
  return (
    <div class={`${styles.footer} form-footer`}>
      {cancel}
      <div class={styles.right}>{primary}</div>
    </div>
  );
}
