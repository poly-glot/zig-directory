import type { ComponentChildren } from "preact";
import styles from "./AdminTable.module.css";

interface Props {
  columns: string[];
  /** Optional `title` tooltip per column index — for cryptic headers. */
  columnTooltips?: Partial<Record<number, string>>;
  emptyMessage?: string;
  children: ComponentChildren;
}

export default function AdminTable(
  { columns, columnTooltips, emptyMessage, children }: Props,
) {
  // children should be <tr>s OR null when empty
  const isEmpty = Array.isArray(children) && children.length === 0;
  return (
    <table class={`${styles.table} ${styles.bleed} admin-table`}>
      <thead>
        <tr>
          {columns.map((c, i) => (
            <th key={c} title={columnTooltips?.[i]}>{c}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {isEmpty && emptyMessage
          ? (
            <tr>
              <td class={styles.empty} colSpan={columns.length}>
                {emptyMessage}
              </td>
            </tr>
          )
          : children}
      </tbody>
    </table>
  );
}
