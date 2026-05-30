interface ErrorProps {
  message: string;
}

interface CapProps {
  maxPages: number;
}

export function ErrorBanner({ message }: ErrorProps) {
  return (
    <div class="banner error" role="alert">
      <span>
        {message}. <a href="/">Return to the directory</a>.
      </span>
    </div>
  );
}

export function OffsetCapBanner({ maxPages }: CapProps) {
  return (
    <div class="banner error mt-32" role="alert">
      <span>
        Pagination beyond page {maxPages}{" "}
        isn't supported on this view. Try search or drill into a specific
        subcategory.
      </span>
    </div>
  );
}
