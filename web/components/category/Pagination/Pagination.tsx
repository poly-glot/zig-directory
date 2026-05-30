interface Props {
  path: string;
  page: number;
  totalPages: number;
}

function buildPageUrl(path: string, p: number): string {
  return p <= 1 ? `/category/${path}` : `/category/${path}?page=${p}`;
}

// Compute up to 7 numeric pager cells with "1 …" / "… N" boundary tokens
// when the current page is far from either edge.
function paginationCells(page: number, total: number): Array<number | null> {
  if (total <= 7) {
    return Array.from({ length: total }, (_, i) => i + 1);
  }
  const cells: Array<number | null> = [1];
  const start = Math.max(2, page - 2);
  const end = Math.min(total - 1, page + 2);
  if (start > 2) cells.push(null);
  for (let p = start; p <= end; p++) cells.push(p);
  if (end < total - 1) cells.push(null);
  cells.push(total);
  return cells;
}

function PagerCell(
  { p, page, path, idx }: {
    p: number | null;
    page: number;
    path: string;
    idx: number;
  },
) {
  if (p === null) return <span key={`e${idx}`} class="ellipsis">…</span>;
  return (
    <a
      key={p}
      class={p === page ? "active" : ""}
      href={buildPageUrl(path, p)}
    >
      {p}
    </a>
  );
}

export default function Pagination({ path, page, totalPages }: Props) {
  if (totalPages <= 1) return null;
  const cells = paginationCells(page, totalPages);
  return (
    <nav class="pager mt-48" aria-label="Pagination">
      {page > 1
        ? <a class="prev" href={buildPageUrl(path, page - 1)}>← Prev</a>
        : null}
      {cells.map((p, i) => (
        <PagerCell key={`c${i}`} p={p} page={page} path={path} idx={i} />
      ))}
      {page < totalPages
        ? <a class="next" href={buildPageUrl(path, page + 1)}>Next →</a>
        : null}
    </nav>
  );
}
