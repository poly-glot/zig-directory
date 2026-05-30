import type { ComponentChildren } from "preact";
import Hostname from "../Hostname/Hostname.tsx";
import styles from "./LinkCard.module.css";

interface Props {
  href: string;
  title: ComponentChildren;
  url?: string;
  description?: ComponentChildren;
  crumb?: string;
  added?: string;
  monoSeed?: string;
}

const ARROW_GLYPH = (
  <svg
    width="10"
    height="8"
    viewBox="0 0 10 8"
    fill="none"
    stroke="currentColor"
    stroke-width="1.5"
    aria-hidden="true"
  >
    <path d="M1 4h8M6 1l3 3-3 3" />
  </svg>
);

const MONO_VARIANTS = 8;
const MONO_CLASSES = [
  styles.c0,
  styles.c1,
  styles.c2,
  styles.c3,
  styles.c4,
  styles.c5,
  styles.c6,
  styles.c7,
];

function plainText(node: ComponentChildren): string {
  if (node == null || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(plainText).join("");
  // deno-lint-ignore no-explicit-any
  const v = node as any;
  if (v && v.props && v.props.children !== undefined) {
    return plainText(v.props.children);
  }
  return "";
}

function monogramText(seed: string): string {
  const cleaned = seed.replace(/[^A-Za-z0-9 ]+/g, " ").trim();
  if (!cleaned) return "·";
  const words = cleaned.split(/\s+/).filter(Boolean);
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return (words[0][0] + words[1][0]).toUpperCase();
}

function monoVariant(seed: string): number {
  let h = 0;
  for (let i = 0; i < seed.length; i++) {
    h = (h * 31 + seed.charCodeAt(i)) | 0;
  }
  return Math.abs(h) % MONO_VARIANTS;
}

export default function LinkCard(
  { href, title, url, description, crumb, added, monoSeed }: Props,
) {
  const titleText = plainText(title);
  const mono = monogramText(titleText);
  const variant = monoVariant(monoSeed ?? titleText ?? "x");
  const external = !!url;
  const target = external ? url : href;
  return (
    <a
      class={`${styles.card} card`}
      href={target}
      {...(external ? { target: "_blank", rel: "noopener noreferrer" } : {})}
    >
      <div class={styles.head}>
        <span
          class={`${styles.mono} ${MONO_CLASSES[variant]}`}
          aria-hidden="true"
        >
          {mono}
        </span>
        {crumb ? <span class={styles.crumb}>{crumb}</span> : null}
      </div>
      <div class="h3">{title}</div>
      {url
        ? (
          <div class={styles.domain}>
            <Hostname url={url} />
          </div>
        )
        : null}
      {description ? <p class={styles.desc}>{description}</p> : null}
      {added
        ? (
          <div class={styles.added}>
            <span>Added {added}</span>
            <span>{ARROW_GLYPH}</span>
          </div>
        )
        : null}
    </a>
  );
}
