FROM ubuntu:24.04 AS builder

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
RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.21

COPY --from=builder /build/zig-out/bin/dmozdb /usr/local/bin/dmozdb

ENV DMOZDB_PORT=8080
ENV DMOZDB_BIND=0.0.0.0
ENV DMOZDB_DATA_DIR=/var/lib/dmozdb
ENV DMOZDB_CACHE_SIZE_MB=256

RUN mkdir -p /var/lib/dmozdb

EXPOSE 8080
VOLUME ["/var/lib/dmozdb"]
ENTRYPOINT ["/usr/local/bin/dmozdb"]
