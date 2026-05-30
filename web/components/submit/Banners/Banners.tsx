interface BannerProps {
  message?: string;
}

export function ErrorBanner({ message }: BannerProps) {
  if (!message) return null;
  return (
    <div class="banner error" role="alert">
      <span>{message}</span>
    </div>
  );
}

export function FieldError({ message }: BannerProps) {
  if (!message) return null;
  return <span class="err">{message}</span>;
}
