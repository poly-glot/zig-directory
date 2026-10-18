import json
import re
import time
from collections import defaultdict

import igraph as ig
import numpy as np
from common import INDEX, OUT, corpus, embed, link_text, read_jsonl
from rank_bm25 import BM25Okapi

CANDIDATES = 200
RRF_K = 60
MMR_POOL = 100
MMR_LAMBDA = 0.7
PPR_DAMPING = 0.5
PPR_ENTITY_SEEDS = 8
PPR_LINK_SEEDS = 10
GLOBAL_COMMUNITIES = 6
FEEDBACK_DOCS = 3
LOOKUP_K = 10
COVERAGE_K = 20
BOOTSTRAP_ROUNDS = 2000
BASELINE = "hybrid"
TOKEN = re.compile(r"[a-z0-9]+")


def tokenize(text: str) -> list[str]:
    return TOKEN.findall(text.lower())


def rrf(*rankings: list[int]) -> list[int]:
    scores: dict[int, float] = defaultdict(float)
    for ranking in rankings:
        for rank, row in enumerate(ranking):
            scores[row] += 1.0 / (RRF_K + rank + 1)
    return sorted(scores, key=lambda r: -scores[r])


class Retriever:
    def __init__(
        self,
        links: list[dict],
        link_vectors: np.ndarray,
        link_entities: list[list[str]],
        entity_names: list[str],
        entity_vectors: np.ndarray,
        communities: list[dict] | None = None,
        reports: list[dict] | None = None,
        report_vectors: np.ndarray | None = None,
    ) -> None:
        self.links = links
        self.row_of_id = {l["id"]: i for i, l in enumerate(links)}
        self.link_vectors = link_vectors
        self.entity_names = entity_names
        self.entity_vectors = entity_vectors
        self.bm25 = BM25Okapi([tokenize(link_text(l)) for l in links])
        self.communities = {c["id"]: c for c in communities or []}
        self.reports = reports or []
        self.report_vectors = report_vectors
        self.bipartite = self._bipartite(link_entities)

    @classmethod
    def from_index(cls) -> "Retriever":
        links, _ = corpus()
        graph_data = json.loads((INDEX / "communities.json").read_text())
        return cls(
            links,
            np.load(INDEX / "link_vectors.npy"),
            [row["entities"] for row in read_jsonl(INDEX / "link_entities.jsonl")],
            graph_data["names"],
            np.load(INDEX / "entity_vectors.npy"),
            graph_data["communities"],
            read_jsonl(INDEX / "reports.jsonl"),
            np.load(INDEX / "report_vectors.npy"),
        )

    def _bipartite(self, link_entities: list[list[str]]) -> ig.Graph:
        entity_row = {name: i for i, name in enumerate(self.entity_names)}
        offset = len(self.links)
        edges = [
            (link_row, offset + entity_row[e])
            for link_row, ents in enumerate(link_entities)
            for e in ents
        ]
        return ig.Graph(n=offset + len(self.entity_names), edges=edges, directed=False)

    def keyword(self, query: str) -> list[int]:
        scores = self.bm25.get_scores(tokenize(query))
        top = np.argpartition(-scores, CANDIDATES)[:CANDIDATES]
        return [int(r) for r in top[np.argsort(-scores[top])] if scores[r] > 0]

    def vector(self, qvec: np.ndarray) -> list[int]:
        scores = self.link_vectors @ qvec
        top = np.argpartition(-scores, CANDIDATES)[:CANDIDATES]
        return [int(r) for r in top[np.argsort(-scores[top])]]

    def hybrid(self, query: str, qvec: np.ndarray) -> list[int]:
        return rrf(self.keyword(query), self.vector(qvec))

    def hybrid_feedback(self, query: str, qvec: np.ndarray) -> list[int]:
        first = self.hybrid(query, qvec)
        expanded_vector = qvec + self.link_vectors[first[:FEEDBACK_DOCS]].mean(axis=0)
        expanded_vector /= np.linalg.norm(expanded_vector)
        expanded_query = " ".join(
            [query, *(link_text(self.links[r]) for r in first[:FEEDBACK_DOCS])]
        )
        return rrf(first, self.hybrid(expanded_query, expanded_vector))

    def mmr(self, query: str, qvec: np.ndarray, k: int) -> list[int]:
        pool = self.hybrid(query, qvec)[:MMR_POOL]
        vectors = self.link_vectors[pool]
        relevance = vectors @ qvec
        chosen: list[int] = []
        remaining = list(range(len(pool)))

        while remaining and len(chosen) < k:
            redundancy = (
                (vectors[remaining] @ vectors[chosen].T).max(axis=1)
                if chosen
                else np.zeros(len(remaining))
            )
            score = MMR_LAMBDA * relevance[remaining] - (1 - MMR_LAMBDA) * redundancy
            best = remaining[int(np.argmax(score))]
            chosen.append(best)
            remaining.remove(best)

        return [pool[i] for i in chosen]

    def graph_local(self, query: str, qvec: np.ndarray) -> list[int]:
        offset = len(self.links)
        reset = np.zeros(self.bipartite.vcount())

        entity_scores = self.entity_vectors @ qvec
        for e in np.argsort(-entity_scores)[:PPR_ENTITY_SEEDS]:
            reset[offset + e] += max(float(entity_scores[e]), 0.0)
        for rank, row in enumerate(self.hybrid(query, qvec)[:PPR_LINK_SEEDS]):
            reset[row] += 1.0 / (rank + 1)

        ppr = np.array(
            self.bipartite.personalized_pagerank(
                damping=PPR_DAMPING, reset=reset.tolist()
            )
        )[:offset]
        top = np.argpartition(-ppr, CANDIDATES)[:CANDIDATES]
        return [int(r) for r in top[np.argsort(-ppr[top])]]

    def graph_global(self, qvec: np.ndarray, k: int) -> list[int]:
        best = np.argsort(-(self.report_vectors @ qvec))[:GLOBAL_COMMUNITIES]
        queues = []
        for r in best:
            rows = [
                self.row_of_id[i]
                for i in self.communities[self.reports[r]["community"]]["links"]
            ]
            scores = self.link_vectors[rows] @ qvec
            queues.append([rows[i] for i in np.argsort(-scores)])

        picked: list[int] = []
        seen: set[int] = set()
        while len(picked) < k and any(queues):
            for queue in queues:
                while queue and queue[0] in seen:
                    queue.pop(0)
                if queue and len(picked) < k:
                    seen.add(queue[0])
                    picked.append(queue.pop(0))
        return picked

    def run(self, method: str, query: str, qvec: np.ndarray, k: int) -> list[int]:
        match method:
            case "bm25":
                rows = self.keyword(query)
            case "vector":
                rows = self.vector(qvec)
            case "hybrid":
                rows = self.hybrid(query, qvec)
            case "hybrid_feedback":
                rows = self.hybrid_feedback(query, qvec)
            case "hybrid_mmr":
                rows = self.mmr(query, qvec, k)
            case "graph_local":
                rows = self.graph_local(query, qvec)
            case "graph_global":
                rows = self.graph_global(qvec, k)
            case "hybrid+global":
                rows = rrf(self.hybrid(query, qvec)[:k], self.graph_global(qvec, k))
            case _:
                raise ValueError(method)
        return [self.links[r]["id"] for r in rows[:k]]


