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

## Hybrid design check (`hybrid_design_check.py`)

Decides the native hybrid search design: whether the existing postings, int8
vectors and the transformers.js ONNX model are good enough. Keyword side emulates dmozdb's tokenizer over title, URL and description with
binary postings; vectors from the ONNX int8 bge-small that transformers.js runs.

| Retrieval | Lookup recall@10 | Coverage@20 | Multi-hop both@10 |
|---|---|---|---|
| AND (today) | 0.077 | 0.000 | 0.000 |
| IDF-weighted OR | 0.853 | 0.058 | 0.073 |
| BM25 | 0.863 | 0.077 | 0.120 |
| BM25 + MLX f32 | 0.890 | 0.167 | 0.193 |
| IDF-OR + ONNX f32 | 0.913 | 0.171 | 0.187 |
| IDF-OR + ONNX int8 | 0.913 | 0.171 | 0.187 |

ONNX int8 vs MLX embeddings: mean cosine 0.996 (documents and queries).

## Native search check (`run_dmozdb_search.ts`, `score_native.py`)

The same questions against dmozdb's own search op on a v6 copy of the store.
Vectors and queries are embedded by the web tier's embedder
(`web/lib/embedder.ts`), one text at a time, and links are written through
`put_link_vectors` (op 37) by `web/scripts/backfill-vectors.ts`.

```bash
cd ../../web
deno run -A scripts/fetch-embedding-model.ts
DMOZDB_PORT=18080 deno run -A scripts/backfill-vectors.ts
for mode in all_terms ranked hybrid; do
  SEARCH_MODE=$mode deno run -A --config deno.json ../eval/graphrag/run_dmozdb_search.ts
done
cd ../eval/graphrag && uv run python score_native.py
```

| Search op mode | Lookup recall@10 | Coverage@20 | Multi-hop both@10 | Search p50 / p95 |
|---|---|---|---|---|
| 0 all terms (today) | 0.077 | 0.000 | — | 2 / 8 ms |
| 1 ranked keywords | 0.853 | 0.059 | — | 24 / 33 ms |
| 2 hybrid | 0.907 | 0.165 | 0.200 | 19 / 23 ms |

Backfill wrote all 91,995 vectors in 774 s on one M1 core. Embedding a query
takes 8 ms at p50 (10 ms p95). Batched embedding is not used: the int8 model
quantises activations over the whole padded batch, so the same text embedded
in a batch drifts (mean cosine 0.995) from the text embedded alone.
