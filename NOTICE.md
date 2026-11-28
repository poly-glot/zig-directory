# Third-party notices

The code in this repository is under the [MIT licence](LICENSE). This file lists the third-party data and models that
the repository uses or fetches, and what each source says about its own licence. The licence text quoted below was
read from each source's published page on 2026-11-28. If a source changes its terms, the source wins.

Packages installed from the Deno, npm and Python lock files (`web/deno.lock`, `mcp/uv.lock`,
`eval/graphrag/uv.lock`, `e2e/package-lock.json`) keep the licences their authors chose. They are not listed here.

## GeoNames

- **Used for:** the place gazetteer `web/lib/data/gazetteer.tsv`, which the website uses to find places named in a
  link's title and description.
- **How:** `web/scripts/build-entity-data.ts` reads `cities15000.txt` and `admin1CodesASCII.txt` from a GeoNames
  download and writes the gazetteer. It keeps places only in the countries `dmozdb` accepts, so the file is a filtered
  and changed copy of the GeoNames data, not the original.
- **Source:** [geonames.org](https://www.geonames.org/)
- **Licence:** Creative Commons Attribution 4.0. The [GeoNames about page](https://www.geonames.org/about.html) says:
  "This work is licensed under a Creative Commons Attribution 4.0 License." It links to
  <https://creativecommons.org/licenses/by/4.0/>. The [GeoNames download page](https://www.geonames.org/export/) says:
  "cc-by licence (creative commons attribution license). You should give credit to GeoNames when using data or web
  services with a link or another reference to GeoNames." It adds that the data is provided "as is" without warranty.
- **What the licence asks of you:** the Creative Commons deed lists the attribution term as "You must give appropriate
  credit, provide a link to the license, and indicate if changes were made."
- **Attribution:** this file gives it. Data from [GeoNames](https://www.geonames.org/), changed as described above.

## Hugging Face models

`web/scripts/fetch-models.ts` downloads two ONNX models from Hugging Face at pinned revisions and checks each file's
SHA-256. The models are not stored in this repository. They are fetched when the website image is built (`Dockerfile.web`)
and in CI. The model cards below were read at those pinned revisions.

### Xenova/bge-small-en-v1.5

- **Used for:** the website's embedding of link and category text (384 dimensions, int8, CLS pooling), which
  `dmozdb` stores and searches. `models/vector_model.bin` is a product-quantisation model trained with
  `eval/graphrag/train_vector_model.py` on embeddings from this model.
- **Revision:** `ea104dacec62c0de699686887e3f920caeb4f3e3`, files `onnx/model_quantized.onnx`, `tokenizer.json` and
  `tokenizer_config.json`.
- **Source:** <https://huggingface.co/Xenova/bge-small-en-v1.5>
- **What its card says:** the card at this revision has no `license` field. Its header reads `base_model:
  BAAI/bge-small-en-v1.5`, and its text reads "https://huggingface.co/BAAI/bge-small-en-v1.5 with ONNX weights to be
  compatible with Transformers.js."
- **Licence of the base model:** the [BAAI/bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) card
  has `license: mit` and says: "FlagEmbedding is licensed under the MIT License. The released models can be used for
  commercial purposes free of charge."

### Xenova/bert-base-NER

- **Used for:** finding the places, people and organisations that a link's title and description name. The result is
  stored as link entities for `query_links`.
- **Revision:** `8e892123e8b7c2c0c2bd1dcb598b7d244c4e53aa`, files `onnx/model_quantized.onnx`, `tokenizer.json`,
  `tokenizer_config.json` and `config.json`.
- **Source:** <https://huggingface.co/Xenova/bert-base-NER>
- **What its card says:** `license: mit`, with `base_model: dslim/bert-base-NER`. The text reads
  "https://huggingface.co/dslim/bert-base-NER with ONNX weights to be compatible with Transformers.js."
- **Licence of the base model:** the [dslim/bert-base-NER](https://huggingface.co/dslim/bert-base-NER) card has
  `license: mit`. The same card says the model "was fine-tuned on the English version of the standard CoNLL-2003 Named
  Entity Recognition dataset", and that this dataset "was derived from the Reuters corpus which consists of Reuters news
  stories". The card gives no separate licence for that training data.

## zigstore

The storage engine is [zigstore](https://github.com/poly-glot/zigstore), pinned in `build.zig.zon`. It is the same
author's library and is under the MIT licence.
