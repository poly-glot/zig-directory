interface Props {
  num?: string;
  label: string;
  muted?: boolean;
}

// `.eyebrow` and `.muted` are design-system globals (assets/typography.css)
// — used in nearly every route, scoping them per-component would be noise.
export default function Eyebrow({ num, label, muted = false }: Props) {
  const cls = muted ? "eyebrow muted" : "eyebrow";
  return (
    <span class={cls}>
      {num ? <>— {num}</> : <>—</>}
      {label}
    </span>
  );
}
