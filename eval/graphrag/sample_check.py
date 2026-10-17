import json
import random
import re
import time
from collections import Counter, defaultdict

import numpy as np
from build_index import extract_entities, normalize, prune
from common import (
    INDEX,
    OUT,
    complete,
    corpus,
    embed,
    link_text,
    parse_json,
    read_jsonl,
    write_jsonl,
)
from evaluate import Retriever, paired_bootstrap, score

SEED = 11
SAMPLE_SIZE = 5000
BRIDGE_CANDIDATES = 700
MULTIHOP_TARGET = 150
BRIDGE_MIN_DF = 2
BRIDGE_MAX_DF = 8
BRIDGE_MIN_CHARS = 4
MIN_QUESTION_WORDS = 6
SUB_MAX_DF = 25
LLM_EXTRACT_BATCH = 32
LLM_MAX_ENTITIES = 8
BASELINE = "hybrid"
METHODS = ["bm25", "vector", "hybrid", "hybrid_feedback", "graph_local"]


def timed(label: str, fn):
    start = time.perf_counter()
    result = fn()
    print(f"{label}: {time.perf_counter() - start:.1f}s", flush=True)
    return result


def branch(category: dict) -> tuple[str, ...]:
    return tuple(category["path"][:3])


def capitalised_in(entity: str, text: str) -> bool:
    match = re.search(re.escape(entity), text, re.IGNORECASE)
    return bool(match) and text[match.start()].isupper()


def bridge_pairs(rng: random.Random) -> list[dict]:
    links, categories = corpus()
    by_id = {l["id"]: l for l in links}
    links_by_entity = defaultdict(list)
    for row in read_jsonl(INDEX / "link_entities.jsonl"):
        for e in row["entities"]:
            links_by_entity[e].append(row["id"])

    pairs = []
    for entity, ids in links_by_entity.items():
        if (
            not BRIDGE_MIN_DF <= len(ids) <= BRIDGE_MAX_DF
            or len(entity) < BRIDGE_MIN_CHARS
        ):
            continue
        named = [
            i
            for i in ids
            if capitalised_in(entity, link_text(by_id[i]))
            and by_id[i]["category_id"] in categories
        ]
        for a in named:
            partner = next(
                (
                    b
                    for b in named
                    if branch(categories[by_id[b]["category_id"]])
                    != branch(categories[by_id[a]["category_id"]])
                ),
                None,
            )
            if partner:
                pairs.append({"entity": entity, "a": a, "b": partner, "mentions": ids})
                break

    rng.shuffle(pairs)
    return pairs[:BRIDGE_CANDIDATES]


def same_referent(pairs: list[dict], by_id: dict[int, dict]) -> list[dict]:
    prompts = [
        f"Site A: {by_id[p['a']]['title']}. {by_id[p['a']]['description']}\n"
        f"Site B: {by_id[p['b']]['title']}. {by_id[p['b']]['description']}\n\n"
        f'Do both sites refer to the same real-world entity "{p["entity"]}" (the same person, place, organisation or thing, '
        "not merely the same word or name)? Reply with only yes or no."
        for p in pairs
    ]
    replies = complete(prompts, max_tokens=3, batch=LLM_EXTRACT_BATCH)
    return [
        p for p, reply in zip(pairs, replies) if reply.strip().lower().startswith("yes")
    ]


