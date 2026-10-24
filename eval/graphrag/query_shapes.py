import json
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from common import corpus, embed  # noqa: E402
from rank_bm25 import BM25Okapi  # noqa: E402

OUT = Path(__file__).parent / "out"
random.seed(7)
N_PER_SHAPE = 300
K = 10
CANDIDATES = 200
RRF_K = 60
TOKEN = re.compile(r"[a-z0-9]+")
STOP = set("a about all an and any are as at be by can categories category count do does find for from get give how i in inside into is it link links list many me my number of on or page pages please section show site sites some subdomain subdomains that the there these this those to under website websites what where which who with within".split())

links, cats = corpus()
row_of = {l["id"]: r for r, l in enumerate(links)}
parent = {i: c["parent_id"] for i, c in cats.items()}
slug = {i: c["slug"] for i, c in cats.items()}
name = {i: c["name"] for i, c in cats.items()}
root = next(i for i, c in cats.items() if c["parent_id"] == 0)
children = defaultdict(list)
for i, p in parent.items():
    children[p].append(i)


def chain(cid):
    out = []
    while cid in parent and cid != root:
        out.append(cid)
        cid = parent[cid]
    return list(reversed(out))


own = defaultdict(list)
for r, l in enumerate(links):
    own[l["category_id"]].append(r)
subtree = defaultdict(list)
for cid, rows in own.items():
    for a in chain(cid):
        subtree[a].extend(rows)

LETTER = re.compile(r"^[a-z]$|^[a-z]-[a-z]$|^[0-9]$|^[0-9]-[0-9]$")
PERSON = re.compile(r"^[^,_/]+(_[^,_/]+)?,_[^,]+$")


def is_person(c):
    return bool(PERSON.match(slug[c])) and not re.search(r"\d", slug[c])


def words(s):
    return " ".join(w for w in re.split(r"[_,]+", s.lower()) if w)


def person_name(c):
    sur, given = slug[c].split(",_", 1)
    return f"{words(given)} {words(sur)}".strip()


PLACE_SEED = {"by_region", "regional", "by_country", "countries", "by_location"}
place_vocab = Counter()
for c in cats:
    if PLACE_SEED & {slug[a] for a in chain(c)[:-1]}:
        place_vocab[slug[c]] += 1
slug_count = Counter(slug[c] for c in cats)
PLACES = {s for s, n in place_vocab.items() if n >= 3 and slug_count[s] >= 10}
ASPECTS = {
    "organizations": "organizations", "news_and_media": "news", "personal_pages": "personal pages", "associations": "associations",
    "chats_and_forums": "forums", "directories": "directories", "software": "software", "fan_pages": "fan sites", "clubs": "clubs",
    "reviews": "reviews", "magazines_and_e-zines": "magazines", "journals": "journals", "education": "education", "breeders": "breeders",
    "publications": "publications", "research": "research", "history": "history", "resources": "resources", "reviews_and_previews": "reviews",
    "image_galleries": "pictures", "weblogs": "blogs", "events": "events", "museums": "museums", "shopping": "shops", "lyrics": "lyrics",
}
STRUCTURAL = set(ASPECTS) | PLACES | {"titles", "people", "works", "by_region", "regional"}


def topic_of(c):
    for a in reversed(chain(c)[:-1]):
        s = slug[a]
        if LETTER.match(s) or s in STRUCTURAL or is_person(a) or s in {"north_america", "europe", "asia", "oceania", "south_america", "africa"}:
            continue
        return words(name[a])
    return ""


print("== role hubs: nodes whose children (or grandchildren through letter buckets) are mostly person nodes")
role_links = Counter()
role_nodes = Counter()
hub_of_person = {}
for c in cats:
    kids = children[c]
    if not kids:
        continue
    leaves = []
    for k in kids:
        if LETTER.match(slug[k]):
            leaves.extend(children[k])
        else:
            leaves.append(k)
    persons = [k for k in leaves if is_person(k)]
    if len(leaves) >= 3 and len(persons) / len(leaves) >= 0.5:
        role_nodes[slug[c]] += 1
        role_links[slug[c]] += sum(len(own[p]) for p in persons)
        for p in persons:
            hub_of_person[p] = c
