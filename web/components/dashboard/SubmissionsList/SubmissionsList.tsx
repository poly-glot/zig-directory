import type { Link, LinkStatus } from "../../../lib/dmoz-client.ts";
import LinkRow from "../../common/LinkRow/LinkRow.tsx";
import { formatLongDate, pad2 } from "../../../lib/format.ts";
import type { Tab } from "../TabStrip/TabStrip.tsx";

interface Props {
  tab: Tab;
  links: Link[];
}

function statusCrumb(s: LinkStatus): string {
  if (s === "approved") return "Approved";
  if (s === "pending") return "Pending review";
  if (s === "rejected") return "Rejected";
  return "Unknown";
}

function EmptyState({ tab }: { tab: Tab }) {
  const label = tab === "all" ? "submissions" : `${tab} submissions`;
  return (
    <div class="banner mt-32">
      <span>
        No {label} yet. <a href="/submit" class="under">Submit a link</a>{" "}
        to get started.
      </span>
    </div>
  );
}

export default function SubmissionsList({ tab, links }: Props) {
  if (links.length === 0) return <EmptyState tab={tab} />;
  return (
    <ul class="list list-bleed-borders">
      {links.map((l, i) => (
        <LinkRow
          key={l.id}
          num={pad2(i + 1)}
          href={`/link/${l.id}`}
          title={l.title}
          url={l.url}
          description={l.description}
          crumb={statusCrumb(l.status)}
          added={formatLongDate(l.createdAt)}
        />
      ))}
    </ul>
  );
}