def multihop_questions(rng: random.Random) -> list[dict]:
    path = OUT / "multihop_questions.jsonl"
    if path.exists():
        return read_jsonl(path)

    links, _ = corpus()
    by_id = {l["id"]: l for l in links}
    candidates = bridge_pairs(rng)
    pairs = same_referent(candidates, by_id)
    (OUT / "multihop_stats.json").write_text(
        json.dumps(
            {"candidate_pairs": len(candidates), "same_referent_pairs": len(pairs)}
        )
    )
    print(
        f"bridge pairs: {len(pairs)}/{len(candidates)} refer to the same real-world entity",
        flush=True,
    )
    prompts = [
        f'Two websites from a web directory both relate to "{p["entity"]}".\n'
        f"Site A: {by_id[p['a']]['title']}. {by_id[p['a']]['description']}\n"
        f"Site B: {by_id[p['b']]['title']}. {by_id[p['b']]['description']}\n\n"
        f'Write one question (max 30 words) that needs BOTH sites: identify "{p["entity"]}" only indirectly, '
        "through a detail taken from Site A, and ask for the kind of thing Site B offers. "
        f'Never write "{p["entity"]}" or either site\'s name. Reply with only the question.'
        for p in pairs
    ]
    replies = complete(prompts, max_tokens=60)

    questions = []
    for p, reply in zip(pairs, replies):
        text = reply.strip().strip('"')
        if p["entity"] in text.lower() or len(text.split()) < MIN_QUESTION_WORDS:
            continue
        questions.append(
            {
                "qid": f"multihop-{len(questions)}",
                "task": "multihop",
                "query": text,
                "bridge": p["entity"],
                "gold_links": [p["a"], p["b"]],
                "mentions": p["mentions"],
            }
        )

    questions = questions[:MULTIHOP_TARGET]
    write_jsonl(path, questions)
    return questions


def sample_corpus(questions: list[dict], rng: random.Random) -> list[dict]:
    links, _ = corpus()
    required = set()
    for q in questions:
        required.update(q.get("gold_links", []))
        required.update(q.get("mentions", []))
        if "gold_link" in q:
            required.add(q["gold_link"])

    rest = [l["id"] for l in links if l["id"] not in required]
    fill = rng.sample(rest, max(0, SAMPLE_SIZE - len(required)))
    chosen = required | set(fill)
    return [l for l in links if l["id"] in chosen]


def llm_entities(sample: list[dict]) -> list[list[str]]:
    path = OUT / "llm_entities.jsonl"
    cached = (
        {row["id"]: row["entities"] for row in read_jsonl(path)}
        if path.exists()
        else {}
    )
    missing = [l for l in sample if l["id"] not in cached]

    if missing:
        prompts = [
            f"Website: {link_text(l)}\n\n"
            f"List up to {LLM_MAX_ENTITIES} entities and specific topics in this description: people, organisations, places, "
            "works, products, events and specific subjects (1-4 words each). Skip generic words such as website, "
            'information, services, online. Reply with a JSON array of strings only, e.g. ["louvre", "paris", "impressionism"].'
            for l in missing
        ]
        replies = complete(prompts, max_tokens=80, batch=LLM_EXTRACT_BATCH)
        for l, reply in zip(missing, replies):
            parsed = parse_json(reply)
            items = parsed if isinstance(parsed, list) else []
            cached[l["id"]] = sorted(
                {normalize(str(x)) for x in items if isinstance(x, (str, int))} - {""}
            )
        write_jsonl(path, [{"id": i, "entities": e} for i, e in cached.items()])

    return [
        [e for e in cached[l["id"]] if len(e) > 2 and not e.isdigit()] for l in sample
    ]


def build_retriever(
    sample: list[dict], link_vectors: np.ndarray, per_link: list[list[str]]
) -> Retriever:
    names = sorted({e for ents in per_link for e in ents})
    return Retriever(sample, link_vectors, per_link, names, embed(names))


def graph_stats(
    label: str, per_link: list[list[str]], sample: list[dict], multihop: list[dict]
) -> dict:
    row_of = {l["id"]: i for i, l in enumerate(sample)}
    linked = [
        bool(
            set(per_link[row_of[q["gold_links"][0]]])
            & set(per_link[row_of[q["gold_links"][1]]])
        )
        for q in multihop
    ]
    vocabulary = Counter(e for ents in per_link for e in ents)
    stats = {
        "entities": len(vocabulary),
        "entities_per_link": float(np.mean([len(e) for e in per_link])),
        "links_without_entities": sum(1 for e in per_link if not e),
        "gold_pairs_sharing_an_entity": float(np.mean(linked)),
    }
    print(f"{label}: {stats}", flush=True)
    return stats