print(f"  {sum(role_nodes.values())} hub nodes, {len(role_nodes)} distinct role slugs, {sum(role_links.values())} person-page links under them")
for s, n in role_links.most_common(45):
    print(f"    {s:40s} hubs={role_nodes[s]:4d} person-links={n:5d}")

# ---------- query shapes ----------
shapes = defaultdict(list)  # shape -> list of (query, gold_rows)

persons = [c for c in cats if is_person(c) and own[c]]
for c in random.sample(persons, N_PER_SHAPE):
    n = person_name(c)
    shapes["person: given surname"].append((n, own[c]))
    shapes["person: NL 'who is X'"].append((f"who is {n}", own[c]))
    shapes["person: 'X biography'"].append((f"{n} biography", own[c]))

titles = [c for c in cats if "titles" in [slug[a] for a in chain(c)[:-1]] and own[c] and not LETTER.match(slug[c])]
for c in random.sample(titles, N_PER_SHAPE):
    n = words(name[c])
    shapes["title: name"].append((n, own[c]))
    shapes["title: 'X review'"].append((f"{n} review", own[c]))
    shapes["title: NL 'show me sites about X'"].append((f"show me sites about {n}", own[c]))

topics = [c for c in cats if len(own[c]) >= 3 and len(chain(c)) >= 3 and not LETTER.match(slug[c]) and not is_person(c) and slug[c] not in STRUCTURAL and not re.search(r"\d", slug[c])]
for c in random.sample(topics, N_PER_SHAPE):
    n = words(name[c])
    shapes["topic: leaf name"].append((n, own[c]))
    shapes["topic: NL 'what are the links about X'"].append((f"what are the links about {n}", own[c]))
    last = n.split()[-1]
    swapped = (last[:-1] if last.endswith("s") and len(last) > 4 else last + "s")
    shapes["topic: plural/singular swapped"].append((" ".join(n.split()[:-1] + [swapped]), own[c]))
    w = n.split()
    i = random.randrange(len(w))
    if len(w[i]) > 4:
        j = random.randrange(1, len(w[i]) - 1)
        w[i] = w[i][:j] + w[i][j + 1:]
    shapes["topic: one letter dropped"].append((" ".join(w), own[c]))

place_nodes = [c for c in cats if slug[c] in PLACES and subtree[c] and topic_of(c)]
for c in random.sample(place_nodes, N_PER_SHAPE):
    t, p = topic_of(c), words(name[c])
    shapes["topic+place: 'X Y'"].append((f"{t} {p}", subtree[c]))
    shapes["topic+place: NL 'X in Y'"].append((f"{t} in {p}", subtree[c]))

aspect_nodes = [c for c in cats if slug[c] in ASPECTS and subtree[c] and topic_of(c)]
for c in random.sample(aspect_nodes, N_PER_SHAPE):
    t = topic_of(c)
    shapes["topic+aspect: 'X forums'"].append((f"{t} {ASPECTS[slug[c]]}", subtree[c]))

hubs = [(c, s) for c in cats for s in [slug[c]] if role_nodes[s] and any(is_person(k) or LETTER.match(slug[k]) for k in children[c]) and subtree[c] and topic_of(c)]
for c, s in random.sample(hubs, min(N_PER_SHAPE, len(hubs))):
    rows = [r for p, h in hub_of_person.items() if h == c for r in own[p]]
    if not rows:
        continue
    shapes["topic+role: 'jazz saxophonists'"].append((f"{topic_of(c)} {words(s)}", rows))
    shapes["topic+role: NL 'biographies of X Y'"].append((f"biographies of {topic_of(c)} {words(s)}", rows))

# ---------- retrieval ----------
def cached(name, texts):
    path = OUT / f"{name}.npy"
    if path.exists():
        return np.load(path)
    vectors = np.concatenate([embed(texts[s : s + 8192]) for s in range(0, len(texts), 8192)])
    np.save(path, vectors)
    return vectors


