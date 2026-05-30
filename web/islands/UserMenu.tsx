import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { User } from "../lib/kv-users.ts";
import styles from "./UserMenu.module.css";

interface Props {
  user: Pick<User, "username" | "role">;
}

export default function UserMenu({ user }: Props) {
  const isOpen = useSignal(false);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const close = (e: Event) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        isOpen.value = false;
      }
    };
    document.addEventListener("click", close);
    return () => document.removeEventListener("click", close);
  }, []);

  const onLogout = async (e: Event) => {
    e.preventDefault();
    await fetch("/api/auth", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "logout" }),
    });
    globalThis.location.href = "/";
  };

  return (
    <div class={styles.wrap} ref={wrapRef}>
      <button
        type="button"
        class={styles.trigger}
        onClick={() => (isOpen.value = !isOpen.value)}
        aria-haspopup="menu"
        aria-expanded={isOpen.value}
      >
        <span>{user.username}</span>
        <svg
          width="10"
          height="6"
          viewBox="0 0 10 6"
          fill="none"
          stroke="currentColor"
          stroke-width="1.4"
          aria-hidden="true"
        >
          <path d="M1 1l4 4 4-4" />
        </svg>
      </button>
      {isOpen.value && (
        <div class={styles.menu} role="menu">
          <a href="/dashboard" role="menuitem">Dashboard</a>
          {user.role === "admin"
            ? <a href="/admin" role="menuitem">Admin</a>
            : null}
          <button type="button" onClick={onLogout} role="menuitem">
            Sign out
          </button>
        </div>
      )}
    </div>
  );
}
