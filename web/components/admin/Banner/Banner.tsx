import styles from "./Banner.module.css";

type Variant = "success" | "error" | "info";

interface Props {
  variant?: Variant;
  message?: string | null;
}

/** Derive variant from a free-text message when not explicitly set. */
function inferVariant(message: string): Variant {
  if (message.startsWith("Error")) return "error";
  return "success";
}

export default function Banner({ variant, message }: Props) {
  if (!message) return null;
  const v = variant ?? inferVariant(message);
  return (
    <div class={`${styles.banner} ${styles[v]} banner ${v}`}>{message}</div>
  );
}
