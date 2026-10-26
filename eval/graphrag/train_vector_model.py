import glob
import json
import struct
import sys
import time

import numpy as np

CELLS, M, K, DIMS = 256, 96, 256, 384
SUB = DIMS // M
MAGIC, VERSION = 0x4D564D44, 1
ROWS_PER_BLOCK = 6000


def normalize(x):
    x = np.asarray(x, dtype=np.float32)
    return x / np.linalg.norm(x, axis=1, keepdims=True)


def kmeans(x, k, rng, iters, spherical):
    centers = x[rng.choice(len(x), k, replace=False)].copy()
    for _ in range(iters):
        if spherical:
            assign = (x @ centers.T).argmax(1)
        else:
            d = (x * x).sum(1)[:, None] - 2 * x @ centers.T + (centers * centers).sum(1)[None, :]
            assign = d.argmin(1)
        for c in range(k):
            members = x[assign == c]
            if len(members):
                centers[c] = members.mean(0)
        if spherical:
            centers = normalize(centers)
    return centers


def main(emb_dir, out_path, seed=3):
    rng = np.random.default_rng(seed)
    started = time.perf_counter()
    blocks = [np.load(p, mmap_mode="r") for p in sorted(glob.glob(f"{emb_dir}/block_*.npy"))]
    sample = normalize(np.concatenate([b[np.sort(rng.choice(len(b), ROWS_PER_BLOCK, replace=False))] for b in blocks]))

    centroids = kmeans(sample, CELLS, rng, iters=25, spherical=True)
    books = np.stack([kmeans(sample[:, m * SUB:(m + 1) * SUB], K, rng, iters=20, spherical=False) for m in range(M)])

    with open(out_path, "wb") as f:
        f.write(struct.pack("<6I", MAGIC, VERSION, CELLS, M, K, DIMS))
        f.write(centroids.astype("<f4").tobytes())
        f.write(books.astype("<f4").tobytes())
    print(json.dumps({"sample": len(sample), "cells": CELLS, "m": M, "k": K, "bytes": 24 + (CELLS * DIMS + M * K * SUB) * 4, "sec": round(time.perf_counter() - started)}))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