def link_text(l):
    return f"{l['title']}. {l['description']}".strip()


cat_ids = [i for i, c in cats.items() if len(c["path"]) > 1]
vec_a = cached("vec_a", [link_text(l) for l in links])
vec_b = cached("vec_b", [f"{' > '.join(cats[l['category_id']]['path'][1:])}. {link_text(l)}" for l in links])
cat_vec = cached("vec_cats", [" > ".join(cats[i]["path"][1:]) for i in cat_ids])
bm25 = BM25Okapi([TOKEN.findall(f"{l['title']} {l['description']} {l['url']}".lower()) for l in links])


def kw(tokens):
    if not tokens:
        return []
    s = bm25.get_scores(tokens)
    top = np.argpartition(-s, CANDIDATES)[:CANDIDATES]
    return [int(r) for r in top[np.argsort(-s[top])] if s[r] > 0]


def vec(m, q):
    s = m @ q
    top = np.argpartition(-s, CANDIDATES)[:CANDIDATES]
    return [int(r) for r in top[np.argsort(-s[top])]]


def rrf(*lists):
    s = defaultdict(float)
    for lst in lists:
        for rank, row in enumerate(lst):
            s[row] += 1.0 / (RRF_K + rank + 1)
    return sorted(s, key=lambda r: -s[r])


def catres(q, n=3):
    s = cat_vec @ q
    top = np.argsort(-s)[:n]
    rows = []
    seen = set()
    for t in top:
        for r in subtree[cat_ids[t]]:
            if r not in seen:
                seen.add(r)
                rows.append(r)
    if not rows:
        return []
    rows = np.array(rows)
    return [int(r) for r in rows[np.argsort(-(vec_b[rows] @ q))]]


CONFIGS = ["prod (bm25 raw + vecA)", "stop (bm25 stop + vecA)", "vecB only", "hybridB stop", "catres top3", "hybridB + catres"]
print(f"\n== hit@{K} (any gold link in top {K}) / P@{K}, {N_PER_SHAPE} generated queries per shape, gold = links of the source node")
print(f"{'shape':42s}" + "".join(f"{c:>26s}" for c in CONFIGS))
for shape, items in shapes.items():
    raw_q = [q for q, _ in items]
    stop_q = [" ".join(t for t in TOKEN.findall(q.lower()) if t not in STOP) or q for q in raw_q]
    qa = embed(raw_q, is_query=True)
    qs = embed(stop_q, is_query=True)
    hits = defaultdict(float)
    prec = defaultdict(float)
    for i, (q, gold) in enumerate(items):
        g = set(gold)
        raw_t = TOKEN.findall(q.lower())
        stop_t = [t for t in raw_t if t not in STOP]
        kr, ks = kw(raw_t), kw(stop_t)
        va, vas, vbs = vec(vec_a, qa[i]), vec(vec_a, qs[i]), vec(vec_b, qs[i])
        cr = catres(qs[i])
        results = {
            "prod (bm25 raw + vecA)": rrf(kr, va),
            "stop (bm25 stop + vecA)": rrf(ks, vas),
            "vecB only": vbs,
            "hybridB stop": rrf(ks, vbs),
            "catres top3": cr,
            "hybridB + catres": rrf(ks, vbs, cr[:CANDIDATES]),
        }
        for c, rows in results.items():
            top = rows[:K]
            hits[c] += any(r in g for r in top)
            prec[c] += sum(1 for r in top if r in g) / K
    n = len(items)
    print(f"{shape:42s}" + "".join(f"{hits[c]/n:>13.2f}{prec[c]/n:>13.2f}" for c in CONFIGS))

json.dump({s: [(q, [links[r]["id"] for r in g][:50]) for q, g in items[:40]] for s, items in shapes.items()}, (OUT / "shape_queries.json").open("w"))
print("\nwrote shape_queries.json (40 per shape) for live validation")
