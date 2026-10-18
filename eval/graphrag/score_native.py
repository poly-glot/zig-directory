import numpy as np

from common import OUT, corpus, read_jsonl
from evaluate import ancestors_by_category, score

RUNS = ("run_dmozdb.jsonl", "run_dmozdb_ranked.jsonl", "run_dmozdb_hybrid.jsonl")
TASKS = (
    ("lookup", "recall@10", 10),
    ("coverage", "coverage@20", 20),
    ("multihop", "both@10", 10),
)


def main() -> None:
    links, categories = corpus()
    category_of = {link["id"]: link["category_id"] for link in links}
    ancestors = ancestors_by_category(categories)
    questions = read_jsonl(OUT / "questions.jsonl") + read_jsonl(
        OUT / "multihop_questions.jsonl"
    )

    for name in RUNS:
        path = OUT / name
        if not path.exists():
            continue
        ids = {row["qid"]: row["ids"] for row in read_jsonl(path)}
        line = [f"{name:26}"]
        for task, metric, k in TASKS:
            subset = [q for q in questions if q["task"] == task and q["qid"] in ids]
            values = [
                score(q, ids[q["qid"]][:k], category_of, ancestors)[metric]
                for q in subset
            ]
            line.append(f"{task}={np.mean(values):.3f}" if values else f"{task}=-")
        print("  ".join(line))


if __name__ == "__main__":
    main()
