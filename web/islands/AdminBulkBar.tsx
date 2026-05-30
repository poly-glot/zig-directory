import type { ComponentChildren } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import ConfirmModal from "./ConfirmModal.tsx";
import Toast, { type ToastMessage } from "./Toast.tsx";
import styles from "./AdminBulkBar.module.css";

interface Props {
  /** What is being bulk-managed — drives button labels & endpoint paths. */
  entity: "links" | "categories";
  children: ComponentChildren;
}

const BULK_ENDPOINTS = {
  links: {
    status: "/admin/api/bulk-status",
    delete: "/admin/api/bulk-delete",
  },
  categories: {
    status: null,
    // Categories have their own delete endpoint — link ids and category ids
    // share no id space, so this must NOT be the link bulk-delete path.
    delete: "/admin/api/bulk-delete-categories",
  },
} as const;

/**
 * Wraps an SSR table and manages a per-page selection Set<id>. Row checkboxes
 * carry `data-bulk-id`; on mount the island wires change listeners so the
 * selection signal tracks them without re-rendering the table. The sticky bar
 * appears when ≥1 row is selected and offers bulk actions; destructive Delete
 * routes through a type-to-confirm modal. Selection is per-page (not persisted
 * across paginator clicks) by design.
 */
export default function AdminBulkBar({ entity, children }: Props) {
  const selected = useSignal<Set<number>>(new Set());
  const toasts = useSignal<ToastMessage[]>([]);
  const confirmOpen = useSignal(false);
  const root = useRef<HTMLDivElement | null>(null);
  const nextToastId = useRef(1);

  function pushToast(m: Omit<ToastMessage, "id">) {
    toasts.value = [...toasts.value, { ...m, id: nextToastId.current++ }];
  }
  function dismissToast(id: number) {
    toasts.value = toasts.value.filter((t) => t.id !== id);
  }

  useEffect(() => {
    if (!root.current) return;
    const checkboxes = root.current.querySelectorAll<HTMLInputElement>(
      'input[type="checkbox"][data-bulk-id]',
    );
    const onChange = (e: Event) => {
      const cb = e.currentTarget as HTMLInputElement;
      const id = Number(cb.dataset.bulkId);
      const next = new Set(selected.value);
      if (cb.checked) next.add(id);
      else next.delete(id);
      selected.value = next;
    };
    for (const cb of Array.from(checkboxes)) {
      cb.addEventListener("change", onChange);
    }
    return () => {
      for (const cb of Array.from(checkboxes)) {
        cb.removeEventListener("change", onChange);
      }
    };
  }, []);

  function clearSelection() {
    selected.value = new Set();
    if (root.current) {
      for (
        const cb of Array.from(
          root.current.querySelectorAll<HTMLInputElement>(
            "input[data-bulk-id]",
          ),
        )
      ) cb.checked = false;
    }
  }

  async function callBulk(
    path: string,
    body: Record<string, unknown>,
    label: string,
  ) {
    const ids = Array.from(selected.value);
    if (ids.length === 0) return;
    try {
      const r = await fetch(path, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ ids, ...body }),
      });
      const data = await r.json();
      if (!r.ok) throw new Error(data?.error ?? `HTTP ${r.status}`);
      const errCount = Array.isArray(data.errors) ? data.errors.length : 0;
      pushToast({
        message: errCount === 0
          ? `${label}d ${data.ok} of ${ids.length}.`
          : `${label}d ${data.ok} of ${ids.length}. ${errCount} errored.`,
        variant: errCount === 0 ? "success" : (data.ok > 0 ? "info" : "error"),
      });
      // Reload so server-side filters reflect the new state. Optimistic UI is
      // deferred per the spec's risks section.
      setTimeout(() => globalThis.location.reload(), 600);
    } catch (e) {
      pushToast({ message: `${label} failed: ${e}`, variant: "error" });
    }
  }

  const n = selected.value.size;
  const links = entity === "links";

  return (
    <div ref={root} class="admin-bulk-host">
      {n > 0 && (
        <div class={`${styles.host} admin-bulk-bar`}>
          <div class={`${styles.bar} container`}>
            <span class={styles.count}>{n} selected</span>
            {links && (
              <>
                <button
                  type="button"
                  class={styles.btn}
                  onClick={() =>
                    callBulk(
                      BULK_ENDPOINTS.links.status,
                      { status: "approved" },
                      "Approve",
                    )}
                >
                  Approve all
                </button>
                <button
                  type="button"
                  class={styles.btn}
                  onClick={() =>
                    callBulk(
                      BULK_ENDPOINTS.links.status,
                      { status: "rejected" },
                      "Reject",
                    )}
                >
                  Reject all
                </button>
              </>
            )}
            <button
              type="button"
              class={`${styles.btn} ${styles.danger}`}
              onClick={() => {
                confirmOpen.value = true;
              }}
            >
              Delete
            </button>
            <span class={styles.spacer} />
            <button type="button" class={styles.btn} onClick={clearSelection}>
              Clear
            </button>
          </div>
        </div>
      )}
      {children}
      <ConfirmModal
        open={confirmOpen.value}
        title={`Delete ${n} ${entity}?`}
        body="This removes them permanently."
        confirmPhrase={`delete ${n} ${entity}`}
        primaryLabel="Delete"
        onCancel={() => {
          confirmOpen.value = false;
        }}
        onConfirm={() => {
          confirmOpen.value = false;
          callBulk(BULK_ENDPOINTS[entity].delete, {}, "Delete");
        }}
      />
      <Toast messages={toasts.value} onDismiss={dismissToast} />
    </div>
  );
}
