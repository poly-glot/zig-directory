import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

OUT = Path(__file__).parent / "out"
import os
BASE = os.environ.get("BASE", "https://directory.junaid.guru") + "/api/v1/search"
PER_SHAPE = int(sys.argv[1]) if len(sys.argv) > 1 else 25
K = 10

shapes = json.load((OUT / "shape_queries.json").open())
print(f"live hit@{K} at {BASE} on {PER_SHAPE} queries per shape (same generated queries and gold as the offline run)")
for shape, items in shapes.items():
    hits = 0
    ms = []
    n = 0
    for q, gold in items[:PER_SHAPE]:
        g = set(gold)
        url = f"{BASE}?q={urllib.parse.quote(q)}&limit={K}"
        t0 = time.time()
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                d = json.load(r)
        except Exception as e:  # noqa: BLE001
            print(f"   ! {q!r}: {e}")
            continue
        ms.append((time.time() - t0) * 1000)
        n += 1
        hits += any(l["id"] in g for l in d["links"][:K])
    if n:
        print(f"  {shape:42s} hit@{K}={hits / n:.2f}  n={n}  median_ms={sorted(ms)[len(ms) // 2]:.0f}")
