import json
import time
from collections import Counter, defaultdict
from itertools import combinations

import igraph as ig
import leidenalg
import numpy as np
from common import (
    INDEX,
    complete,
    corpus,
    embed,
    link_text,
    parse_json,
    read_jsonl,
    write_jsonl,
)

NER_LABELS = {
    "ORG",
    "PERSON",
    "GPE",
    "LOC",
    "NORP",
    "FAC",
    "EVENT",
    "WORK_OF_ART",
    "PRODUCT",
    "LANGUAGE",
}
LEADING_NOISE = {
    "the",
    "a",
    "an",
    "this",
    "its",
    "their",
    "our",
    "his",
    "her",
    "your",
    "my",
    "all",
    "various",
    "other",
}
MIN_DF = 2
MAX_DF = 400
MAX_CHUNK_TOKENS = 4
MAX_CLUSTER = 250
MAX_LEVELS = 3
SEED = 42
REPORT_MIN_LINKS = 15
REPORT_TOP_ENTITIES = 25
REPORT_SAMPLE_LINKS = 12


def timed(label: str, fn):
    start = time.perf_counter()
    result = fn()
    print(f"{label}: {time.perf_counter() - start:.1f}s", flush=True)
    return result


def normalize(text: str) -> str:
    words = text.lower().replace("’", "'").split()
    while words and words[0] in LEADING_NOISE:
        words = words[1:]
    return " ".join(words).strip(" .,;:'\"()-")


def extract_entities(links: list[dict]) -> list[list[str]]:
    import spacy

    nlp = spacy.load("en_core_web_sm", disable=["lemmatizer"])
    per_link: list[list[str]] = []

    for doc in nlp.pipe((link_text(l) for l in links), batch_size=512):
        found = {normalize(e.text) for e in doc.ents if e.label_ in NER_LABELS}
        found |= {
            normalize(chunk.text)
            for chunk in doc.noun_chunks
            if len(chunk) <= MAX_CHUNK_TOKENS and chunk.root.pos_ in {"NOUN", "PROPN"}
        }
        per_link.append(sorted(e for e in found if len(e) > 2 and not e.isdigit()))

    return per_link


def prune(per_link: list[list[str]], max_df: int = MAX_DF) -> list[list[str]]:
    df = Counter(e for ents in per_link for e in ents)
    keep = {e for e, n in df.items() if MIN_DF <= n <= max_df}
    return [[e for e in ents if e in keep] for ents in per_link]


def cooccurrence_graph(per_link: list[list[str]]) -> tuple[ig.Graph, list[str]]:
    names = sorted({e for ents in per_link for e in ents})
    index = {name: i for i, name in enumerate(names)}
    weights: Counter = Counter()

    for ents in per_link:
        ids = sorted(index[e] for e in ents)
        weights.update(combinations(ids, 2))

    graph = ig.Graph(n=len(names), edges=list(weights.keys()), directed=False)
    graph.es["weight"] = list(weights.values())
    return graph, names


def hierarchical_leiden(graph: ig.Graph) -> list[dict]:
    communities: list[dict] = []

    def split(vertex_ids: list[int], level: int, parent: int) -> None:
        sub = graph.subgraph(vertex_ids)
        partition = leidenalg.find_partition(
            sub, leidenalg.ModularityVertexPartition, weights="weight", seed=SEED
        )

        for members in partition:
            original = [vertex_ids[m] for m in members]
            cid = len(communities)
            communities.append(
                {"id": cid, "level": level, "parent": parent, "entities": original}
            )

            if (
                len(original) > MAX_CLUSTER
                and level + 1 < MAX_LEVELS
                and len(partition) > 1
            ):
                split(original, level + 1, cid)

    split(list(range(graph.vcount())), 0, -1)
    return communities


def assign_links(
    communities: list[dict],
    per_link: list[list[str]],
    names: list[str],
    links: list[dict],
) -> None:
    entity_index = {name: i for i, name in enumerate(names)}
    links_by_entity: dict[int, list[int]] = defaultdict(list)
    for row, ents in enumerate(per_link):
        for e in ents:
            links_by_entity[entity_index[e]].append(row)

    for c in communities:
        rows = {r for e in c["entities"] for r in links_by_entity[e]}
        c["links"] = sorted(links[r]["id"] for r in rows)


