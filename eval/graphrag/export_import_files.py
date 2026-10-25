import glob
import json
import struct
import sys
import time

import numpy as np

DIMS = 384
VECTORS_MAGIC, VECTORS_VERSION = 0x52564D44, 1
MODEL_TEXT = b"Xenova/bge-small-en-v1.5:model_quantized.onnx:cls"
FNV_OFFSET, FNV_PRIME, U64 = 0xCBF29CE484222325, 0x100000001B3, (1 << 64) - 1


def fnv1a64(data):
    h = FNV_OFFSET
    for b in data:
        h = ((h ^ b) * FNV_PRIME) & U64
    return h


def field(s):
    return " ".join(s.replace("\t", " ").split())


def write_categories(topics, path):
    paths = set()
    for topic in topics:
        parts = topic.split("/")
        for depth in range(2, len(parts) + 1):
            paths.add("/".join(parts[:depth]))
    with open(path, "w") as f:
        for p in sorted(paths, key=lambda s: (s.count("/"), s)):
            parent, _, name = p.rpartition("/")
            f.write(f"{p}\t{parent}\t{name}\t{name.lower()}\n")
    return len(paths)


def write_vectors(emb_dir, rows, path):
    blocks = [np.load(p, mmap_mode="r") for p in sorted(glob.glob(f"{emb_dir}/block_*.npy"))]
    assert sum(len(b) for b in blocks) == rows, (sum(len(b) for b in blocks), rows)
    with open(path, "wb") as f:
        f.write(struct.pack("<IIQQ", VECTORS_MAGIC, VECTORS_VERSION, fnv1a64(MODEL_TEXT), rows))
        for b in blocks:
            v = np.asarray(b, dtype=np.float32)
            v /= np.linalg.norm(v, axis=1, keepdims=True)
            scale = np.abs(v).max(axis=1, keepdims=True) / 127.0
            q = np.clip(np.round(v / scale), -127, 127).astype(np.int8)
            rec = np.empty(len(v), dtype=np.dtype([("s", "<f4"), ("v", "i1", (DIMS,))]))
            rec["s"] = scale[:, 0]
            rec["v"] = q
            f.write(rec.tobytes())


def main(links_jsonl, emb_dir, out_dir):
    started = time.perf_counter()
    topics = set()
    rows = 0
    with open(links_jsonl) as src, open(f"{out_dir}/links.tsv", "w") as dst:
        for line in src:
            link = json.loads(line)
            topics.add(link["topic"])
            dst.write(f'{link["topic"]}\t{field(link["url"])}\t{field(link["title"])}\t{field(link["description"])}\n')
            rows += 1
    categories = write_categories(topics, f"{out_dir}/cats.tsv")
    write_vectors(emb_dir, rows, f"{out_dir}/vectors.bin")
    print(json.dumps({"links": rows, "categories": categories, "model_id": fnv1a64(MODEL_TEXT), "sec": round(time.perf_counter() - started)}))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
