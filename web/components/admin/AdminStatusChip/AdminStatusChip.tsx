interface Props {
  healthy: boolean;
}

export default function AdminStatusChip({ healthy }: Props) {
  return (
    <span class={`status-dot ${healthy ? "live" : "down"}`}>
      Backend {healthy ? "online" : "offline"}
    </span>
  );
}
