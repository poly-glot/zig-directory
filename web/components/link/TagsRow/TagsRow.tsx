import { parseTags } from "../../../lib/format.ts";

interface Props {
  tags: string;
}

export default function TagsRow({ tags }: Props) {
  const items = parseTags(tags);
  if (items.length === 0) {
    return <p class="small mt-16">No tags.</p>;
  }
  return (
    <div class="row mt-16 flex-wrap gap-8">
      {items.map((t) => <span class="chip" key={t}>{t}</span>)}
    </div>
  );
}
