import json
import math
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import onnxruntime as ort
from common import INDEX, OUT, corpus, embed, link_text, read_jsonl
from evaluate import ancestors_by_category, paired_bootstrap, rrf, score
from huggingface_hub import snapshot_download
from rank_bm25 import BM25Okapi
from tokenizers import Tokenizer

ONNX_REPO = "Xenova/bge-small-en-v1.5"
ONNX_BATCH = 128
ONNX_MAX_TOKENS = 128
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
CANDIDATES = 200
MIN_TOKEN = 2
MAX_TOKEN = 64
BASELINE = "bm25+f32"


def zigstore_tokens(text: str) -> set[str]:
    tokens, current = set(), []
    for ch in text.encode("utf-8", "replace") + b" ":
        if 48 <= ch <= 57 or 65 <= ch <= 90 or 97 <= ch <= 122:
            current.append(chr(ch).lower())
            continue
        if len(current) >= MIN_TOKEN:
            tokens.add("".join(current[:MAX_TOKEN]))
        current = []
    return tokens


class IdfOr:
    def __init__(self, docs: list[set[str]]) -> None:
        self.postings: dict[str, list[int]] = defaultdict(list)
        for row, tokens in enumerate(docs):
            for t in tokens:
                self.postings[t].append(row)
        self.n = len(docs)

    def search(self, query: str) -> list[int]:
        scores: dict[int, float] = defaultdict(float)
        for t in zigstore_tokens(query):
            rows = self.postings.get(t, [])
            idf = math.log(1 + (self.n - len(rows) + 0.5) / (len(rows) + 0.5))
            for r in rows:
                scores[r] += idf
        return sorted(scores, key=lambda r: -scores[r])[:CANDIDATES]

    def search_and(self, query: str) -> list[int]:
        sets = [set(self.postings.get(t, [])) for t in zigstore_tokens(query)]
        return sorted(set.intersection(*sets))[:CANDIDATES] if sets else []


def onnx_embedder():
    path = Path(
        snapshot_download(
            ONNX_REPO, allow_patterns=["onnx/model_quantized.onnx", "tokenizer.json"]
        )
    )
    session = ort.InferenceSession(
        str(path / "onnx" / "model_quantized.onnx"), providers=["CPUExecutionProvider"]
    )
    tokenizer = Tokenizer.from_file(str(path / "tokenizer.json"))
    tokenizer.enable_truncation(ONNX_MAX_TOKENS)
    tokenizer.enable_padding()
    wanted = {i.name for i in session.get_inputs()}

    def run(texts: list[str]) -> np.ndarray:
        out = []
        for start in range(0, len(texts), ONNX_BATCH):
            enc = tokenizer.encode_batch(texts[start : start + ONNX_BATCH])
            feeds = {
                "input_ids": np.array([e.ids for e in enc], dtype=np.int64),
                "attention_mask": np.array(
                    [e.attention_mask for e in enc], dtype=np.int64
                ),
                "token_type_ids": np.array([e.type_ids for e in enc], dtype=np.int64),
            }
            hidden = session.run(None, {k: v for k, v in feeds.items() if k in wanted})[
                0
            ]
            cls = hidden[:, 0, :]
            out.append(cls / np.linalg.norm(cls, axis=1, keepdims=True))
        return np.concatenate(out).astype(np.float32)

    return run