def evaluate_runs(
    questions: list[dict], runs: dict[str, dict[str, list[int]]], sample: list[dict]
) -> dict:
    category_of = {l["id"]: l["category_id"] for l in sample}
    rng = np.random.default_rng(0)
    tasks = {}

    for task in ("multihop", "lookup"):
        subset = [q for q in questions if q["task"] == task]
        per_method = {
            m: [score(q, runs[m][q["qid"]], category_of, {}) for q in subset]
            for m in runs
        }
        table = {}
        for m, rows in per_method.items():
            table[m] = {}
            for metric in rows[0]:
                values = np.array([r[metric] for r in rows])
                baseline = np.array([r[metric] for r in per_method[BASELINE]])
                delta, low, high = paired_bootstrap(values, baseline, rng)
                table[m][metric] = {
                    "mean": float(values.mean()),
                    "delta_vs_hybrid": delta,
                    "ci95": [low, high],
                }
        tasks[task] = {"n": len(subset), "metrics": table}

    return tasks


def main() -> None:
    rng = random.Random(SEED)
    links, _ = corpus()
    row_of_full = {l["id"]: i for i, l in enumerate(links)}

    multihop = timed("multi-hop questions", lambda: multihop_questions(rng))
    lookup = [q for q in read_jsonl(OUT / "questions.jsonl") if q["task"] == "lookup"]
    questions = multihop + lookup
    print(f"multi-hop questions kept: {len(multihop)}", flush=True)

    sample = sample_corpus(questions, rng)
    sample_vectors = np.load(INDEX / "link_vectors.npy")[
        [row_of_full[l["id"]] for l in sample]
    ]
    print(f"sample corpus: {len(sample)} links", flush=True)

    spacy_entities = prune(
        timed("spaCy extraction (sample)", lambda: extract_entities(sample)), SUB_MAX_DF
    )
    llm_raw = timed("LLM extraction (sample)", lambda: llm_entities(sample))
    llm_pruned = prune(llm_raw, SUB_MAX_DF)

    stats = {
        "spacy": graph_stats("spaCy graph", spacy_entities, sample, multihop),
        "llm": graph_stats("LLM graph", llm_pruned, sample, multihop),
    }

    spacy_retriever = build_retriever(sample, sample_vectors, spacy_entities)
    llm_retriever = build_retriever(sample, sample_vectors, llm_pruned)
    query_vectors = embed([q["query"] for q in questions], is_query=True)

    runs: dict[str, dict[str, list[int]]] = {}
    latency: dict[str, float] = {}
    plan = [
        (m, spacy_retriever, m if m != "graph_local" else "graph_local_spacy")
        for m in METHODS
    ]
    plan.append(("graph_local", llm_retriever, "graph_local_llm"))

    for method, retriever, label in plan:
        started = time.perf_counter()
        runs[label] = {
            q["qid"]: retriever.run(method, q["query"], qvec, 10)
            for q, qvec in zip(questions, query_vectors)
        }
        latency[label] = (time.perf_counter() - started) * 1000 / len(questions)

    tasks = evaluate_runs(questions, runs, sample)
    (OUT / "sample_results.json").write_text(
        json.dumps({"graphs": stats, "latency_ms": latency, "tasks": tasks}, indent=2)
    )

    for task, data in tasks.items():
        print(f"\n{task} (n={data['n']}, corpus={len(sample)})")
        for m, row in data["metrics"].items():
            cells = "  ".join(
                f"{metric}={v['mean']:.3f} (Δ{v['delta_vs_hybrid']:+.3f} [{v['ci95'][0]:+.3f},{v['ci95'][1]:+.3f}])"
                for metric, v in row.items()
            )
            print(f"  {m:18} {cells}")
    print("\nlatency ms/query:", {m: round(v, 1) for m, v in latency.items()})


if __name__ == "__main__":
    main()
