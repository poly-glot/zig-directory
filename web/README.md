# dmozdb web

Deno/Fresh frontend for dmozdb. Point it at a running backend with
`DMOZDB_HOST=127.0.0.1` and `DMOZDB_PORT`.

```
deno install
deno run -A scripts/fetch-models.ts
deno task dev
```

The fetch script downloads the pinned `bge-small-en-v1.5` and `bert-base-NER`
ONNX models into `data/models/` (override with `EMBEDDING_MODEL_DIR` and
`NER_MODEL_DIR`) and checks their hashes. Without them the app still runs:
search falls back to keywords and saved links get no entity facts.

## Link vectors

New and edited links are embedded when they are saved. To embed every existing
link, for a new store or a new model:

```
DMOZDB_HOST=127.0.0.1 DMOZDB_PORT=8080 deno run -A scripts/backfill-vectors.ts
```

It walks links in id order, writes 32 vectors per call and is safe to rerun. It
prints `afterId` every 3,200 links; pass `BACKFILL_AFTER_ID` to resume from
there. Against the cluster, run it through
`kubectl -n dmozdb port-forward svc/dmozdb 8080:8080`.

## Link entities

Saving a link also extracts the places, religions, people and organisations its
title and description name, for `query_links`. To extract them for every
existing link:

```
DMOZDB_HOST=127.0.0.1 DMOZDB_PORT=8080 deno run -A scripts/backfill-entities.ts
```

It writes 64 records per call, prints `afterId` every 3,200 links, resumes from
`BACKFILL_AFTER_ID` and is safe to rerun. `BACKFILL_DUMP=<file>` also writes
every record as JSON lines, which `eval/graphrag/graph_facts.py` reads.

The gazetteer and common-word list in `lib/data/` (override with
`ENTITY_DATA_DIR`) are generated from GeoNames (geonames.org, CC BY 4.0),
`src/facts/countries.tsv` and an export of the links:

```
deno run -A scripts/build-entity-data.ts <geonames dir> ../src/facts/countries.tsv <links.jsonl>
```

The GeoNames directory needs `cities15000.txt` and `admin1CodesASCII.txt`.
Places are kept only in countries dmozdb accepts (`lib/entities_test.ts`).
