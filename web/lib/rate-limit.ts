import { getKv } from "./kv-users.ts";

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const COMMIT_ATTEMPTS_MAX = 5;

export const RATE_LIMITS = {
  login: { attemptsMax: 10, windowMs: 10 * MINUTE_MS },
  register: { attemptsMax: 10, windowMs: HOUR_MS },
  clientRegistration: { attemptsMax: 30, windowMs: HOUR_MS },
  token: { attemptsMax: 120, windowMs: MINUTE_MS },
  authorize: { attemptsMax: 60, windowMs: MINUTE_MS },
} as const;

export type RateLimitedAction = keyof typeof RATE_LIMITS;

export function clientAddress(
  req: Request,
  info: Deno.ServeHandlerInfo,
): string {
  const nearestForwardedFor = req.headers.get("x-forwarded-for")?.split(",")
    .at(-1)?.trim();
  if (nearestForwardedFor) return nearestForwardedFor;

  const remote = info.remoteAddr;
  return "hostname" in remote ? remote.hostname : "unknown";
}

async function adjustAttempts(
  action: RateLimitedAction,
  address: string,
  delta: 1 | -1,
): Promise<boolean> {
  const { attemptsMax, windowMs } = RATE_LIMITS[action];
  const window = Math.floor(Date.now() / windowMs);
  const key = ["rate_limit", action, address, window];
  const kv = await getKv();

  for (let commit = 0; commit < COMMIT_ATTEMPTS_MAX; commit++) {
    const entry = await kv.get<number>(key);
    const attempts = (entry.value ?? 0) + delta;
    if (attempts > attemptsMax || attempts < 0) return false;

    const result = await kv.atomic().check(entry)
      .set(key, attempts, { expireIn: windowMs }).commit();
    if (result.ok) return true;
  }
  return false;
}

export function consumeAttempt(
  action: RateLimitedAction,
  address: string,
): Promise<boolean> {
  return adjustAttempts(action, address, 1);
}

export async function refundAttempt(
  action: RateLimitedAction,
  address: string,
): Promise<void> {
  await adjustAttempts(action, address, -1);
}
