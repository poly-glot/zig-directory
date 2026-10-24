import json
import re
import statistics
from collections import Counter, defaultdict
from pathlib import Path

DATA = Path(__file__).parent / "data"
OUT = Path(__file__).parent / "out"

cats = {c["id"]: c for c in map(json.loads, (DATA / "categories.jsonl").open())}
links = [l for l in map(json.loads, (DATA / "links.jsonl").open())]
entities = {r["id"]: r for r in map(json.loads, (OUT / "entities_dump.jsonl").open())}
parent = {i: c["parent_id"] for i, c in cats.items()}
slug = {i: c["slug"] for i, c in cats.items()}
root = next(i for i, c in cats.items() if c["parent_id"] == 0)


def chain(cid):
    out = []
    while cid in parent and cid != root:
        out.append(cid)
        cid = parent[cid]
    return list(reversed(out))


def spath(cid):
    return "/".join(slug[c] for c in chain(cid))


subtree = Counter()
own = Counter(l["category_id"] for l in links)
for cid, n in own.items():
    for a in chain(cid):
        subtree[a] += n

print("LINKS", len(links), "status", Counter(l["status"] for l in links))
print("CATEGORIES", len(cats), "with own links", sum(1 for c in cats if own[c]), "empty leaves", sum(1 for c in cats if own[c] == 0 and not any(parent[x] == c for x in cats)))

print("\n== A. branches (top-level under root)")
for cid in sorted((c for c in cats if parent.get(c) == root), key=lambda c: -subtree[c]):
    ncat = sum(1 for c in cats if cid in chain(c))
    print(f"  {slug[cid]:28s} links={subtree[cid]:6d} categories={ncat:6d}")

print("\n== B. depth of link categories")
depth = Counter(len(chain(l["category_id"])) for l in links)
for d in sorted(depth):
    print(f"  depth {d}: {depth[d]} links")

print("\n== C. recurring slugs = DMOZ facet vocabulary (slug repeated across the tree, with link mass)")
slug_count = Counter(slug[c] for c in cats)
slug_links = Counter()
for l in links:
    slug_links[slug[l["category_id"]]] += 1
letter = re.compile(r"^[a-z]$|^[a-z]-[a-z]$|^[0-9]$|^[0-9]-[0-9]$")
for s, n in slug_count.most_common(70):
    if letter.match(s):
        continue
    print(f"  {s:40s} nodes={n:5d} own-links={slug_links[s]:5d}")

print("\n== D. structural node kinds (by naming convention) and the links filed directly under them")
kinds = {
    "alphabet bucket": lambda c: bool(letter.match(slug[c])),
    "person (Surname,_Given)": lambda c: bool(re.match(r"^[^,_/]+(_[^,_/]+)?,_[^,]+$", slug[c])) and not re.search(r"\d", slug[c]),
    "title leaf (under titles/)": lambda c: "titles" in [slug[a] for a in chain(c)[:-1]],
    "place (under by_region|regional|by_country|countries)": lambda c: bool({"by_region", "regional", "by_country", "countries", "by_location"} & {slug[a] for a in chain(c)[:-1]}),
    "people/organizations hub": lambda c: slug[c] in {"people", "organizations", "associations", "clubs", "companies", "artists", "bands_and_artists", "authors", "players", "personalities"},
    "page-type node": lambda c: slug[c] in {"personal_pages", "personal_homepages", "chats_and_forums", "news_and_media", "directories", "reviews", "image_galleries", "sound_files", "weblogs", "faqs,_help,_and_tutorials", "fan_pages", "fan_sites", "magazines_and_e-zines", "mailing_lists", "software", "products", "shopping", "education", "history", "humor", "resources", "guides_and_directories", "web_rings", "events", "conferences", "journals", "research", "publications", "employment", "museums", "galleries"},
}
for name, pred in kinds.items():
    nodes = [c for c in cats if pred(c)]
    print(f"  {name:55s} nodes={len(nodes):6d} own-links={sum(own[c] for c in nodes):6d}")

