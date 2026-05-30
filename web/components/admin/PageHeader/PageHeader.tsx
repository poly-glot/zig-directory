import { Fragment } from "preact";

export interface Crumb {
  label: string;
  href?: string;
}

interface Props {
  title: string;
  crumbs?: Crumb[];
}

export default function PageHeader({ title, crumbs }: Props) {
  return (
    <div class="container">
      {crumbs && crumbs.length > 0 && (
        <nav class="crumbs" aria-label="Breadcrumb">
          {crumbs.map((c, i) => (
            <Fragment key={i}>
              {c.href
                ? <a href={c.href}>{c.label}</a>
                : <span class="here">{c.label}</span>}
              {i < crumbs.length - 1 && <span class="sep">/</span>}
            </Fragment>
          ))}
        </nav>
      )}
      <h1 class="display mt-16 mb-32">{title}</h1>
    </div>
  );
}
