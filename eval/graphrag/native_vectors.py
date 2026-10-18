import json

import numpy as np

from common import INDEX, OUT, corpus, read_jsonl
from hybrid_design_check import QUERY_PREFIX, onnx_embedder


def main() -> None:
    links, _ = corpus()
    vectors = np.load(INDEX / "link_vectors_onnx.npy").astype("<f4")
    assert len(vectors) == len(links)
    vectors.tofile(INDEX / "link_vectors_onnx.f32")
    (INDEX / "link_vector_ids.json").write_text(
        json.dumps(
            [
                {"id": l["id"], "title": l["title"], "description": l["description"]}
                for l in links
            ]
        )
    )

    questions = read_jsonl(OUT / "questions.jsonl") + read_jsonl(
        OUT / "multihop_questions.jsonl"
    )
    query_vectors = onnx_embedder()([QUERY_PREFIX + q["query"] for q in questions])
    with (OUT / "query_vectors.jsonl").open("w") as f:
        for q, v in zip(questions, query_vectors):
            f.write(json.dumps({"qid": q["qid"], "vector": v.tolist()}) + "\n")
    print(f"exported {len(links)} link vectors and {len(questions)} query vectors")


if __name__ == "__main__":
    main()