def quantize(vectors: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    scale = np.abs(vectors).max(axis=1, keepdims=True) / 127.0
    return np.round(vectors / scale).astype(np.int8), scale.astype(np.float32)


def top(scores: np.ndarray) -> list[int]:
    idx = np.argpartition(-scores, CANDIDATES)[:CANDIDATES]
    return [int(r) for r in idx[np.argsort(-scores[idx])]]


def main() -> None:
    links, categories = corpus()
    questions = read_jsonl(OUT / "questions.jsonl") + read_jsonl(
        OUT / "multihop_questions.jsonl"
    )
    queries = [q["query"] for q in questions]

    docs = [
        zigstore_tokens(f"{l['title']} {l['url']} {l['description']}") for l in links
    ]
    idf_or = IdfOr(docs)
    bm25 = BM25Okapi([sorted(d) for d in docs])

    mlx_docs = np.load(INDEX / "link_vectors.npy")
    mlx_queries = embed(queries, is_query=True)

    onnx = onnx_embedder()
    onnx_path = INDEX / "link_vectors_onnx.npy"
    if not onnx_path.exists():
        started = time.perf_counter()
        np.save(onnx_path, onnx([link_text(l) for l in links]))
        print(f"onnx embed 92k links: {time.perf_counter() - started:.0f}s", flush=True)
    onnx_docs = np.load(onnx_path)
    onnx_queries = onnx([QUERY_PREFIX + q for q in queries])

    doc_parity = float(np.mean(np.sum(mlx_docs * onnx_docs, axis=1)))
    query_parity = float(np.mean(np.sum(mlx_queries * onnx_queries, axis=1)))

    q8_docs, doc_scale = quantize(onnx_docs)
    q8_queries, _ = quantize(onnx_queries)
    q8_docs_f = q8_docs.astype(np.float32)

    runs: dict[str, dict[str, list[int]]] = defaultdict(dict)
    for i, q in enumerate(questions):
        k = 20 if q["task"] == "coverage" else 10
        kw_and = idf_or.search_and(q["query"])
        kw_or = idf_or.search(q["query"])
        kw_bm25 = top(bm25.get_scores(sorted(zigstore_tokens(q["query"]))))
        vec_mlx = top(mlx_docs @ mlx_queries[i])
        vec_onnx = top(onnx_docs @ onnx_queries[i])
        vec_i8 = top((q8_docs_f @ q8_queries[i].astype(np.float32)) * doc_scale[:, 0])

        variants = {
            "and(today)": kw_and,
            "idf_or": kw_or,
            "bm25": kw_bm25,
            "bm25+f32": rrf(kw_bm25, vec_mlx),
            "idf_or+onnx_f32": rrf(kw_or, vec_onnx),
            "idf_or+onnx_i8": rrf(kw_or, vec_i8),
        }
        for name, rows in variants.items():
            runs[name][q["qid"]] = [links[r]["id"] for r in rows[:k]]

    category_of = {l["id"]: l["category_id"] for l in links}
    ancestors = ancestors_by_category(categories)
    rng = np.random.default_rng(0)
    report = {
        "embedding_parity_cosine": {"docs": doc_parity, "queries": query_parity},
        "tasks": {},
    }

    for task, metric in (
        ("lookup", "recall@10"),
        ("coverage", "coverage@20"),
        ("multihop", "both@10"),
    ):
        subset = [q for q in questions if q["task"] == task]
        base = np.array(
            [
                score(q, runs[BASELINE][q["qid"]], category_of, ancestors)[metric]
                for q in subset
            ]
        )
        report["tasks"][task] = {}
        for name in runs:
            values = np.array(
                [
                    score(q, runs[name][q["qid"]], category_of, ancestors)[metric]
                    for q in subset
                ]
            )
            delta, low, high = paired_bootstrap(values, base, rng)
            report["tasks"][task][name] = {
                "metric": metric,
                "mean": float(values.mean()),
                "delta_vs_eval_hybrid": delta,
                "ci95": [low, high],
            }

    (OUT / "hybrid_design_results.json").write_text(json.dumps(report, indent=2))
    print(
        f"embedding parity (mean cosine MLX vs ONNX int8): docs={doc_parity:.4f} queries={query_parity:.4f}"
    )
    for task, rows in report["tasks"].items():
        print(f"\n{task}")
        for name, r in rows.items():
            print(
                f"  {name:18} {r['metric']}={r['mean']:.3f} (Δ{r['delta_vs_eval_hybrid']:+.3f} [{r['ci95'][0]:+.3f},{r['ci95'][1]:+.3f}])"
            )


if __name__ == "__main__":
    main()
