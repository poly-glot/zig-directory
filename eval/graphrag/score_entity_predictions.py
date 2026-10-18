import json
import sys

from entity_bakeoff import HERE, score


def main() -> None:
    sample = {
        r["id"]: r for r in map(json.loads, (HERE / "entity_sample.jsonl").open())
    }
    gold = {r["id"]: r for r in map(json.loads, (HERE / "entity_gold.jsonl").open())}
    preds = {r["id"]: r for r in map(json.loads, open(sys.argv[1]))}
    result = score(sys.argv[1], preds, gold, sample)
    for field in ("countries", "religions", "people", "orgs"):
        p, r, f = result[field]
        print(f"{field:10} P/R/F1 {p:.2f}/{r:.2f}/{f:.2f}")


if __name__ == "__main__":
    main()
