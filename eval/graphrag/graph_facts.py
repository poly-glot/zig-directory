import json
import re
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
DATA = HERE / "data" / "graph"
OUT = HERE / "out"
COUNTRIES_TSV = HERE.parent.parent / "src" / "facts" / "countries.tsv"

PUBLIC_SECOND_LEVELS = {
    "ac",
    "asn",
    "biz",
    "co",
    "com",
    "edu",
    "gen",
    "go",
    "gob",
    "gouv",
    "gov",
    "id",
    "info",
    "k12",
    "lg",
    "ltd",
    "me",
    "mil",
    "ne",
    "net",
    "nhs",
    "nic",
    "nom",
    "or",
    "org",
    "plc",
    "police",
    "res",
    "sch",
    "tm",
}
VANITY_CCTLDS = {
    "ac",
    "ag",
    "ai",
    "am",
    "cc",
    "co",
    "eu",
    "fm",
    "gg",
    "io",
    "la",
    "ly",
    "md",
    "me",
    "ms",
    "nu",
    "sh",
    "su",
    "tk",
    "to",
    "tv",
    "vc",
    "ws",
}
PATH_PLATFORMS = {
    "members.tripod.com": (None, 1),
    "angelfire.com": (None, 2),
    "groups.yahoo.com": ("group", 2),
    "sites.google.com": ("site", 2),
    "freewebs.com": (None, 1),
}
SUBDOMAIN_PLATFORMS = {
    "50megs.com",
    "8m.com",
    "blogspot.com",
    "free.fr",
    "freeservers.com",
    "homestead.com",
    "livejournal.com",
    "proboards.com",
    "tripod.com",
    "typepad.com",
    "webs.com",
    "weebly.com",
    "wordpress.com",
}
PARENTS_THAT_FILE_THINGS_BY_NAME = {"Breeds", "Kitchen_and_Dining", "Poultry"}
ALL_EDGES = ["cctld", "category", "entity"]
ENTITIES_DUMP = OUT / "entities_dump.jsonl"
TOKEN = re.compile(rb"[A-Za-z0-9]+")


def load_countries() -> tuple[dict[str, str], set[str]]:
    by_name, codes = {}, set()
    for line in COUNTRIES_TSV.read_text().splitlines():
        code, name = line.split("\t")
        by_name[name] = code
        codes.add(code)
    return by_name, codes


COUNTRY_BY_NAME, ISO_CODES = load_countries()


def split_url(url: str) -> tuple[str, str]:
    rest = url.split("://", 1)[1] if "://" in url else url
    end = min((rest.find(c) for c in "/?#" if c in rest), default=len(rest))
    authority = rest[:end].rsplit("@", 1)[-1].split(":", 1)[0].rstrip(".")
    path = rest[end:]
    path_end = min((path.find(c) for c in "?#" if c in path), default=len(path))
    return authority[:64].lower(), path[:path_end]


def bare_host(host: str) -> str:
    return host.removeprefix("www.")


def registrable_domain(host: str) -> str:
    labels = host.split(".")
    if len(labels) < 2:
        return host
    if len(labels[-1]) == 2 and labels[-2] in PUBLIC_SECOND_LEVELS:
        return ".".join(labels[-3:]) if len(labels) >= 3 else host
    return ".".join(labels[-2:])


def has_suffix(host: str, suffix: str) -> bool:
    return host == suffix or host.endswith("." + suffix)


def cctld_country(host: str) -> str:
    if "." not in host:
        return ""
    tld = host.rsplit(".", 1)[1]
    if len(tld) != 2 or tld in VANITY_CCTLDS:
        return ""
    if tld == "uk":
        return "GB"
    return tld.upper() if tld.upper() in ISO_CODES else ""


def site_of(host: str, path: str) -> tuple[str, bool]:
    bare = bare_host(host)
    segments = [s for s in path.split("/") if s][:2]
    if segments and len(segments[0]) > 1 and segments[0][0] == "~":
        return f"{bare}/{segments[0]}", True
    if bare in PATH_PLATFORMS:
        leading, depth = PATH_PLATFORMS[bare]
        if len(segments) >= depth and (leading is None or segments[0] == leading):
            return "/".join([bare, *segments[:depth]]), True
        return bare, False
    domain = registrable_domain(host)
    if domain in SUBDOMAIN_PLATFORMS and bare != domain:
        return bare, True
    return domain, False


def fold_name(name: str) -> str:
    return "".join(c.lower() if c.isascii() else c for c in name[:64])


