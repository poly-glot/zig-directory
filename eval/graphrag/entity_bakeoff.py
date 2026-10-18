import itertools
import json
import re
import time
import unicodedata
from collections import defaultdict
from pathlib import Path

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

from common import complete, parse_json
from graph_facts import COUNTRY_BY_NAME, Graph, cctld_country, split_url

HERE = Path(__file__).parent
GEO = HERE / "data" / "geonames"
NER_MODEL = HERE / "data" / "ner-model"
OUT = HERE / "out"

AMBIGUITY_RATIO = 0.5
MAX_NGRAM = 4
LLM_MAX_TOKENS = 240
COMMON_WORD_MIN = 25
LANGUAGE_CONTEXT_BEFORE = {"in", "into"}
LANGUAGE_CONTEXT_AFTER = {
    "text",
    "texts",
    "version",
    "translation",
    "translations",
    "language",
    "languages",
    "subtitles",
    "type",
    "style",
    "revival",
    "rite",
}

RELIGION_TERMS = {
    "islam": "islam islamic muslim muslims mosque mosques quran koran sufi sufism sufis halal imam hadith ramadan sharia madrasa allah",
    "christianity": "christian christians christianity church churches catholic catholics protestant baptist methodist lutheran presbyterian anglican episcopal bible biblical gospel jesus christ pope bishop archbishop diocese archdiocese parish priest pastor evangelical pentecostal nazarene seminary sermons sermon canon ecclesiastical jesuit benedictine franciscan dominican dominicans liturgy testament epistle apostle rosary eucharist sacrament sacraments baptism congregational reformed theology theologian monastery nuns",
    "judaism": "jewish judaism jews synagogue torah talmud rabbi rebbe hasidic chassidic chasidic kosher rosh hashana hashanah yom kippur passover tanakh kabbalah",
    "buddhism": "buddhism buddhist buddhists buddha dharma sangha theravada mahayana zen vipassana nichiren",
    "hinduism": "hindu hindus hinduism vedic vedas krishna shiva vishnu bhagavad",
    "sikhism": "sikh sikhs sikhism gurdwara",
    "taoism": "taoism taoist daoism daoist",
    "jainism": "jain jains jainism",
    "bahai": "bahai baha'i",
    "shinto": "shinto",
    "paganism": "pagan pagans paganism wicca wiccan druid druidry",
}
TERM_RELIGION = {
    term: religion
    for religion, terms in RELIGION_TERMS.items()
    for term in terms.split()
}

