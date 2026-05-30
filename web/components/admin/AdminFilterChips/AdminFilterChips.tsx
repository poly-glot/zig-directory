import styles from "./AdminFilterChips.module.css";

export interface ChipOption {
  label: string;
  value: string;
  count?: number;
  dot?: string; // optional leading symbol, e.g. "●"
}

export interface ChipGroup {
  label: string;
  param: string; // URL param this group controls
  active: string; // currently-active value
  options: ChipOption[];
  baseUrl: URL;
}

/**
 * Filter chips (pure SSR). Each chip is a link that sets its group's URL
 * param and resets the paginator cursor. One active chip per group.
 */
export default function AdminFilterChips({ groups }: { groups: ChipGroup[] }) {
  return (
    <div class={`${styles.strip} admin-chips`}>
      {groups.map((g) => (
        <div class={styles.group} key={g.param}>
          <span class={styles.label}>{g.label}:</span>
          {g.options.map((opt) => {
            const url = new URL(g.baseUrl);
            url.searchParams.set(g.param, opt.value);
            // Reset paginator state when a chip changes.
            url.searchParams.delete("after_id");
            url.searchParams.delete("cursors");
            const active = opt.value === g.active;
            return (
              <a
                key={opt.value}
                href={url.toString()}
                class={`${styles.chip} ${active ? styles.active : ""}`}
                aria-pressed={active}
              >
                {opt.dot && <span>{opt.dot}</span>}
                <span>{opt.label}</span>
                {typeof opt.count === "number" && (
                  <span class={styles.count}>
                    ({opt.count.toLocaleString()})
                  </span>
                )}
              </a>
            );
          })}
        </div>
      ))}
    </div>
  );
}
