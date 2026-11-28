import type { User } from "../../../lib/kv-users.ts";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";

interface Props {
  user: User;
}

export default function HeaderRow({ user }: Props) {
  return (
    <div class="row between pt-48 mb-32 flex-wrap gap-16">
      <div>
        <Eyebrow muted label={`@${user.username}`} />
        <h1 class="display mt-16">Dashboard.</h1>
      </div>
      <div class="row gap-16">
        <form method="POST" action="/auth/logout">
          <button class="btn ghost" type="submit">Sign out →</button>
        </form>
        <a class="btn" href="/submit">Submit a link →</a>
      </div>
    </div>
  );
}
