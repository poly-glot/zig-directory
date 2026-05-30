import type { ComponentChildren } from "preact";
import styles from "./RowActions.module.css";

interface Props {
  children: ComponentChildren;
}

export default function RowActions({ children }: Props) {
  return <span class={`${styles.cluster} row-actions`}>{children}</span>;
}