def tokens(text: str) -> set[str]:
    return {
        t.decode().lower()[:64]
        for t in TOKEN.findall(text.encode("utf-8", "replace"))
        if len(t) >= 2
    }


class Graph:
    def __init__(self) -> None:
        self.categories = {
            c["id"]: c for c in map(json.loads, (DATA / "categories.jsonl").open())
        }
        self.links = []
        for raw in map(json.loads, (DATA / "links.jsonl").open()):
            host, path = split_url(raw["url"])
            site, hosted = site_of(host, path)
            self.links.append(
                {
                    **raw,
                    "host": host,
                    "domain": registrable_domain(host),
                    "site": site,
                    "hosted": hosted,
                    "cctld": cctld_country(host),
                    "tokens": tokens(raw["title"])
                    | tokens(raw["url"])
                    | tokens(raw["description"]),
                }
            )
        self.views = {}
        self.entities = {}
        self.display = {}
        if ENTITIES_DUMP.exists():
            rows = sorted(map(json.loads, ENTITIES_DUMP.open()), key=lambda r: r["id"])
            for row in rows:
                self.entities[row["id"]] = row
                for name in [*row["people"], *row["orgs"]]:
                    self.display.setdefault(fold_name(name), name)

    def distinct_names(self, entity: dict | None, kind: str) -> list[str]:
        if not entity:
            return []
        return list(dict.fromkeys(self.display[fold_name(n)] for n in entity[kind]))

    def describe(self, category_id: int) -> tuple[list[int], str, int]:
        if category_id in self.views:
            return self.views[category_id]
        chain, country, below, current = [], "", 0, category_id
        while current in self.categories and len(chain) < 64:
            cat = self.categories[current]
            chain.append(current)
            parent = self.categories.get(cat["parent_id"])
            named = COUNTRY_BY_NAME.get(cat["name"].replace("_", " ").lower(), "")
            files_by_name = parent is not None and (
                len(parent["name"]) == 1
                or parent["name"] in PARENTS_THAT_FILE_THINGS_BY_NAME
            )
            if named and not files_by_name:
                country = named
            if cat["parent_id"] == 0 or cat["parent_id"] not in self.categories:
                branch = below or current
                break
            below, current = current, cat["parent_id"]
        else:
            branch = category_id
        self.views[category_id] = (chain, country, branch)
        return self.views[category_id]

    def resolve(self, slug_path: str) -> int:
        current = next(c["id"] for c in self.categories.values() if c["parent_id"] == 0)
        for slug in [s for s in slug_path.split("/") if s]:
            current = next(
                c["id"]
                for c in self.categories.values()
                if c["parent_id"] == current and c["slug"] == slug
            )
        return current

    def query(self, q: dict) -> dict:
        scope = self.resolve(q["category"]) if q.get("category") else 0
        via = q.get("via", ALL_EDGES)
        religions = set(q.get("religions", []))
        wanted = fold_name(q.get("entity", ""))
        status = q.get("status", "approved")
        words = tokens(q.get("words", ""))
        group_by = q.get("groupBy", "none")

        matches, tallies, group_sites = [], defaultdict(int), defaultdict(set)
        for link in self.links:
            if status != "any" and link["status"] != status:
                continue
            if q.get("hostedOnly") and not link["hosted"]:
                continue
            if words:
                hit = (
                    words <= link["tokens"]
                    if q.get("allWords")
                    else words & link["tokens"]
                )
                if not hit:
                    continue
            if q.get("domain") and not has_suffix(
                link["host"], q["domain"].lstrip(".").lower()
            ):
                continue
            entity = self.entities.get(link["id"])
            if religions and not (entity and religions & set(entity["religions"])):
                continue
            named = (
                {fold_name(n) for n in [*entity["people"], *entity["orgs"]]}
                if entity
                else set()
            )
            if wanted and wanted not in named:
                continue
            chain, category_country, branch = self.describe(link["category_id"])
            if scope and scope not in chain:
                continue
            candidates = []
            if "cctld" in via:
                candidates.append(link["cctld"])
            if "category" in via:
                candidates.append(category_country)
            if "entity" in via and entity:
                candidates += entity["countries"]
            ties = []
            for code in candidates:
                if code and code not in ties:
                    ties.append(code)
            if q.get("country") and q["country"] not in ties:
                continue

            matches.append(link)
            keys = {
                "none": [],
                "domain": [link["domain"]],
                "site": [link["site"]],
                "host": [link["host"]],
                "branch": [branch],
                "country": ties,
                "religion": entity["religions"] if entity else [],
                "person": self.distinct_names(entity, "people"),
                "org": self.distinct_names(entity, "orgs"),
            }[group_by]
            for key in keys:
                tallies[key] += 1
                group_sites[key].add(link["site"])

        groups = [
            {
                "label": "" if group_by == "branch" else key,
                "categoryId": key if group_by == "branch" else 0,
                "links": n,
                "sites": len(group_sites[key]),
            }
            for key, n in tallies.items()
        ]
        groups.sort(key=lambda g: (-g["links"], g["label"], g["categoryId"]))
        ids = sorted(link["id"] for link in matches)
        return {
            "total": len(matches),
            "sites": len({m["site"] for m in matches}),
            "hosts": len({m["host"] for m in matches}),
            "domains": len({m["domain"] for m in matches}),
            "groups": groups[: q.get("groupLimit", 10)],
            "ids": ids[: q.get("limit", 20)],
        }


