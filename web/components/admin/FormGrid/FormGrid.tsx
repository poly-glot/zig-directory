import type { ComponentChildren } from "preact";

interface Props {
  cols?: 1 | 2;
  children: ComponentChildren;
}

export default function FormGrid({ cols = 1, children }: Props) {
  return <div class={`form-grid ${cols === 2 ? "two" : "one"}`}>{children}
  </div>;
}
