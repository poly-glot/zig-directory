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
deno run -A scripts/fetch-models.ts
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

## Graph facts check (`graph_facts.py`, `graph_check.ts`)

Filter, count and group questions that ranking cannot answer ("how many sites
are hosted on tripod.com"). `graph_facts.py` is an independent reference: it
re-implements the URL, site and country rules over an export of the store,
reads the entity records the backfill dumps, and answers nineteen questions.
The native `query_links` op (38) must reproduce every count, group and link id
exactly.

```bash
cd ../../web
DMOZDB_PORT=18081 EXPORT_DIR=./data/graph/ deno run -A --config deno.json ../eval/graphrag/export.ts
DMOZDB_PORT=18081 BACKFILL_DUMP=../eval/graphrag/out/entities_dump.jsonl deno run -A --config deno.json scripts/backfill-entities.ts
(cd ../eval/graphrag && uv run python graph_facts.py)
DMOZDB_PORT=18081 deno run -A --config deno.json ../eval/graphrag/graph_check.ts
```

| Question | Answer on the prod copy |
|---|---|
| Sites hosted on tripod.com | 1,675 links on 1,655 sites (1,212 hosts) |
| Hosting platforms by personal sites | angelfire 1,681, tripod 1,655, blogspot 480, yahoo 418 |
| Links tied to Pakistan | 16 by `.pk`, 7 by a category named Pakistan, 18 by either |
| UK universities by listings | cam.ac.uk 38, ox.ac.uk 23, ed.ac.uk 21 |
| Personal anime sites by platform | 176 sites: angelfire 85, tripod 64, yahoo 11 |
| Links tied to Pakistan by any edge | 76 links on 72 sites: business 34, society 16, reference 6 |
| Links about Islam tied to Pakistan | 3: Jamia Farooqia, an Ahmadiyya page, a comparative page |
| Arts links about Islam by country | 6: IR 2, DE 1, IT 1, US 1 |
| Religions Society links name | christianity 4,506, judaism 231, buddhism 120 |
| People named most | John 125, God 93, Michael 79 |
| Organisations named most in Arts | IMDb 547, Rotten (Tomatoes) 131, Metacritic 82 |

All nineteen match the reference. No Arts link is both tied to Pakistan and
about Islam: five Arts links are tied to Pakistan, all through their text,
and none of the six about Islam is. Measured inside the container
network, a filter question takes 1 to 6 ms, and a tally over all 92k links 14
ms by country and 25 ms by person; from the Mac host Docker Desktop's port
proxy adds about 15 ms to any reply larger than about 16 KiB. The facts index
loads 91,995 links, 59,219 categories and 91,995 entity records in about 2 s
after boot; links and categories add about 20 MiB. A first name alone ("John")
and "God" lead the people tally; the NER model tags both as people.

## Entity extractor bake-off (`entity_bakeoff.py`)

Chooses how links get entity facts (places with their country, religions,
people, organisations) for the graph facts index. `entity_sample.jsonl` holds
300 links drawn independently of every extractor: 120 at random, 90 from
`Society/Religion_and_Spirituality`, 90 from geographically filed categories.
`entity_gold.jsonl` labels them from the title and description; a place's
country uses all context an informed reader has (so "Richmond" in a Missouri
category is US). The labels were written by Claude, so Claude-family
extractors may agree with them more readily.

Countries and religions are scored per link (micro P/R/F1); people and
organisations by relaxed name match. Places resolve through GeoNames
(`data/geonames/`, CC-BY 4.0) with co-mention, population and the link's ccTLD
and category country as the graph vote.

| Extractor | Countries P/R/F1 | Religions P/R/F1 | People F1 | Orgs F1 | ms/link |
|---|---|---|---|---|---|
| Gazetteer + lexicons on raw text, + graph | 0.71/0.85/0.77 | 1.00/0.89/0.94 | - | - | <1 |
| spaCy en_core_web_sm + gazetteer, + graph | 0.88/0.54/0.67 | 1.00/0.89/0.94 | 0.46 | 0.58 | 5 |
| ONNX bert-base-NER + gazetteer, + graph | 0.83/0.65/0.73 | 1.00/0.89/0.94 | 0.68 | 0.73 | 8 |
| Hybrid (NER people suppress gazetteer hits, cities1000), + graph | 0.70/0.92/0.80 | 1.00/0.89/0.94 | 0.68 | 0.73 | 7 |
| Qwen3-8B (MLX), its own countries | 0.95/0.91/0.93 | 0.81/0.63/0.71 | 0.84 | 0.52 | 1,032 |
| Qwen3-8B countries + lexicon religions | 0.95/0.91/0.93 | 0.86/0.93/0.89 | 0.84 | 0.52 | - |

The deterministic layer cannot reach good precision on directory text: given
names (Diana, Martin), common words that are also villages (Jackpot, Haro), and
languages read as nationalities ("Mass in English, Spanish and Vietnamese").
An LLM resolves those from context and adds world knowledge (NASA and the CDC
are US). The religion lexicon is exact (precision 1.00) and stays either way.

### Native extractor (`entity_check.ts`)

`web/lib/entities.ts` runs the deterministic choice in the web tier:
bert-base-NER spans for people, organisations and places, capitalised
gazetteer spans that are multiword or name a city of 100,000 or more, US state
abbreviations after a comma, nationality words outside language context, and
the religion lexicon. It has no graph vote, so a link's record depends only on
its text, and the facts index adds the ccTLD and category edges itself.

```bash
cd ../../web
deno run -A --config deno.json ../eval/graphrag/entity_check.ts
(cd ../eval/graphrag && uv run python score_entity_predictions.py out/entity_predictions_native.jsonl)
```

| Field | P/R/F1 on the 300 links |
|---|---|
| Countries | 0.89/0.75/0.82 |
| Religions | 1.00/0.89/0.94 |
| People | 0.54/0.98/0.70 |
| Organisations | 0.74/0.73/0.74 |

It takes 25 ms a link on one M1 core.

The 300 links are too few to show a religion term's rarer senses, so every term
was also audited over the whole store: how often it is a link's only evidence
for its religion, and in which branch. That found given names and surnames
(Christian Dior, "Bishop, Henry"), the Dominican Republic, Canon cameras,
Buddha Air, Jain Irrigation and World of Warcraft druids. A term inside a
person name the NER finds no longer counts unless it names a religious figure
(Jesus Christ, Krishna), and `canon`, `dominican`, `reformed`, `buddha`, `jain`
and `druid` left the lexicon. `monastery`, `nuns`, `seminary` and `testament`
stayed: in this store they sit under Christianity far more than anywhere else
(`monastery` 27 links against 5 under Buddhism). A brand that contains a term,
such as Pope Insurance Group, still counts.

Backfilling the whole store found defects the 300 links did not. The model
splits names at dots and after abbreviations (`J` and `. Schulz`, `Kurokumo`
and `com`, `St` and `Nicholas`), so person and organisation spans of one kind
now join across one attached character or after an abbreviation of up to three
letters. A nationality word inside a longer place name the model finds
(`British Columbia`, `Indian Ocean`) no longer counts; it had tied 171 British
Columbia links to the UK. GeoNames files Kosovo under the user-assigned `XK`,
which dmozdb refuses, so the gazetteer keeps only countries `countries.tsv`
assigns.

## Query-shape gate (2026-10-24)

Three scripts measure search by the shapes a directory invites, not by a
handful of hand-typed probes.

- `corpus_study.py` — the corpus as it is: branches, depth, the facet
  vocabulary (place, aspect, role, person, title nodes), text conventions,
  ambiguity, morphology. Pure Python, reads `data/`.
- `query_shapes.py` — generates 300 queries per shape from the tree itself
  (person, title, topic, topic+place, topic+aspect, topic+role, NL wrappers,
  plural swap, dropped letter), gold = the source node's links, and scores
  the production design against alternatives offline (needs the MLX venv;
  caches embeddings under `out/`). Writes `out/shape_queries.json`.
- `live_shapes.py [n]` — replays `n` of those queries per shape against a
  running app (`BASE=http://localhost:8000`, default prod) and reports
  hit@10, so an offline delta is checked against the real pipeline before
  and after a change.
