import json
import re
from functools import cache
from pathlib import Path

import mlx.core as mx
import numpy as np

ROOT = Path(__file__).parent
DATA = ROOT / "data"
INDEX = DATA / "index"
OUT = ROOT / "out"

EMBED_MODEL = "mlx-community/bge-small-en-v1.5-bf16"
LLM_MODEL = "mlx-community/Qwen3-8B-4bit"
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
EMBED_BATCH = 256
EMBED_MAX_TOKENS = 96
LLM_BATCH = 16


def read_jsonl(path: Path) -> list[dict]:
    with path.open() as f:
        return [json.loads(line) for line in f if line.strip()]


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")


@cache
def corpus() -> tuple[list[dict], dict[int, dict]]:
    links = [l for l in read_jsonl(DATA / "links.jsonl") if l["status"] == "approved"]
    categories = {c["id"]: c for c in read_jsonl(DATA / "categories.jsonl")}
    return links, categories


def link_text(link: dict) -> str:
    return f"{link['title']}. {link['description']}".strip()


@cache
def _embedder():
    from mlx_embeddings.utils import load

    return load(EMBED_MODEL)


def embed(texts: list[str], is_query: bool = False) -> np.ndarray:
    model, tokenizer = _embedder()
    prefix = QUERY_PREFIX if is_query else ""
    chunks = []

    for start in range(0, len(texts), EMBED_BATCH):
        batch = [prefix + t for t in texts[start : start + EMBED_BATCH]]
        enc = tokenizer._tokenizer(
            batch,
            return_tensors="np",
            padding=True,
            truncation=True,
            max_length=EMBED_MAX_TOKENS,
        )
        out = model(
            mx.array(enc["input_ids"]), attention_mask=mx.array(enc["attention_mask"])
        )

        cls = out.last_hidden_state[:, 0, :]
        cls = cls / mx.linalg.norm(cls, axis=1, keepdims=True)
        chunks.append(np.array(cls.astype(mx.float32)))

    return np.concatenate(chunks) if chunks else np.zeros((0, 384), dtype=np.float32)


@cache
def _llm():
    from mlx_lm import load

    return load(LLM_MODEL)


def complete(
    prompts: list[str], max_tokens: int = 160, batch: int = LLM_BATCH
) -> list[str]:
    from mlx_lm import batch_generate

    model, tokenizer = _llm()
    encoded = [
        tokenizer.apply_chat_template(
            [{"role": "user", "content": p}],
            add_generation_prompt=True,
            enable_thinking=False,
        )
        for p in prompts
    ]
    texts: list[str] = []

    for start in range(0, len(encoded), batch):
        response = batch_generate(
            model, tokenizer, encoded[start : start + batch], max_tokens=max_tokens
        )
        texts.extend(t.strip() for t in response.texts)

    return texts


def parse_json(text: str):
    match = re.search(r"\{.*\}|\[.*\]", text, re.DOTALL)
    if not match:
        return None
    try:
        return json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
