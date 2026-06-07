# Plan: Cloud Run web tier to serve 1000 VU (no CDN)

## Context & goal

The current architecture is an all-in-OKE split (PR #2–#4): a Deno/Fresh `web`
Deployment, the `dmozdb` Zig backend StatefulSet, and a `denokv` store — all on
the 4-OCPU Always-Free cluster.

The measured ceiling is **~150 req/s at SLA**; at 1000 VU the site degrades to
p95 ~8s with ~1.6% errors. The binding constraint is **web/SSR CPU on the
4-OCPU cluster** — *not* the backend, which sat at ~100× headroom throughout.

**Goal:** serve **1000 VU as comfortably as 100 VU today** (p95 well under SLA,
0 errors, real headroom), **without a CDN**.

**Approach:** move the stateless SSR tier to **Cloud Run** (autoscales past the
4-OCPU cap); keep the single `dmozdb` in OKE. This is the realization of the
Cloud Run plan considered at the start of this work, now justified by the
benchmark numbers below.

## Why this works — the backend already has the headroom (measured)

From the in-cluster `bench` sweep (real Ampere, server isolated, ~1500m-class):

|                                                         | value                              |
|---------------------------------------------------------|------------------------------------|
| 1000 VU offered                                         | ~1,140 req/s                       |
| backend ops/req (home≈5, category≈2, search≈1, blended) | ~2.7                               |
| backend ops/s needed at 1000 VU                         | **~3,000**                         |
| dmozdb capacity @1500m — cheap reads                    | ~24,000 ops/s                      |
| dmozdb capacity @1500m — `subtree-links` (slowest op)   | ~1,500 ops/s                       |
| category pages (~1/3) hitting `subtree-links`           | ~380/s → **~25% of the slow wall** |

So at 1000 VU the **single backend runs at ~25%**. Cloud Run removes the SSR
wall; the backend needs **no scaling**. (MVCC / read-replicas / many-core boxes
remain irrelevant — those are 10k-req/s, 16+-core concerns.)

## Target architecture

```
Browser ──HTTPS──> Cloud Run (Deno/Fresh SSR, amd64, autoscale, europe-west2/London)
                     │  DmozClient → Deno.connectTls (client cert)
                     │  Deno.openKv → shared session/user store
                     │
                     └──mTLS (TCP 8443)──> OCI Network LB (free) ─┐
                                                                  ▼
                                          OKE pod: ghostunnel sidecar → 127.0.0.1:8080 → dmozdb (unchanged, loopback-trusted)
                                                   dmozdb data PVC (single writer)
```

`dmozdb` keeps binding loopback; the ghostunnel sidecar terminates mTLS and
forwards over loopback, so the backend needs **no protocol change** and no new
trust config for the Cloud Run path (loopback is always trusted). Co-locate
Cloud Run in the OKE region so cross-cloud RTT stays low.

## Reusable vs new

**Reusable from the in-OKE split (already built):**
- `Dockerfile.web` (Deno/Fresh build) — but Cloud Run runs **linux/amd64 only**, so build an **amd64** variant (the OKE backend stays arm64).
- `denokv` as the shared users/sessions store.
- `web/lib/dmoz-client.ts`, `web/routes/healthz.ts` — minor edits only.

**New for Cloud Run:**
- mTLS stream proxy (ghostunnel sidecar + OCI NLB) — the in-OKE path used
  private-network CIDR trust; the Cloud Run path crosses the internet and needs
  encryption + mutual auth.
- amd64 web image build + GCP deploy pipeline.
- Stateless-session wiring (Cloud Run is ephemeral).

## Work breakdown

### A. Web image for Cloud Run (amd64)
Build `Dockerfile.web` for **linux/amd64** (Cloud Run is x86-only). CMD must
honor Cloud Run's `$PORT` (`deno serve --port ${PORT:-8080}`).

### B. Secure cross-cloud channel (mTLS)
- Add a **ghostunnel sidecar** to the `dmozdb` pod: `server --listen 0.0.0.0:8443
  --target 127.0.0.1:8080 --cert/key/cacert --allow-cn <cloudrun-cn>`. dmozdb
  stays `DMOZDB_BIND=127.0.0.1` (loopback-trusted — no change).
- Expose 8443 via an **OCI Network Load Balancer** (no hourly charge), DNS
  `db.directory.junaid.guru`.
- `DmozClient.ensureConnected()`: use `Deno.connectTls({ caCerts, cert, key })`
  when TLS env is present, else plain `Deno.connect` (keeps local/dev working).
  Transport-only change — **no wire-format change, no gen-client-ts**.
- PKI (CA + server + client certs) → k8s Secret for the pod; client cert/key/CA
  into Cloud Run via GSM `--set-secrets`.

### C. dmozdb (k8s) — minimal
- **Bump memory request 512Mi → ~1Gi** (the one under-set value the sweep found;
  observed peak ~884Mi). CPU stays **1500m** — ~25% utilized at 1000 VU.
- Remove the in-OKE `web` Deployment + its ingress once Cloud Run is validated
  (or keep for fallback during cutover).

### D. Stateless sessions/users
Cloud Run instances are ephemeral. Anonymous 1000-VU browsing does **not** touch
this; it only matters for logged-in users. Pick one:
- Point `Deno.openKv` at the in-cluster `denokv` over the same mTLS endpoint, OR
- HMAC **signed-cookie** sessions (no per-request store read) + users in `denokv`.

### E. Latency (cross-cloud RTT compounds)
- **Parallelize `loadHomepage`'s 4 sequential backend calls** (`web/routes/index.tsx`)
  — over the internet, 4×RTT sequential is what would hurt p95. Use `Promise.all`
  for the independent fetches.
- Co-locate Cloud Run in the OKE region (**europe-west2**, OKE is `uk-london-1`).
- Set Cloud Run `--min-instances=1 --no-cpu-throttling` only if cold-start
  reconnect latency matters (≈$40–50/mo); otherwise scale-to-zero and let
  `DmozClient` reconnect on the first request.

### F. Egress cost (the no-CDN tradeoff)
Without a CDN, **all page bytes egress from Cloud Run (GCP, ~$0.09–0.12/GB)** —
this moves user-facing egress off OCI's free 10TB onto GCP's metered egress and
scales with traffic. Budget it explicitly. (A CDN later would cut it to near-zero
and is the obvious follow-up.)

### G. CI/CD & DNS
- Backend: unchanged (arm64 → OCIR → OKE).
- Web: build amd64 → **Artifact Registry** (europe-west2) → `gcloud run deploy`,
  authenticate via **Workload Identity Federation** (keyless).
- `directory.junaid.guru` → Cloud Run (domain mapping, or Global LB + serverless
  NEG). Keep the OKE ingress serving until validated, then flip DNS.

### H. Connection model
Each Cloud Run instance's `DmozClient` uses one serialized connection. At
1000 VU across N instances the per-instance req rate is low → fine. If
per-instance concurrency is high, add a small connection pool (drop the
single-`sendChain` serialization).

## Verification

1. Gates: `zig build test` (Linux+0.15.2 container — host is 0.13), `cd web && deno task check`.
2. mTLS path: confirm Cloud Run → ghostunnel → dmozdb round-trips (browse/search/login).
3. **k6 1000 VU (cloud, London) against the Cloud Run URL** → expect **p95 < 800ms,
   ~0% errors, dmozdb ~25% CPU, 0 restarts** — vs the in-OKE 1000 VU (p95 ~8s).
4. Sustained-load `kubectl top` on dmozdb to confirm it stays well under 1500m.
5. Look at the rendered pages (not just green specs).

## What we deliberately do NOT do

- No backend scaling — single `dmozdb` @1500m suffices at 1000 VU (~25%).
- No MVCC / read-replicas / big-core box — irrelevant below ~16 cores / 10k req/s.
- No CDN — assumed unavailable; GCP egress is the accepted cost.

## Rollback

Keep the in-OKE `web` Deployment + ingress until Cloud Run is validated; reverting
is a single DNS change. The backend (dmozdb + denokv) is untouched by the web move.

## Cost summary

| Line                    | Cost                                                         |
|-------------------------|--------------------------------------------------------------|
| Cloud Run compute       | per-request (scale-to-zero)                                  |
| **GCP egress (no CDN)** | **main variable cost**, ~$0.09–0.12/GB — scales with traffic |
| OCI NLB                 | $0 (no hourly charge)                                        |
| Artifact Registry       | cents                                                        |
| dmozdb / denokv         | unchanged (stays in OKE free tier)                           |
