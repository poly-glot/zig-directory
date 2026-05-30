import styles from "./KpiStrip.module.css";

interface Cell {
  label: string;
  value: string;
}

interface Props {
  cells: Cell[];
  compact?: boolean;
}

export default function KpiStrip({ cells, compact = false }: Props) {
  const cls = compact
    ? `${styles.strip} ${styles.compact} kpi-strip compact`
    : `${styles.strip} kpi-strip`;
  return (
    <div class={cls}>
      {cells.map((c) => (
        <div class={`${styles.cell} kpi-cell`} key={c.label}>
          <span class="micro">{c.label}</span>
          <div class="h1">{c.value}</div>
        </div>
      ))}
    </div>
  );
}
