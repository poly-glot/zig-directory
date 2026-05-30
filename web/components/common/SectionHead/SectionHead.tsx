import type { ComponentChildren } from "preact";
import styles from "./SectionHead.module.css";

interface Props {
  num: string;
  topic: string;
  title: ComponentChildren;
  lede?: ComponentChildren;
}

export default function SectionHead({ num, topic, title, lede }: Props) {
  return (
    <div class={styles.head}>
      <div class={styles.label}>
        <span class={styles.num}>— SEC. {num}</span>
        <br />
        <span class="micro">{topic}</span>
      </div>
      <div>
        <h2 class="h1">{title}</h2>
        {lede ? <p class="lede mt-16">{lede}</p> : null}
      </div>
    </div>
  );
}
