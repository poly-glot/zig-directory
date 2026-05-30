interface Props {
  url: string;
}

export default function Hostname({ url }: Props) {
  try {
    return <>{new URL(url).hostname}</>;
  } catch {
    return <>{url}</>;
  }
}
