import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import { pad7 } from "../../../lib/format.ts";
import styles from "./DoneState.module.css";

interface Props {
  referenceId?: number;
}

export default function DoneState({ referenceId }: Props) {
  const ref = referenceId ? `DMZ-${pad7(referenceId)}` : "DMZ-0000000";
  return (
    <div>
      <Eyebrow muted label="Submitted" />
      <h1 class="display mt-16">Thanks. Your link is queued.</h1>
      <p class="lede mt-16">
        An editor will review your submission and either approve, decline, or
        re-categorise it. You'll see the outcome on your profile.
      </p>
      <div class={styles.refCard}>
        <div class={styles.refRow}>
          <span class="micro muted">Reference</span>
          <span class={styles.refValue}>{ref}</span>
        </div>
      </div>
      <div class="row gap-16 flex-wrap mt-32">
        <a class="btn" href="/submit">Submit another →</a>
        <a class="btn ghost" href="/">Back to directory →</a>
      </div>
    </div>
  );
}
