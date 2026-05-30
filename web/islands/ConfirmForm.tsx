import type { ComponentChildren } from "preact";

interface Props {
  message: string;
  method?: "POST" | "GET";
  class?: string;
  children: ComponentChildren;
}

export default function ConfirmForm(
  { message, method = "POST", class: cls = "inline-form", children }: Props,
) {
  return (
    <form
      method={method}
      class={cls}
      onSubmit={(e) => {
        if (!confirm(message)) e.preventDefault();
      }}
    >
      {children}
    </form>
  );
}