QUESTIONS = [
    (
        "How many sites are hosted on tripod.com?",
        {"domain": "tripod.com", "groupBy": "host", "groupLimit": 3},
    ),
    (
        "Which hosting platforms carry the most personal sites?",
        {"hostedOnly": True, "groupBy": "domain", "groupLimit": 10},
    ),
    (
        "Which branches hold sites on Pakistan's .pk domain?",
        {"domain": "pk", "groupBy": "branch", "groupLimit": 13, "limit": 50},
    ),
    (
        "Links tied to Pakistan by its ccTLD",
        {"country": "PK", "via": ["cctld"], "limit": 50},
    ),
    (
        "Links tied to Pakistan by a category named for it",
        {"country": "PK", "via": ["category"], "limit": 50},
    ),
    (
        "Links tied to Pakistan by domain or category",
        {
            "country": "PK",
            "via": ["cctld", "category"],
            "groupBy": "branch",
            "limit": 50,
        },
    ),
    (
        "Which UK universities have the most listings?",
        {"domain": "ac.uk", "groupBy": "domain", "groupLimit": 5},
    ),
    (
        "Personal anime sites by hosting platform",
        {
            "category": "arts/animation/anime",
            "hostedOnly": True,
            "groupBy": "domain",
            "groupLimit": 6,
        },
    ),
    (
        "Which countries' ccTLDs appear most?",
        {"via": ["cctld"], "groupBy": "country", "groupLimit": 10},
    ),
    (
        "Society links tied to Pakistan that mention Islam",
        {
            "category": "society",
            "country": "PK",
            "via": ["cctld", "category"],
            "words": "islam islamic muslim",
            "limit": 50,
        },
    ),
    (
        "Personal sites in Arts tied to the UK",
        {
            "category": "arts",
            "hostedOnly": True,
            "country": "GB",
            "via": ["cctld", "category"],
            "limit": 50,
        },
    ),
    (
        "Busiest sites on angelfire.com",
        {"domain": "angelfire.com", "groupBy": "site", "groupLimit": 3},
    ),
    (
        "Links tied to Pakistan by any edge, text included",
        {"country": "PK", "groupBy": "branch", "limit": 50},
    ),
    (
        "Links about Islam tied to Pakistan",
        {"country": "PK", "religions": ["islam"], "limit": 50},
    ),
    (
        "Arts links about Islam, grouped by country",
        {"category": "arts", "religions": ["islam"], "groupBy": "country", "limit": 50},
    ),
    (
        "Which religions do Society links name?",
        {"category": "society", "groupBy": "religion", "groupLimit": 11},
    ),
    (
        "Who is named most across the directory?",
        {"groupBy": "person", "groupLimit": 10, "limit": 0},
    ),
    (
        "Which organisations are named most in Arts?",
        {"category": "arts", "groupBy": "org", "groupLimit": 10, "limit": 0},
    ),
    ("Links naming Jamia Farooqia", {"entity": "jamia farooqia", "limit": 50}),
]


def main() -> None:
    graph = Graph()
    gold = [
        {"question": text, "query": q, "answer": graph.query(q)}
        for text, q in QUESTIONS
    ]
    OUT.mkdir(exist_ok=True)
    (OUT / "graph_gold.json").write_text(json.dumps(gold, indent=1))
    for item in gold:
        a = item["answer"]
        print(
            f"{item['question']:58} links={a['total']:5} sites={a['sites']:5} groups={[(g['label'] or g['categoryId'], g['links']) for g in a['groups'][:3]]}"
        )


if __name__ == "__main__":
    main()
