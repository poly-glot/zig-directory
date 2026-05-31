# ============================================================
# dmozdb — single combined image (Zig backend + Deno/Fresh web)
# ============================================================
# The Zig backend speaks a raw TCP binary protocol and rejects any
# non-loopback connection unless DMOZDB_TRUSTED lists the exact peer
# IPv4 (no CIDR support). Co-locating both processes in one image lets
# the web frontend reach the backend over 127.0.0.1, which the backend
# always trusts — no brittle pod-IP wiring. The entrypoint starts the
# backend on loopback and runs the Deno server in the foreground.
#
# Build: docker build --platform linux/arm64 -t dmozdb .
# Run:   docker run -p 8000:8000 dmozdb
# ============================================================

# ── Stage 1: build the dmozdb backend ──────────────────────
FROM ubuntu:24.04 AS zig-builder

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    curl xz-utils ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.15.2
RUN ZIG_ARCH="$(uname -m)" && \
    curl -sL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /usr/local && \
    ln -s /usr/local/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /build
COPY build.zig ./
COPY src/ src/
# -Dcpu=baseline: the CI builder and the OKE Ampere A1 nodes are different arm64
# microarchitectures. A default (native-CPU) build emits instructions the build
# host supports but Ampere may not, crashing the pod with SIGILL. Baseline armv8-a
# runs on every arm64 target.
RUN zig build -Doptimize=ReleaseSafe -Dcpu=baseline

# ── Stage 2: build the Deno/Fresh web frontend ─────────────
FROM denoland/deno:2.8.1 AS web-builder

WORKDIR /web

# Resolve dependencies first so the layer caches across source edits.
# nodeModulesDir is "manual", so deno install populates node_modules from
# the lockfile; vite (run by `deno task build`) needs it present.
COPY web/deno.json web/deno.lock ./
RUN deno install

COPY web/ ./
RUN deno task build

# ── Stage 3: runtime ───────────────────────────────────────
FROM denoland/deno:2.8.1

WORKDIR /web

# Backend binary.
COPY --from=zig-builder /build/zig-out/bin/dmozdb /usr/local/bin/dmozdb

# The built Fresh SSR bundle (_fresh/server.js) is self-contained — vite inlines
# its deps, so node_modules is NOT shipped at runtime (verified: the bundle boots
# and serves under `deno serve --cached-only` with node_modules removed). Ship the
# bundle, the static assets, and the import map / lockfile the entry resolves.
COPY --from=web-builder /web/_fresh ./_fresh
COPY --from=web-builder /web/static ./static
COPY --from=web-builder /web/deno.json /web/deno.lock ./

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Backend listens on loopback only — never exposed outside the pod.
ENV DMOZDB_BIND=127.0.0.1
ENV DMOZDB_PORT=8080
ENV DMOZDB_DATA_DIR=/var/lib/dmozdb
ENV DMOZDB_CACHE_SIZE_MB=256
# Frontend reaches the backend over loopback; KV persists to a mounted volume.
ENV DMOZDB_HOST=127.0.0.1
ENV KV_PATH=/var/lib/web-kv/users.db

# Only the web frontend is published; the backend stays on 127.0.0.1.
EXPOSE 8000
VOLUME ["/var/lib/dmozdb", "/var/lib/web-kv"]

# tini as PID 1: reaps zombies and forwards SIGTERM to the supervisor script,
# which in turn signals dmozdb so it completes its WAL drain / snapshot before
# the pod terminates. /tini ships in the denoland/deno base image.
ENTRYPOINT ["/tini", "--", "/usr/local/bin/entrypoint.sh"]