print("\n== E. link text shape")
tl = [len(l["title"]) for l in links]
dl = [len(l["description"]) for l in links]
print(f"  title chars median={statistics.median(tl)} p90={sorted(tl)[int(.9*len(tl))]}; description chars median={statistics.median(dl)} p90={sorted(dl)[int(.9*len(dl))]}")
print(f"  empty description: {sum(1 for d in dl if d == 0)} ({100*sum(1 for d in dl if d == 0)/len(dl):.1f}%)")
print(f"  description <= 60 chars: {sum(1 for d in dl if d <= 60)} ({100*sum(1 for d in dl if d <= 60)/len(dl):.1f}%)")
nonascii = sum(1 for l in links if any(ord(ch) > 127 for ch in l["title"] + l["description"]))
print(f"  non-ASCII in title/description: {nonascii} ({100*nonascii/len(links):.1f}%)")
lang = Counter()
for l in links:
    m = re.search(r"\[([A-Z][a-z]+(?:,? (?:and )?[A-Z][a-z]+)*)\]\s*$", l["description"])
    if m:
        for w in re.findall(r"[A-Z][a-z]+", m.group(1)):
            lang[w] += 1
print(f"  trailing [Language] tags: {sum(lang.values())} tags; top: {lang.most_common(12)}")
first = Counter()
for l in links:
    m = re.match(r"\s*([A-Za-z]+)", l["description"])
    if m:
        first[m.group(1).lower()] += 1
print(f"  first word of description, top 25: {first.most_common(25)}")
page_types = {
    "official site": r"\bofficial (web ?site|site|home ?page|page)\b|\bofficial\b",
    "fan site": r"\bfan ?(site|page|club)\b|\bfans?\b",
    "biography": r"\bbiograph",
    "review(s)": r"\breviews?\b",
    "forum/discussion": r"\bforum|discussion|message board|bulletin board|mailing list|newsgroup",
    "blog/journal/diary": r"\bblog|weblog|journal|diary\b",
    "news": r"\bnews\b",
    "photos/gallery/images": r"\bphoto|gallery|galleries|images?\b|pictures?\b",
    "lyrics/discography/tabs": r"\blyrics|discography|tablature|tabs\b",
    "interview": r"\binterview",
    "history": r"\bhistory\b",
    "filmography/cast/crew": r"\bfilmography|cast\b|crew\b",
    "faq/tutorial/guide/how-to": r"\bfaq|tutorial|guide|how[- ]to\b",
    "shop/buy/sell/order": r"\bshop|store|buy|sell|order online|catalog|products?\b|prices?\b",
    "download/software": r"\bdownload|software|freeware|shareware",
    "organization/association/society": r"\bassociation|society|organization|organisation|club|federation|council\b",
    "school/course/education": r"\bschool|course|college|university|education|training\b",
    "personal page": r"\bpersonal (web ?site|site|home ?page|page)|home ?page\b",
    "wikipedia/encyclopedia": r"\bwikipedia|encyclop",
    "kids": r"\bkids|children|child\b",
    "quotes": r"\bquot",
    "sound/audio/video": r"\baudio|sound|mp3|video|clips?\b|streaming",
}
print("  page-type cues in title+description:")
for name, pat in page_types.items():
    r = re.compile(pat, re.I)
    n = sum(1 for l in links if r.search(l["title"] + " " + l["description"]))
    print(f"    {name:36s} {n:6d} ({100*n/len(links):.1f}%)")

print("\n== F. ambiguity (what a one- or two-word query runs into)")
name_parents = defaultdict(set)
for c in cats.values():
    if own[c["id"]] or subtree[c["id"]]:
        name_parents[c["name"].lower()].add(parent[c["id"]])
