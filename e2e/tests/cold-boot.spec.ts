import { test, expect } from '@playwright/test';
import { spawn, execSync } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { connect as netConnect } from 'node:net';

const REPO_ROOT = '/workspaces/zig-directory';
const DMOZDB_BIN = `${REPO_ROOT}/zig-out/bin/dmozdb`;
const DMOZDB_DATA_DIR = `${REPO_ROOT}/data`;

/**
 * SIGTERM dmozdb and wait until pgrep no longer finds the process.
 * Returns true if it exited within `maxWaitMs`, false otherwise.
 */
async function stopDmozdb(maxWaitMs = 120_000): Promise<boolean> {
  try {
    execSync('pkill -TERM -x dmozdb', { stdio: 'ignore' });
  } catch {
    // pkill exits 1 when no matching process exists — that's fine.
  }
  const deadline = Date.now() + maxWaitMs;
  while (Date.now() < deadline) {
    try {
      execSync('pgrep -x dmozdb', { stdio: 'ignore' });
    } catch {
      return true;
    }
    await sleep(250);
  }
  return false;
}

/**
 * Poll TCP connect to 127.0.0.1:8080. Returns the elapsed millis the moment
 * a connection is accepted, or null if `timeoutMs` elapses first.
 */
async function waitForDmozdbReady(timeoutMs: number): Promise<number | null> {
  const t0 = Date.now();
  const deadline = t0 + timeoutMs;
  while (Date.now() < deadline) {
    const ok = await new Promise<boolean>((resolve) => {
      const sock = netConnect({ host: '127.0.0.1', port: 8080 });
      const finish = (success: boolean) => {
        sock.removeAllListeners();
        sock.destroy();
        resolve(success);
      };
      sock.once('connect', () => finish(true));
      sock.once('error', () => finish(false));
      sock.setTimeout(1000, () => finish(false));
    });
    if (ok) return Date.now() - t0;
    await sleep(100);
  }
  return null;
}

test.describe('Deno App - dmozdb cold boot', () => {
  test.describe.configure({ mode: 'serial', retries: 0 });

  test('cold boot ≤10s on post-migration v3 data', async () => {
    test.setTimeout(180_000);

    const stopped = await stopDmozdb();
    expect(stopped, 'dmozdb should stop within 120s of SIGTERM').toBe(true);

    const t0 = Date.now();
    const proc = spawn(DMOZDB_BIN, [], {
      cwd: REPO_ROOT,
      env: { ...process.env, DMOZDB_DATA_DIR },
      stdio: ['ignore', 'ignore', 'ignore'],
      detached: true,
    });
    proc.unref();
    expect(proc.pid, 'spawn should return a pid').toBeTruthy();

    const elapsed = await waitForDmozdbReady(30_000);
    const wallElapsed = Date.now() - t0;
    console.log(
      `cold-boot: TCP open after ${elapsed}ms (wall ${wallElapsed}ms, pid ${proc.pid})`,
    );
    expect(elapsed, 'dmozdb should accept TCP within 30s').not.toBeNull();
    expect(elapsed!, `cold boot took ${elapsed}ms (target <10000ms)`)
      .toBeLessThan(10_000);
  });
});