def ancestors_by_category(categories: dict[int, dict]) -> dict[int, set[int]]:
    result: dict[int, set[int]] = {}
    for cid in categories:
        chain, current = set(), cid
        while current in categories and current not in chain:
            chain.add(current)
            current = categories[current]["parent_id"]
        result[cid] = chain
    return result


def score(
    question: dict,
    ids: list[int],
    category_of: dict[int, int],
    ancestors: dict[int, set[int]],
) -> dict[str, float]:
    if question["task"] == "lookup":
        top = ids[:LOOKUP_K]
        rank = (
            top.index(question["gold_link"]) + 1 if question["gold_link"] in top else 0
        )
        return {
            "recall@10": float(rank > 0),
            "mrr@10": 1.0 / rank if rank else 0.0,
            "category_hit@10": float(
                any(category_of.get(i) == question["gold_category"] for i in top)
            ),
        }

    if question["task"] == "multihop":
        top = set(ids[:LOOKUP_K])
        found = [link in top for link in question["gold_links"]]
        return {
            "both@10": float(all(found)),
            "recall@10": sum(found) / len(found),
            "hop2@10": float(found[-1]),
        }

    top = ids[:COVERAGE_K]
    lineage = [ancestors.get(category_of.get(i, -1), set()) for i in top]
    covered = sum(
        1
        for child in question["gold_children"]
        if any(child in chain for chain in lineage)
    )
    inside = sum(1 for chain in lineage if question["category"] in chain)
    return {
        "coverage@20": covered / len(question["gold_children"]),
        "precision@20": inside / max(len(top), 1),
    }