def report_prompt(
    c: dict, names: list[str], degree: list[float], links_by_id: dict[int, dict]
) -> str:
    top = sorted(c["entities"], key=lambda e: -degree[e])[:REPORT_TOP_ENTITIES]
    sample = [
        links_by_id[i]
        for i in c["links"][:: max(1, len(c["links"]) // REPORT_SAMPLE_LINKS)][
            :REPORT_SAMPLE_LINKS
        ]
    ]
    listing = "\n".join(f"- {l['title']}: {l['description']}" for l in sample)

    return (
        "You summarise a cluster of websites from a web directory.\n"
        f"Key entities: {', '.join(names[e] for e in top)}\n"
        f"Example websites:\n{listing}\n\n"
        'Reply with JSON only: {"title": "<5-8 word theme>", "summary": "<2-3 sentences on what kinds of sites and topics this cluster covers>"}'
    )


def write_reports(
    communities: list[dict], names: list[str], graph: ig.Graph, links: list[dict]
) -> list[dict]:
    degree = graph.strength(weights="weight")
    links_by_id = {l["id"]: l for l in links}
    targets = [c for c in communities if len(c["links"]) >= REPORT_MIN_LINKS]
    print(f"reports to write: {len(targets)}", flush=True)

    replies = complete(
        [report_prompt(c, names, degree, links_by_id) for c in targets], max_tokens=140
    )
    reports = []
    for c, reply in zip(targets, replies):
        parsed = parse_json(reply) or {}
        title = str(parsed.get("title") or "").strip()
        summary = str(parsed.get("summary") or reply).strip()
        reports.append(
            {
                "community": c["id"],
                "level": c["level"],
                "title": title,
                "summary": summary,
            }
        )
    return reports


def main() -> None:
    INDEX.mkdir(parents=True, exist_ok=True)
    links, _ = corpus()

    entities_path = INDEX / "link_entities.jsonl"
    if not entities_path.exists():
        raw = timed("spaCy entities", lambda: extract_entities(links))
        write_jsonl(
            entities_path,
            [{"id": l["id"], "entities": e} for l, e in zip(links, prune(raw))],
        )
    per_link = [row["entities"] for row in read_jsonl(entities_path)]

    graph, names = timed("co-occurrence graph", lambda: cooccurrence_graph(per_link))
    print(
        f"entities={graph.vcount()} edges={graph.ecount()} components={len(graph.connected_components())}",
        flush=True,
    )

    communities_path = INDEX / "communities.json"
    if not communities_path.exists():
        communities = timed("hierarchical Leiden", lambda: hierarchical_leiden(graph))
        assign_links(communities, per_link, names, links)
        communities_path.write_text(
            json.dumps({"names": names, "communities": communities})
        )
    communities = json.loads(communities_path.read_text())["communities"]
    levels = Counter(c["level"] for c in communities)
    print(f"communities per level: {dict(sorted(levels.items()))}", flush=True)

    link_vectors_path = INDEX / "link_vectors.npy"
    if not link_vectors_path.exists():
        np.save(
            link_vectors_path,
            timed("embed links", lambda: embed([link_text(l) for l in links])),
        )

    entity_vectors_path = INDEX / "entity_vectors.npy"
    if not entity_vectors_path.exists():
        np.save(entity_vectors_path, timed("embed entities", lambda: embed(names)))

    reports_path = INDEX / "reports.jsonl"
    if not reports_path.exists():
        reports = timed(
            "community reports (LLM)",
            lambda: write_reports(communities, names, graph, links),
        )
        write_jsonl(reports_path, reports)
    reports = read_jsonl(reports_path)

    report_vectors_path = INDEX / "report_vectors.npy"
    if not report_vectors_path.exists():
        texts = [f"{r['title']}. {r['summary']}" for r in reports]
        np.save(report_vectors_path, timed("embed reports", lambda: embed(texts)))


if __name__ == "__main__":
    main()
