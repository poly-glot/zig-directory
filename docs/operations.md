# Operating dmozdb

This page covers the files the server writes, what to watch, how it shuts down, how to back it up and how the
live deployment is applied. Commands run from the repository root. The environment variables are in the
[configuration table](../README.md#configuration) in the README. The wire ops used for monitoring (`stats`,
`op_latency_stats`, `snapshot`) are in the [protocol reference](protocol.md).

## Data Files

The server creates these files in `DMOZDB_DATA_DIR`:

| File            | Purpose                                                                 |
|-----------------|-------------------------------------------------------------------------|
| `store.dat`     | Main data file (16 KB pages: header + B+Tree nodes)                     |
| `wal.bin`       | Write-ahead log (append-only; truncated at every checkpoint)            |
| `checkpoint.journal` | Page images of the checkpoint in progress; empty between checkpoints, redone on open if a crash left it complete |
| `snapshot.meta` | 64-byte superblock written by op 22 / `dmoz_import`; records the WAL sequence at that point |
| `derived.snap`  | Facts index, URL bloom and vector indexes as they stood at one checkpoint; restored at boot instead of rebuilt from the store, and absent or unreadable means every index loads by scanning |

## Monitoring

Use the `stats` binary protocol op (op=15) to query runtime metrics, and `op_latency_stats` (op=23) for per-op percentiles:

| Metric                          | What to watch                                                            |
|---------------------------------|--------------------------------------------------------------------------|
| `cache_hits` / `cache_misses`   | Compute hit rate; below 80% means cache is too small                     |
| `page_count`                    | Total pages allocated; growth rate reflects write volume                 |
| `wal_pending`                   | Entries waiting to flush; consistently high means writes outpace flushes |
| `category_count` / `link_count` | Total stored objects                                                     |

## Graceful Shutdown

The server handles `SIGINT` and `SIGTERM` via a self-pipe that wakes the epoll loop:

1. Signal handler sets an atomic flag and writes a byte to the self-pipe
2. Epoll loop wakes, detects the shutdown fd, and exits
3. Background workers (checkpointer, memtable flusher, verifier, repair worker) are stopped
4. A final checkpoint runs: memtables drain into the B+Trees, every dirty page and the header go through
   `checkpoint.journal` into `store.dat`, and `wal.bin` is truncated only after the header is durable; if any step
   fails the WAL is kept for replay on the next boot
5. All connections are closed

## Backup

There is no online backup. Either stop the server, or take a snapshot (op 22, a full checkpoint) and copy `store.dat`
immediately after it returns, before the next checkpoint starts; `snapshot.meta` on its own is not a backup.

```bash
# Stop the server for a consistent backup
kill -TERM $(pidof dmozdb)
cp /var/lib/dmozdb/store.dat /var/lib/dmozdb/wal.bin /backup/dmozdb-$(date +%Y%m%d)/
```

## Kubernetes deployment

The live deployment is `deployment/`, applied with kustomize.

```bash
kubectl apply -k deployment/overlays/main
```

`.github/workflows/cd.yaml` does this on every push to `main` or `master`, rewriting each
image tag to the built commit SHA first. Three workloads come out of it: the
Zig backend (StatefulSet), the Deno/Fresh frontend (Deployment + HPA) and the
MCP server (Deployment), behind one Traefik Ingress on
`directory.junaid.guru`, with `/mcp` and `/.well-known/oauth-protected-resource`
routed to the MCP service and everything else to the frontend.

### Secrets, which must exist before the first apply

Two Secrets are referenced by the manifests and created by nobody: not by
kustomize, not by CD. A missing one does not fail the deploy: `kubectl apply`
succeeds, the workflow goes green, and the pod sits in
`CreateContainerConfigError` until someone looks. Create both in the namespace
before the first rollout.

```bash
kubectl create namespace dmozdb

# Deno KV access token, shared by the denokv StatefulSet and the frontend.
kubectl create secret generic denokv-auth -n dmozdb \
  --from-literal=token="$(openssl rand -hex 32)"

# RS256 keypair the frontend signs MCP access tokens with, and verifies them
# against. The MCP server never sees it: it fetches the public half from the
# frontend's JWKS endpoint. Generate a keypair that is not the one in web/.env.
cd web && deno run -A scripts/generate-jwt-keypair.ts
```

That script prints the two values in `.env` form. For the cluster, write each
to a file and load it as a key: `private-key-pem` tolerates real newlines, and
`public-key-jwk` is the JSON object:

```bash
kubectl create secret generic mcp-jwt-signing-key -n dmozdb \
  --from-file=private-key-pem=./private-key-pem \
  --from-file=public-key-jwk=./public-key-jwk
```

Rotating the keypair invalidates every access token already issued, which is
usually what you want and never silent: clients get a `401 invalid_token` and
re-run their sign-in.

The image-pull Secret (`ocirsecret`) is the exception: CD copies it into the
namespace itself on every run.

### What the manifests provide

- **StatefulSet**: 10Gi persistent volume at `/var/lib/dmozdb`, 3Gi request, 5Gi limit RAM,
  250m-1500m CPU
- **Frontend**: 2-4 replicas via HPA at 70% CPU, readiness gated on backend
  reachability
- **MCP**: one replica deliberately; the transport is session-oriented with no
  shared session store, so a second would strand sessions that do not land back
  on their own pod