multi = {n: p for n, p in name_parents.items() if len(p) >= 2}
print(f"  category names used under >=2 different parents (with links): {len(multi)} of {len(name_parents)}")
print("  most reused non-structural names:", [(n, len(p)) for n, p in sorted(multi.items(), key=lambda kv: -len(kv[1])) if not letter.match(n)][:25])
person_nodes = [c for c in cats if kinds["person (Surname,_Given)"](c)]
surname = Counter(slug[c].split(",")[0] for c in person_nodes)
given = Counter()
for c in person_nodes:
    g = slug[c].split(",_", 1)[1] if ",_" in slug[c] else ""
    for w in g.split("_"):
        if w:
            given[w] += 1
print(f"  person nodes {len(person_nodes)}; distinct surnames {len(surname)}; surnames shared by >=2 people: {sum(1 for s, n in surname.items() if n >= 2)}; top: {surname.most_common(10)}")
print(f"  given names shared by >=5 people: {[(g, n) for g, n in given.most_common(40) if n >= 5]}")
people = Counter()
for r in entities.values():
    for p in set(r["people"]):
        people[p.lower()] += 1
print(f"  link_entities: links with any person {sum(1 for r in entities.values() if r['people'])}, org {sum(1 for r in entities.values() if r['orgs'])}, country {sum(1 for r in entities.values() if r['countries'])}, religion {sum(1 for r in entities.values() if r['religions'])}")
print(f"  distinct people {len(people)}; mentioned in >=3 links: {sum(1 for n in people.values() if n >= 3)}; top: {people.most_common(15)}")
single_token_people = Counter(p for p, n in people.items() if " " not in p)
print(f"  single-token person names (ambiguous by construction): {len(single_token_people)} e.g. {list(single_token_people)[:20]}")

print("\n== G. morphology / spelling: tokens whose plural or singular sibling is also indexed")
T = re.compile(r"[a-z0-9]+")
df = Counter()
for l in links:
    df.update(set(T.findall((l["title"] + " " + l["description"]).lower())))
vocab = set(df)
pairs = 0
mass = 0
for t in vocab:
    for sib in (t + "s", t + "es", t[:-1] + "ies" if t.endswith("y") else None):
        if sib and sib in vocab:
            pairs += 1
            mass += min(df[t], df[sib])
            break
print(f"  vocabulary {len(vocab)}; singular/plural pairs {pairs}; link-occurrences stranded on the other form (min side) {mass}")
for w in ["biography", "politician", "poet", "forum", "review", "company", "church", "school", "artist", "university"]:
    print(f"    {w}:{df[w]}  {w}s:{df[w + 's']}  {w[:-1] + 'ies' if w.endswith('y') else w + 'es'}:{df[w[:-1] + 'ies' if w.endswith('y') else w + 'es']}")

print("\n== H. places: category names that are countries or cities (gazetteer-free heuristic: nodes under by_region/regional)")
place_nodes = [c for c in cats if kinds["place (under by_region|regional|by_country|countries)"](c)]
print(f"  place-scoped nodes {len(place_nodes)}, links under them {sum(own[c] for c in place_nodes)}")
print("  top place slugs:", Counter(slug[c] for c in place_nodes).most_common(20))

print("\n== I. what the title says vs the category says (how often the topic word is only in the path)")
missing = 0
sample = 0
for l in links:
    ch = chain(l["category_id"])
    if len(ch) < 3:
        continue
    topic = slug[ch[-2]] if letter.match(slug[ch[-1]]) else slug[ch[-1]]
    words = [w for w in re.split(r"[_,]+", topic) if len(w) > 3 and w not in {"and", "the", "titles", "people"}]
    if not words:
        continue
    sample += 1
    text = (l["title"] + " " + l["description"]).lower()
    if not any(w in text for w in words):
        missing += 1
print(f"  of {sample} links, {missing} ({100*missing/sample:.1f}%) mention none of their own leaf-category words in title+description")
