import type { Step } from "../../../routes/submit/_lib/types.ts";
import styles from "./Stepper.module.css";

interface Props {
  step: Step;
}

const LABELS: Array<[number, string]> = [
  [1, "URL & Title"],
  [2, "Description"],
  [3, "Category"],
  [4, "Review"],
];

export default function Stepper({ step }: Props) {
  if (step === "done") return null;
  return (
    <ol
      class={`${styles.strip} bleed-rule`}
      data-bleed="both"
      aria-label="Submission progress"
    >
      {LABELS.map(([n, label]) => {
        const done = step > n;
        const current = step === n;
        const cls = current
          ? `${styles.cell} ${styles.current}`
          : done
          ? `${styles.cell} ${styles.done}`
          : styles.cell;
        return (
          <li key={n} class={cls} aria-current={current ? "step" : undefined}>
            <span class={styles.num}>{`0${n}`}</span>
            <span class={styles.label}>{label}</span>
            {done
              ? <span class={styles.check} aria-hidden="true">✓</span>
              : null}
          </li>
        );
      })}
    </ol>
  );
}
