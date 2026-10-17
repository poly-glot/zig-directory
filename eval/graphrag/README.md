# GraphRAG phase-0 eval

Measures whether GraphRAG-style retrieval beats plain hybrid search on the
dmozdb corpus before any native work is built. Verdict: it does not. Hybrid
search (BM25 + embeddings, RRF) is the native feature worth building.

## Run

Needs a dmozdb serving a copy of `data/store.dat` on `127.0.0.1:18080`, and
Apple silicon for MLX.

```bash
cp ../../data/store.dat ../../data/wal.bin data/
docker run -d --name dmozdb-eval -p 127.0.0.1:18080:8080 -v "$PWD/data":/d \
  -e DMOZDB_DATA_DIR=/d -e ZIGSTORE_TRUSTED=0.0.0.0/0 zigdev:0.16.0 /d/bin/bin/dmozdb

(cd ../../web && deno run -A --config deno.json ../eval/graphrag/export.ts)
uv run python build_index.py
uv run python make_questions.py
(cd ../../web && deno run -A --config deno.json ../eval/graphrag/run_dmozdb_search.ts)
uv run python evaluate.py
uv run python sample_check.py
```

Models: `mlx-community/Qwen3-8B-4bit` (questions, community reports, entity
extraction) and `mlx-community/bge-small-en-v1.5-bf16` (embeddings).

## Results (2026-10-17, M1 Max)

Full corpus: 91,995 links. GraphRAG index: spaCy entities, hierarchical
Leiden (918 communities), 796 LLM community reports.

| Method | Lookup recall@10 (n=300) | Coverage@20 (n=120) |
|---|---|---|
| dmozdb `search` op (today) | 0.077 | 0.000 |
| BM25 | 0.880 | 0.093 |
| Vector | 0.837 | 0.190 |
| **Hybrid (RRF)** | **0.893** | 0.178 |
| Hybrid + MMR | 0.843 | 0.194 |
| Graph local (PPR) | 0.870 | 0.153 |
| Graph global (reports) | 0.400 | 0.146 |

The `search` op ANDs every token, so 396 of 420 natural-language queries
return nothing.

Sample check (`sample_check.py`): 5,000-link corpus, 150 multi-hop bridge
questions. Only 178 of 700 cross-branch shared-entity pairs name the same
real-world entity; the rest are homonyms.

| Method | Multi-hop both@10 | Δ vs hybrid [95% CI] |
|---|---|---|
| Hybrid | 0.420 | — |
| Hybrid + pseudo-relevance feedback | 0.473 | +0.053 [+0.007, +0.107] |
| Graph local, spaCy entities | 0.440 | +0.020 [−0.013, +0.053] |
| Graph local, LLM entities | 0.447 | +0.027 [−0.013, +0.067] |

LLM entity extraction matched spaCy on retrieval and cost 42 minutes per
5,000 links (about 13 hours for the full corpus).
