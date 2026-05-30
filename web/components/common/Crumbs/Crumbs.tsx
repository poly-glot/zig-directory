import { Fragment } from "preact";

export interface Crumb {
  name: string;
  href?: string;
}

interface Props {
  crumbs: Crumb[];
  title: string;
}

export default function Crumbs({ crumbs, title }: Props) {
  return (
    <nav class="crumbs" aria-label="Breadcrumb">
      <a href="/">Directory</a>
      {crumbs.map((c, i) => (
        <Fragment key={i}>
          <span class="sep">/</span>
          {c.href ? <a href={c.href}>{c.name}</a> : <span>{c.name}</span>}
        </Fragment>
      ))}
      <span class="sep">/</span>
      <span class="here">{title}</span>
    </nav>
  );
}
