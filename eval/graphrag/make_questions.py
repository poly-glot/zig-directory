import random
from collections import defaultdict

from common import OUT, complete, corpus, write_jsonl

SEED = 7
LOOKUP_COUNT = 300
COVERAGE_COUNT = 120
MIN_DESCRIPTION_WORDS = 8
MIN_CHILDREN = 5
MAX_CHILDREN = 25
MIN_CHILD_LINKS = 2
MIN_SUBTREE_LINKS = 40
MAX_SUBTREE_LINKS = 2000


def top_level(category: dict) -> str:
    return category["path"][1] if len(category["path"]) > 1 else category["name"]


def stratified(items: list, key, count: int, rng: random.Random) -> list:
    buckets = defaultdict(list)
    for item in items:
        buckets[key(item)].append(item)
    for bucket in buckets.values():
        rng.shuffle(bucket)

    picked = []
    while len(picked) < count and any(buckets.values()):
        for name in sorted(buckets):
            if buckets[name] and len(picked) < count:
                picked.append(buckets[name].pop())
    return picked


def lookup_questions(rng: random.Random) -> list[dict]:
    links, categories = corpus()
    eligible = [
        l
        for l in links
        if len(l["description"].split()) >= MIN_DESCRIPTION_WORDS
        and l["category_id"] in categories
    ]
    sample = stratified(
        eligible, lambda l: top_level(categories[l["category_id"]]), LOOKUP_COUNT, rng
    )

    prompts = [
        "A website listed in a web directory:\n"
        f"Title: {l['title']}\nDescription: {l['description']}\n"
        f"Category: {' > '.join(categories[l['category_id']]['path'][1:])}\n\n"
        "Write the search query a person would type when looking for a site like this, 4 to 10 words. "
        "Describe the need; never use the site's name, brand, or URL. Reply with only the query."
        for l in sample
    ]
    queries = complete(prompts, max_tokens=32)

    return [
        {
            "qid": f"lookup-{i}",
            "task": "lookup",
            "query": q.strip().strip('"'),
            "gold_link": l["id"],
            "gold_category": l["category_id"],
        }
        for i, (l, q) in enumerate(zip(sample, queries))
    ]


def coverage_questions(rng: random.Random) -> list[dict]:
    _, categories = corpus()
    children = defaultdict(list)
    for c in categories.values():
        children[c["parent_id"]].append(c)

    eligible = []
    for c in categories.values():
        populated = [
            k for k in children[c["id"]] if k["link_count_subtree"] >= MIN_CHILD_LINKS
        ]
        if (
            MIN_CHILDREN <= len(populated) <= MAX_CHILDREN
            and MIN_SUBTREE_LINKS <= c["link_count_subtree"] <= MAX_SUBTREE_LINKS
        ):
            eligible.append((c, populated))
    sample = stratified(eligible, lambda pair: top_level(pair[0]), COVERAGE_COUNT, rng)

    prompts = [
        f"Topic: {c['name']} (within {' > '.join(c['path'][1:-1]) or 'the directory'}).\n"
        "Write one broad question asking what kinds of websites and resources exist about this topic. "
        "Reply with only the question."
        for c, _ in sample
    ]
    queries = complete(prompts, max_tokens=40)

    return [
        {
            "qid": f"coverage-{i}",
            "task": "coverage",
            "query": q.strip().strip('"'),
            "category": c["id"],
            "gold_children": [k["id"] for k in populated],
        }
        for i, ((c, populated), q) in enumerate(zip(sample, queries))
    ]


def main() -> None:
    rng = random.Random(SEED)
    questions = lookup_questions(rng) + coverage_questions(rng)
    write_jsonl(OUT / "questions.jsonl", questions)
    print(f"wrote {len(questions)} questions")


if __name__ == "__main__":
    main()
