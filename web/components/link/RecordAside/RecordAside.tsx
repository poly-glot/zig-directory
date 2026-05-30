import type { LinkStatus } from "../../../lib/dmoz-client.ts";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import { dashOrValue, pad7 } from "../../../lib/format.ts";
import TagsRow from "../TagsRow/TagsRow.tsx";
import styles from "./RecordAside.module.css";

interface Props {
  id: number;
  reviewed: string;
  status: LinkStatus;
  submitterId: number;
  language: string;
  region: string;
  license: string;
  tags: string;
}

function statusLabel(s: LinkStatus): string {
  if (s === "approved") return "● Approved";
  if (s === "pending") return "○ Pending";
  if (s === "rejected") return "× Rejected";
  return "— Unknown";
}

function submittedByLabel(submitterId: number): string {
  if (submitterId <= 0) return "—";
  return `Editor #${submitterId}`;
}

function KeyValue({ label, value }: { label: string; value: string }) {
  return (
    <div class={styles.kv}>
      <span class="label">{label}</span>
      <span class="value">{value}</span>
    </div>
  );
}

export default function RecordAside(props: Props) {
  const { id, reviewed, status, submitterId, language, region, license, tags } =
    props;
  return (
    <aside class={styles.aside}>
      <Eyebrow muted label="Record" />
      <div class="hr-strong mt-16 mb-16"></div>
      <KeyValue label="DMZ ID" value={`DMZ-${pad7(id)}`} />
      <KeyValue label="Status" value={statusLabel(status)} />
      <KeyValue label="Submitted by" value={submittedByLabel(submitterId)} />
      <KeyValue label="Language" value={dashOrValue(language)} />
      <KeyValue label="Region" value={dashOrValue(region)} />
      <KeyValue label="License" value={dashOrValue(license)} />
      <KeyValue label="Reviewed" value={reviewed} />

      <div class="hr-strong mt-32 mb-24"></div>
      <Eyebrow muted label="Tags" />
      <TagsRow tags={tags} />

      <div class="hr-strong mt-32 mb-24"></div>
      <Eyebrow muted label="Actions" />
      <ul class={styles.actions}>
        <li>
          <a href="#">Report a broken link</a>
          <span class="arrow">→</span>
        </li>
        <li>
          <a href="#">Suggest a re-categorization</a>
          <span class="arrow">→</span>
        </li>
        <li>
          <a href="#">View archived snapshot</a>
          <span class="arrow">→</span>
        </li>
      </ul>
    </aside>
  );
}
