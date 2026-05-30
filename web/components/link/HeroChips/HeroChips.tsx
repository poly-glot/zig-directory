import styles from "./HeroChips.module.css";

interface Props {
  hostname: string;
  crumbText: string;
  added: string;
}

export default function HeroChips({ hostname, crumbText, added }: Props) {
  return (
    <div class={styles.row}>
      <span class="chip">{hostname} ↗</span>
      {crumbText ? <span class="chip count">{crumbText}</span> : null}
      <span class="chip count">Added {added}</span>
    </div>
  );
}
