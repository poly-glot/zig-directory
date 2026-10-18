# dmozdb web

Deno/Fresh frontend for dmozdb. Point it at a running backend with
`DMOZDB_HOST=127.0.0.1` and `DMOZDB_PORT`.

```
deno install
deno run -A scripts/fetch-embedding-model.ts
deno task dev
```

The fetch script downloads the pinned `bge-small-en-v1.5` ONNX model into
`data/models/` (override with `EMBEDDING_MODEL_DIR`) and checks its hashes.
Without it the app still runs, and search falls back to keywords.

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