def paired_bootstrap(
    a: np.ndarray, b: np.ndarray, rng: np.random.Generator
) -> tuple[float, float, float]:
    diff = a - b
    samples = rng.choice(diff, size=(BOOTSTRAP_ROUNDS, len(diff))).mean(axis=1)
    return (
        float(diff.mean()),
        float(np.percentile(samples, 2.5)),
        float(np.percentile(samples, 97.5)),
    )


def main() -> None:
    retriever = Retriever.from_index()
    _, categories = corpus()
    questions = read_jsonl(OUT / "questions.jsonl")
    query_vectors = embed([q["query"] for q in questions], is_query=True)
    category_of = {l["id"]: l["category_id"] for l in retriever.links}
    ancestors = ancestors_by_category(categories)

    runs: dict[str, dict[str, list[int]]] = {
        "dmozdb_search": {
            r["qid"]: r["ids"] for r in read_jsonl(OUT / "run_dmozdb.jsonl")
        }
    }
    latency: dict[str, float] = {}
    methods = [
        "bm25",
        "vector",
        "hybrid",
        "hybrid_mmr",
        "graph_local",
        "graph_global",
        "hybrid+global",
    ]

    for method in methods:
        started = time.perf_counter()
        runs[method] = {
            q["qid"]: retriever.run(
                method,
                q["query"],
                qvec,
                LOOKUP_K if q["task"] == "lookup" else COVERAGE_K,
            )
            for q, qvec in zip(questions, query_vectors)
        }
        latency[method] = (time.perf_counter() - started) * 1000 / len(questions)

    rng = np.random.default_rng(0)
    report: dict = {"latency_ms": latency, "tasks": {}}

    for task in ("lookup", "coverage"):
        subset = [q for q in questions if q["task"] == task]
        per_method = {
            m: [
                score(q, runs[m].get(q["qid"], []), category_of, ancestors)
                for q in subset
            ]
            for m in runs
        }
        metrics = list(per_method[BASELINE][0])
        table = {}

        for m, rows in per_method.items():
            table[m] = {}
            for metric in metrics:
                values = np.array([r[metric] for r in rows])
                baseline = np.array([r[metric] for r in per_method[BASELINE]])
                delta, low, high = paired_bootstrap(values, baseline, rng)
                table[m][metric] = {
                    "mean": float(values.mean()),
                    "delta_vs_hybrid": delta,
                    "ci95": [low, high],
                }

        report["tasks"][task] = {"n": len(subset), "metrics": table}

    (OUT / "results.json").write_text(json.dumps(report, indent=2))

    for task, data in report["tasks"].items():
        print(f"\n{task} (n={data['n']})")
        for m, row in data["metrics"].items():
            cells = "  ".join(
                f"{metric}={v['mean']:.3f} (Δ{v['delta_vs_hybrid']:+.3f} [{v['ci95'][0]:+.3f},{v['ci95'][1]:+.3f}])"
                for metric, v in row.items()
            )
            print(f"  {m:14} {cells}")
    print(
        "\nlatency ms/query (python, indicative):",
        {m: round(v, 1) for m, v in latency.items()},
    )


if __name__ == "__main__":
    main()
