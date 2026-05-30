import type { IndexHealthEntry } from "../../../lib/dmoz-client.ts";
import ConfirmForm from "../../../islands/ConfirmForm.tsx";
import RowActions from "../RowActions/RowActions.tsx";

interface Props {
  idx: IndexHealthEntry;
}

export function pctLabel(bp: number): string {
  return (bp / 100).toFixed(2) + "%";
}

function CoverageDot({ entry }: { entry: IndexHealthEntry }) {
  if (entry.coverageBp >= 9990) {
    return <span class="status-dot">{pctLabel(entry.coverageBp)}</span>;
  }
  if (entry.coverageBp >= 9000) {
    return <span class="status-dot warn">{pctLabel(entry.coverageBp)}</span>;
  }
  return <span class="status-dot pending">{pctLabel(entry.coverageBp)}</span>;
}

function RebuildButton({ name }: { name: string }) {
  return (
    <ConfirmForm
      message={`Rebuild ${name}? This may take minutes on a large dataset.`}
    >
      <input type="hidden" name="action" value="rebuild_index" />
      <input type="hidden" name="name" value={name} />
      <button type="submit" class="btn small ghost">Re-derive</button>
    </ConfirmForm>
  );
}

export default function IntegrityIndexRow({ idx }: Props) {
  const canRebuild = idx.coverageBp < 10000 && idx.name !== "links_by_id";
  return (
    <tr key={idx.name}>
      <td>
        <strong>{idx.name}</strong>
      </td>
      <td>{idx.primaryCount.toLocaleString()}</td>
      <td>{idx.secondaryCount.toLocaleString()}</td>
      <td>
        <CoverageDot entry={idx} />
      </td>
      <td>
        <RowActions>
          {canRebuild
            ? <RebuildButton name={idx.name} />
            : <span class="muted">—</span>}
        </RowActions>
      </td>
    </tr>
  );
}