DEMONYMS = {
    "Afghan": "AF",
    "Albanian": "AL",
    "Algerian": "DZ",
    "American": "US",
    "Argentine": "AR",
    "Argentinian": "AR",
    "Armenian": "AM",
    "Australian": "AU",
    "Austrian": "AT",
    "Bangladeshi": "BD",
    "Belgian": "BE",
    "Bolivian": "BO",
    "Brazilian": "BR",
    "British": "GB",
    "Bulgarian": "BG",
    "Cambodian": "KH",
    "Canadian": "CA",
    "Chilean": "CL",
    "Chinese": "CN",
    "Colombian": "CO",
    "Croatian": "HR",
    "Cuban": "CU",
    "Czech": "CZ",
    "Danish": "DK",
    "Dutch": "NL",
    "Egyptian": "EG",
    "English": "GB",
    "Estonian": "EE",
    "Ethiopian": "ET",
    "Filipino": "PH",
    "Finnish": "FI",
    "Flemish": "BE",
    "French": "FR",
    "German": "DE",
    "Ghanaian": "GH",
    "Greek": "GR",
    "Hungarian": "HU",
    "Icelandic": "IS",
    "Indian": "IN",
    "Indonesian": "ID",
    "Iranian": "IR",
    "Iraqi": "IQ",
    "Irish": "IE",
    "Israeli": "IL",
    "Italian": "IT",
    "Jamaican": "JM",
    "Japanese": "JP",
    "Jordanian": "JO",
    "Kenyan": "KE",
    "Korean": "KR",
    "Latvian": "LV",
    "Lebanese": "LB",
    "Lithuanian": "LT",
    "Malaysian": "MY",
    "Maltese": "MT",
    "Mexican": "MX",
    "Mongolian": "MN",
    "Moroccan": "MA",
    "Nepalese": "NP",
    "Nigerian": "NG",
    "Norwegian": "NO",
    "Pakistani": "PK",
    "Palestinian": "PS",
    "Peruvian": "PE",
    "Pinoy": "PH",
    "Pinay": "PH",
    "Polish": "PL",
    "Portuguese": "PT",
    "Romanian": "RO",
    "Russian": "RU",
    "Saudi": "SA",
    "Scottish": "GB",
    "Serbian": "RS",
    "Singaporean": "SG",
    "Slovak": "SK",
    "Slovenian": "SI",
    "Spanish": "ES",
    "Swedish": "SE",
    "Swiss": "CH",
    "Syrian": "SY",
    "Taiwanese": "TW",
    "Thai": "TH",
    "Turkish": "TR",
    "Ukrainian": "UA",
    "Venezuelan": "VE",
    "Vietnamese": "VN",
    "Welsh": "GB",
}
US_STATES = {
    "AL",
    "AK",
    "AZ",
    "AR",
    "CA",
    "CO",
    "CT",
    "DE",
    "FL",
    "GA",
    "HI",
    "ID",
    "IL",
    "IN",
    "IA",
    "KS",
    "KY",
    "LA",
    "ME",
    "MD",
    "MA",
    "MI",
    "MN",
    "MS",
    "MO",
    "MT",
    "NE",
    "NV",
    "NH",
    "NJ",
    "NM",
    "NY",
    "NC",
    "ND",
    "OH",
    "OK",
    "OR",
    "PA",
    "RI",
    "SC",
    "SD",
    "TN",
    "TX",
    "UT",
    "VT",
    "VA",
    "WA",
    "WV",
    "WI",
    "WY",
    "DC",
}
CA_PROVINCES = {
    "AB",
    "BC",
    "MB",
    "NB",
    "NL",
    "NS",
    "NT",
    "NU",
    "ON",
    "PE",
    "QC",
    "SK",
    "YT",
}
STATE_AFTER_COMMA = re.compile(r",\s*([A-Z]{2})\b")
CAPITALISED_STOPWORDS = {
    "The",
    "A",
    "An",
    "And",
    "Of",
    "In",
    "On",
    "For",
    "With",
    "From",
    "By",
    "To",
    "At",
    "Includes",
    "Offers",
    "Features",
    "Provides",
    "Information",
    "Official",
    "Home",
    "Page",
    "Online",
    "Contact",
    "News",
    "Services",
    "Union",
    "Liberty",
    "Independence",
    "Victoria",
    "Reading",
    "Mobile",
    "Bath",
    "Nice",
    "Hope",
    "Orange",
    "Florence",
    "Phoenix",
    "Normal",
    "March",
    "Commerce",
    "Enterprise",
    "Paradise",
    "Mission",
    "Dream",
    "Fever",
    "Trinity",
    "Mesa",
    "Rochester",
    "Lincoln",
    "Washington",
    "Jackson",
    "Columbus",
    "Franklin",
    "Clinton",
}
CONNECTORS = {
    "of",
    "de",
    "la",
    "le",
    "du",
    "del",
    "da",
    "am",
    "an",
    "im",
    "upon",
    "sur",
    "on",
}
WORD = re.compile(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'.-]*")


def fold(text: str) -> str:
    return (
        unicodedata.normalize("NFKD", text)
        .encode("ascii", "ignore")
        .decode()
        .lower()
        .strip(" .,'-")
    )


class Gazetteer:
    def __init__(self, cities: str = "cities15000.txt", counties: bool = False) -> None:
        self.places: dict[str, dict[str, float]] = defaultdict(dict)
        for name, code in COUNTRY_BY_NAME.items():
            self.add(name, code, 1e10)
        for line in (GEO / "admin1CodesASCII.txt").read_text().splitlines():
            key, name, ascii_name, _ = line.split("\t")
            for value in (name, ascii_name):
                self.add(value, key.split(".")[0], 1e9)
        if counties:
            for line in (GEO / "admin2Codes.txt").read_text().splitlines():
                key, name, ascii_name, _ = line.split("\t")
                for value in (name, ascii_name):
                    self.add(value, key.split(".")[0], 1e5)
        for line in (GEO / cities).read_text().splitlines():
            cols = line.split("\t")
            for value in (cols[1], cols[2]):
                self.add(value, cols[8], float(cols[14] or 0))

    def add(self, name: str, code: str, weight: float) -> None:
        key = fold(name)
        if key:
            self.places[key][code] = max(weight, self.places[key].get(code, 0))

    def candidates(self, name: str) -> dict[str, float]:
        return self.places.get(fold(name), {})


def resolve(candidates: dict[str, float], context: set[str]) -> str | None:
    if not candidates:
        return None
    in_context = {c: w for c, w in candidates.items() if c in context}
    pool = in_context or candidates
    ranked = sorted(pool.items(), key=lambda kv: -kv[1])
    if len(ranked) > 1 and ranked[1][1] >= AMBIGUITY_RATIO * ranked[0][1]:
        return None
    return ranked[0][0]


def state_countries(text: str) -> set[str]:
    found = set()
    for code in STATE_AFTER_COMMA.findall(text):
        if code in US_STATES:
            found.add("US")
        elif code in CA_PROVINCES:
            found.add("CA")
    return found


def religions_in(text: str) -> set[str]:
    words = re.findall(r"[a-z']+", text.lower())
    pairs = {f"{a} {b}" for a, b in itertools.pairwise(words)}
    return {TERM_RELIGION[w] for w in [*words, *pairs] if w in TERM_RELIGION}


def resolve_places(gaz: Gazetteer, names: list[str], context: set[str]) -> set[str]:
    resolved, unambiguous = set(), set()
    for name in names:
        candidates = gaz.candidates(name)
        if len(candidates) == 1:
            unambiguous |= set(candidates)
    for name in names:
        parts = [name, *[p.strip() for p in name.split(",") if p.strip()]]
        for part in parts:
            code = resolve(gaz.candidates(part), context | unambiguous)
            if code:
                resolved.add(code)
                break
    return resolved


TOKEN = re.compile(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'.-]*")


def common_words() -> set[str]:
    counts: dict[str, int] = defaultdict(int)
    for link in map(json.loads, (HERE / "data" / "graph" / "links.jsonl").open()):
        for word in re.findall(
            r"\b[a-z][a-z'-]+\b", f"{link['title']} {link['description']}"
        ):
            counts[word] += 1
    return {w for w, n in counts.items() if n >= COMMON_WORD_MIN}


def capitalised_spans(
    text: str,
    gaz: Gazetteer,
    common: set[str] = frozenset(),
    blocked: list[tuple[int, int]] = (),
) -> list[str]:
    tokens = [(m.group(0), m.start(), m.end()) for m in TOKEN.finditer(text)]
    spans, i = [], 0
    while i < len(tokens):
        matched = 0
        for n in range(MAX_NGRAM, 0, -1):
            chunk = tokens[i : i + n]
            words = [w for w, _, _ in chunk]
            if (
                len(chunk) < n
                or not words[0][0].isupper()
                or not words[-1][0].isupper()
            ):
                continue
            if any(not (w[0].isupper() or w in CONNECTORS) for w in words):
                continue
            span = " ".join(words)
            if n == 1 and (span in CAPITALISED_STOPWORDS or fold(span) in common):
                continue
            start, end = chunk[0][1], chunk[-1][2]
            if any(b_start <= start and end <= b_end for b_start, b_end in blocked):
                continue
            if gaz.candidates(span):
                spans.append(span)
                matched = n
                break
        i += matched or 1
    return spans


def contextual_demonym_countries(text: str) -> set[str]:
    words = TOKEN.findall(text)
    found = set()
    for i, word in enumerate(words):
        code = DEMONYMS.get(word.rstrip(".,"))
        if not code:
            continue
        before = words[i - 1].lower() if i else ""
        after = words[i + 1].lower().rstrip(".,") if i + 1 < len(words) else ""
        neighbours = {
            w.rstrip(".,") for w in words[max(0, i - 3) : i + 4] if w is not word
        }
        if before in LANGUAGE_CONTEXT_BEFORE or after in LANGUAGE_CONTEXT_AFTER:
            continue
        if neighbours & set(DEMONYMS):
            continue
        found.add(code)
    return found


def demonym_countries(words: list[str]) -> set[str]:
    return {DEMONYMS[w] for w in words if w in DEMONYMS}


class BertNer:
    def __init__(self) -> None:
        self.tokenizer = Tokenizer.from_file(str(NER_MODEL / "tokenizer.json"))
        self.tokenizer.enable_truncation(256)
        self.session = ort.InferenceSession(
            str(NER_MODEL / "onnx" / "model_quantized.onnx"),
            providers=["CPUExecutionProvider"],
        )
        self.labels = json.loads((NER_MODEL / "config.json").read_text())["id2label"]
        self.inputs = {i.name for i in self.session.get_inputs()}

    def entities(self, text: str) -> list[tuple[str, str]]:
        return [(kind, text[s:e]) for kind, s, e in self.spans(text)]

    def spans(self, text: str) -> list[tuple[str, int, int]]:
        enc = self.tokenizer.encode(text)
        feeds = {
            "input_ids": np.array([enc.ids], dtype=np.int64),
            "attention_mask": np.array([enc.attention_mask], dtype=np.int64),
            "token_type_ids": np.array([enc.type_ids], dtype=np.int64),
        }
        logits = self.session.run(
            None, {k: v for k, v in feeds.items() if k in self.inputs}
        )[0][0]
        found, current = [], None
        for label_id, (start, end), token in zip(
            logits.argmax(-1), enc.offsets, enc.tokens, strict=True
        ):
            if start == end:
                current = None
                continue
            if token.startswith("##") and current is not None:
                current[2] = end
                continue
            label = self.labels[str(int(label_id))]
            if label == "O":
                current = None
                continue
            kind = label[2:]
            if current is not None and current[0] == kind and label.startswith("I-"):
                current[2] = end
                continue
            current = [kind, start, end]
            found.append(current)
        return [(kind, s, e) for kind, s, e in found]


def norm(name: str) -> str:
    text = re.sub(r"[^a-z0-9 ]", " ", fold(name))
    words = [
        w for w in text.split() if w not in {"the", "inc", "ltd", "llc", "llp", "co"}
    ]
    return " ".join(words)


def entity_matches(pred: set[str], gold: set[str]) -> int:
    hits, remaining = 0, set(gold)
    for p in pred:
        hit = next(
            (g for g in remaining if p and g and (p == g or p in g or g in p)), None
        )
        if hit:
            hits += 1
            remaining.discard(hit)
    return hits


def prf(tp: int, n_pred: int, n_gold: int) -> tuple[float, float, float]:
    p = tp / n_pred if n_pred else 0.0
    r = tp / n_gold if n_gold else 0.0
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)


def score(
    name: str, preds: dict[int, dict], gold: dict[int, dict], sample: dict[int, dict]
) -> dict:
    out = {"candidate": name}
    for field in ("countries", "religions"):
        tp = sum(len(set(preds[i][field]) & set(gold[i][field])) for i in gold)
        n_pred = sum(len(set(preds[i][field])) for i in gold)
        n_gold = sum(len(set(gold[i][field])) for i in gold)
        out[field] = prf(tp, n_pred, n_gold)
        for stratum in ("random", "geographic", "religion"):
            ids = [i for i in gold if sample[i]["stratum"] == stratum]
            tp = sum(len(set(preds[i][field]) & set(gold[i][field])) for i in ids)
            out[f"{field}:{stratum}"] = prf(
                tp,
                sum(len(set(preds[i][field])) for i in ids),
                sum(len(set(gold[i][field])) for i in ids),
            )
    for field in ("people", "orgs"):
        tp = n_pred = n_gold = 0
        for i in gold:
            p = {norm(x) for x in preds[i][field]} - {""}
            g = {norm(x) for x in gold[i][field]} - {""}
            tp += entity_matches(p, g)
            n_pred += len(p)
            n_gold += len(g)
        out[field] = prf(tp, n_pred, n_gold)
    return out


def link_context(link: dict, graph: Graph) -> set[str]:
    host, _ = split_url(link["url"])
    context = {cctld_country(host)}
    category = graph.categories_by_link.get(link["id"])
    if category is not None:
        context.add(graph.describe(category)[1])
    return context - {""}


def run_lexicon(rows, gaz, contexts, common=frozenset(), contextual=False):
    preds = {}
    for r in rows:
        text = f"{r['title']}. {r['description']}"
        spans = capitalised_spans(text, gaz, common)
        countries = resolve_places(gaz, spans, contexts[r["id"]]) | state_countries(
            text
        )
        countries |= (
            contextual_demonym_countries(text)
            if contextual
            else demonym_countries(WORD.findall(text))
        )
        preds[r["id"]] = {
            "countries": sorted(countries),
            "religions": sorted(religions_in(text)),
            "people": [],
            "orgs": [],
        }
    return preds


def run_hybrid(rows, gaz, contexts, common, ner):
    preds = {}
    for r in rows:
        text = f"{r['title']}. {r['description']}"
        entities = ner.spans(text)
        people = [(s, e) for kind, s, e in entities if kind == "PER"]
        spans = capitalised_spans(text, gaz, common, people)
        spans += [text[s:e] for kind, s, e in entities if kind == "LOC"]
        countries = resolve_places(gaz, spans, contexts[r["id"]]) | state_countries(
            text
        )
        countries |= contextual_demonym_countries(text)
        preds[r["id"]] = {
            "countries": sorted(countries),
            "religions": sorted(religions_in(text)),
            "people": [text[s:e] for kind, s, e in entities if kind == "PER"],
            "orgs": [text[s:e] for kind, s, e in entities if kind == "ORG"],
        }
    return preds


def from_entities(r, entities, gaz, context):
    text = f"{r['title']}. {r['description']}"
    places = [t for k, t in entities if k in {"LOC", "GPE", "FAC"}]
    cultures = [t for k, t in entities if k in {"MISC", "NORP"}]
    countries = resolve_places(gaz, places, context) | state_countries(text)
    countries |= demonym_countries([w for c in cultures for w in c.split()])
    religions = religions_in(text) | {
        TERM_RELIGION[fold(c)] for c in cultures if fold(c) in TERM_RELIGION
    }
    return {
        "countries": sorted(countries),
        "religions": sorted(religions),
        "people": [t for k, t in entities if k in {"PER", "PERSON"}],
        "orgs": [t for k, t in entities if k == "ORG"],
    }


def run_spacy(rows, gaz, contexts):
    import spacy

    nlp = spacy.load("en_core_web_sm")
    docs = nlp.pipe(f"{r['title']}. {r['description']}" for r in rows)
    return {
        r["id"]: from_entities(
            r, [(e.label_, e.text) for e in doc.ents], gaz, contexts[r["id"]]
        )
        for r, doc in zip(rows, docs, strict=True)
    }


def run_bert(rows, gaz, contexts):
    ner = BertNer()
    return {
        r["id"]: from_entities(
            r, ner.entities(f"{r['title']}. {r['description']}"), gaz, contexts[r["id"]]
        )
        for r in rows
    }


LLM_PROMPT = (
    "Extract named entities from this web directory listing. Reply with JSON only, shaped like "
    '{{"people": [], "orgs": [], "places": [{{"name": "", "country": ""}}], '
    '"cultures": [{{"name": "", "country": ""}}], "religions": []}}.\n'
    "Rules: list only what the text states or clearly implies. A place's country is the ISO 3166 alpha-2 "
    "code of the country it is in; leave it empty when the place is ambiguous. cultures are nationalities or "
    "ethnic groups as written, not languages. religions are those the listing is about or belongs to, such as "
    "a church or bible study for christianity, a mosque for islam, a synagogue for judaism; use only these ids: "
    "islam, christianity, judaism, hinduism, buddhism, sikhism, taoism, jainism, bahai, shinto, paganism.\n"
    "Listing: {title}. {description}"
)


def llm_replies(rows) -> list[str]:
    return complete(
        [
            LLM_PROMPT.format(title=r["title"], description=r["description"])
            for r in rows
        ],
        max_tokens=LLM_MAX_TOKENS,
    )


def llm_predictions(rows, replies, gaz, contexts, resolve_with_gazetteer: bool):
    preds = {}
    for r, reply in zip(rows, replies, strict=True):
        data = parse_json(reply) or {}
        places = [p for p in data.get("places", []) if isinstance(p, dict)]
        cultures = [c for c in data.get("cultures", []) if isinstance(c, dict)]
        if resolve_with_gazetteer:
            countries = resolve_places(
                gaz, [str(p.get("name", "")) for p in places], contexts[r["id"]]
            )
            countries |= demonym_countries([str(c.get("name", "")) for c in cultures])
        else:
            countries = {
                str(x.get("country", "")).upper() for x in [*places, *cultures]
            }
        preds[r["id"]] = {
            "countries": sorted(c for c in countries if len(c) == 2),
            "religions": sorted(
                {str(x).lower() for x in data.get("religions", [])}
                & set(RELIGION_TERMS)
            ),
            "people": [str(x) for x in data.get("people", [])],
            "orgs": [str(x) for x in data.get("orgs", [])],
        }
    return preds


def main() -> None:
    sample = {
        r["id"]: r for r in map(json.loads, (HERE / "entity_sample.jsonl").open())
    }
    gold = {r["id"]: r for r in map(json.loads, (HERE / "entity_gold.jsonl").open())}
    rows = [sample[i] for i in sorted(sample)]

    graph = Graph()
    graph.categories_by_link = {link["id"]: link["category_id"] for link in graph.links}
    with_graph = {r["id"]: link_context(r, graph) for r in rows}
    without_graph = {r["id"]: set() for r in rows}
    gaz = Gazetteer()
    big = Gazetteer("cities1000.txt", counties=True)
    common = common_words()
    ner = BertNer()

    results, timings = [], {}
    candidates = [
        ("lexicon", lambda c: run_lexicon(rows, gaz, c)),
        ("lexicon-v2", lambda c: run_lexicon(rows, big, c, common, contextual=True)),
        ("spacy-sm", lambda c: run_spacy(rows, gaz, c)),
        ("bert-ner", lambda c: run_bert(rows, gaz, c)),
        ("hybrid", lambda c: run_hybrid(rows, big, c, common, ner)),
    ]
    for name, run in candidates:
        for label, contexts in (("", without_graph), ("+graph", with_graph)):
            started = time.perf_counter()
            preds = run(contexts)
            timings[name] = (time.perf_counter() - started) / len(rows) * 1000
            results.append(score(name + label, preds, gold, sample))
    hybrid_preds = run_hybrid(rows, big, with_graph, common, ner)

    started = time.perf_counter()
    replies = llm_replies(rows)
    timings["qwen3-8b"] = (time.perf_counter() - started) / len(rows) * 1000
    llm_own = llm_predictions(rows, replies, big, with_graph, False)
    results.append(score("qwen3-8b", llm_own, gold, sample))
    results.append(
        score(
            "qwen3-8b+gazetteer+graph",
            llm_predictions(rows, replies, big, with_graph, True),
            gold,
            sample,
        )
    )
    combined = {
        i: {
            **llm_own[i],
            "religions": sorted(
                set(llm_own[i]["religions"]) | set(hybrid_preds[i]["religions"])
            ),
        }
        for i in llm_own
    }
    results.append(score("qwen3-8b + lexicon religions", combined, gold, sample))

    OUT.mkdir(exist_ok=True)
    (OUT / "entity_bakeoff.json").write_text(
        json.dumps({"results": results, "ms_per_link": timings}, indent=1)
    )
    (OUT / "entity_llm_replies.jsonl").write_text(
        "\n".join(
            json.dumps({"id": r["id"], "reply": t})
            for r, t in zip(rows, replies, strict=True)
        )
        + "\n"
    )

    print(
        f"{'candidate':28} {'countries P/R/F1':22} {'religions P/R/F1':22} {'people F1':10} {'orgs F1':8}"
    )
    for res in results:
        c, g, p, o = res["countries"], res["religions"], res["people"], res["orgs"]
        print(
            f"{res['candidate']:28} {c[0]:.2f}/{c[1]:.2f}/{c[2]:.2f}{'':8} {g[0]:.2f}/{g[1]:.2f}/{g[2]:.2f}{'':8} {p[2]:.2f}{'':6} {o[2]:.2f}"
        )
    print("ms per link:", {k: round(v, 1) for k, v in timings.items()})


if __name__ == "__main__":
    main()
