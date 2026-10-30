<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Language AI: text, LLMs and speech across the family

OxidANT, OrchestrANT, AccelerANTgine and OmniAccelerANT run computer vision today. This page is
the plan for adding language processing to them and the contract they share: the one engine,
the text API, the model packages and the order of work. Owner goal of 2026-10-30.

## Decisions

| Question | Decision (owner, 2026-10-30) |
|---|---|
| Local engine | ONNX Runtime GenAI from the chain, nothing else. llama.cpp stays reachable through Ollama over HTTP; LiteRT-LM is not an engine here. |
| Weights | One model package per ModelANT release (`.deb`, `.msi`). App installers carry no language-model weights. |
| Licences | Gemma and Llama are allowed, with their obligations ([§ Licences](#licences)). |
| Chat widgets | ANThology, so every Flutter app of the family can use them. |
| Android and web | Endpoint only until the chain builds GenAI for Android; the web stays on the endpoint. An assumption the owner has not confirmed yet. |
| Speech output | Decided in milestone 5: the usable German voices need espeak-ng, which is GPL-3.0. |

## What the images carry

| Piece | Where | Gap |
|---|---|---|
| GenAI at `ONNXRUNTIME_GENAI_VERSION` | Linux `/usr/local/lib/onnxruntime-genai` on amd64, arm64 and riscv64 (CPU; CUDA in the nvidia variant); Windows `ONNX_GENAI_ROOT` (DirectML; CUDA in the nvidia variant); the `:winarm64` bundle | no Android build, no web build |
| llguidance: JSON schema and grammars | Linux, `--use_guidance` in `60-build-genai.sh` | Windows builds with `-DUSE_GUIDANCE=OFF` |
| `ort_genai.h`, `ort_genai_c.h` | GenAI's `include/` | required by the Linux artifact check since LAI-H1 ([contract](consumer-image-contract.md#genais-library-and-headers)) |
| Ollama, Open WebUI, the APISIX gateway | [`linux/llm-stack/`](../linux/llm-stack/README.md) | none |
| GenieX on Snapdragon | [`geniex-local-ai-setup.md`](geniex-local-ai-setup.md) | HTTP only |
| HailoRT for Hailo-10H | [`hailo-support.md`](hailo-support.md) | its GenAI part is not built |

## The text contract

Every binding (C++, C, Rust, Python, Dart) offers the same calls against two backends:

- **local:** GenAI in the process, from the chain build only, loaded the way that binding
  loads ONNX Runtime.
- **endpoint:** an OpenAI-compatible server, by URL or by name through
  [`backends.json`](../linux/llm-stack/README.md#named-backends).

| Call | Contract |
|---|---|
| generate | Messages (`system`, `user`, `assistant`, `tool`) and options in; text deltas out through a callback or a stream. The chat template is the model's own. |
| options | `max_new_tokens`, `temperature`, `top_p`, `top_k`, `seed`, and an optional `json_schema`. |
| cancel | Allowed at any time from another thread; the result's finish reason is `cancelled`. |
| result | `finish_reason` (`stop`, `length`, `cancelled`), prompt and completion token counts, time to first token with the prefill included, decode tokens per second. |
| embed | Texts in, one L2-normalised float vector per text out. |

No binding implements `seed` or `json_schema` yet, and only the endpoint backends embed; GenAI's
embeddings arrive with LAI-O5.

Each failure has its own error and is never an empty answer: model not found, invalid model
directory, execution provider unavailable, `json_schema` unsupported on this lane, endpoint
unreachable, endpoint HTTP status. Greedy decoding (`temperature` 0) of one model on one
execution provider yields the same tokens on every run; the tests rely on that.

## Models and model packages

ModelANT builds and releases every model ([`data-repositories.md`](data-repositories.md)). A
language-model release `<name>-v<N>` adds three things:

- **The GenAI model directory** as `<name>-<ep>.tar.xz`, one per execution provider (`cpu`,
  `cuda`, `dml`), because the GenAI builder exports per provider. The hub fetcher unpacks it
  with `--extract`.
- **A `text-generation-v1` contract archive:** a fixed prompt and the token ids greedy decoding
  must produce. The release workflow checks it before it publishes.
- **`kataglyphis-model-<name>`** as an architecture-independent `.deb` and as an `.msi`.

A package installs to `/usr/share/kataglyphis/models/<name>-<ep>/` on Linux and to
`%ProgramData%\Kataglyphis\models\<name>-<ep>\` on Windows. An app looks for a model in this
order: an explicit path, its own resources directory, the package directory. An app's package
recommends the model package and never contains it. CI and development fetch the same archives
through a separate `llm.lock`, so the app's `models.lock` keeps listing only what its installer
bundles.

GitHub ends a release asset at 2 GiB, so a larger model splits its ONNX external data across
files.

## Licences

ModelANT's rule was "permissive only". Since 2026-10-30 a model may also carry the Llama or the
Gemma licence. `model.json` records the licence class and its obligations; the package and every
app that ships the model carry them out.

| Licence | Obligations when redistributing, checked per model version |
|---|---|
| Llama | Ship the licence agreement and the acceptable use policy, display "Built with Llama", and start a derived model's name with "Llama". The multimodal Llama models exclude users resident in the EU (Llama 3.2 Vision), so none is used here. |
| Gemma | Ship the terms of use and the prohibited use policy, with the notice that the model is provided under them. |

## Models chosen so far

| Use | Model | Licence |
|---|---|---|
| tests | SmolLM2-135M-Instruct | Apache-2.0 |
| chat | Qwen3-1.7B, Qwen3-0.6B for small devices | Apache-2.0 |
| comparison in the lab | Llama 3.2 1B and 3B Instruct, Gemma 3 1B and 4B | Llama, Gemma |
| quality on a GPU | Phi-4-mini-instruct | MIT |
| embeddings | multilingual-e5-small, then bge-m3 | MIT |
| speech recognition | Whisper base or small | MIT |
| image and text | Phi-4-multimodal-instruct or Qwen3-VL-4B | MIT, Apache-2.0 |

German and English are required, which is why the chat and embedding models are multilingual.
Each licence and each model's support in the pinned GenAI release is checked before its export.

## The test model

`linux/scripts/lib/tiny-genai-model.py --out DIR` writes a complete GenAI model directory of about
270 KB with the standard library alone: `model.onnx`, `genai_config.json`, a byte-level BPE
`tokenizer.json` with its `tokenizer_config.json` and chat template, and `fixture.json`.

- **The rule:** every byte token predicts its successor, and byte 255 predicts the end token. Greedy
  decoding of `abc` with `max_length` 7 therefore yields `defg`, token ids 100 to 103.
- **The oracle:** `fixture.json` holds the prompt, its ids, the continuation and `max_length`.
  A binding test reads it instead of retyping the numbers.
- **The cache:** one layer whose `present` outputs concatenate the past with one embedding per
  token, so GenAI exercises its KV-cache loop exactly as with a real decoder.

`--check` decodes the model through the installed `onnxruntime_genai`: exit 0 when tokens, decoded
text and chat template match, 1 on a mismatch, 2 when the wheel is absent.

**Proven 2026-10-30** on the published index `7d4d4129` (amd64): the Python wheel and a C17 program
against `ort_genai_c.h` (GCC 16.2, `-Wall -Werror`) both decode `defg`. `test-tiny-genai-model.sh`
reads the bytes back on any host: graph, weights, names, tokenizer, and the check mode's verdict.
The image smoke's GenAI tier 4 decodes it on every arch it runs on (LAI-H5): proven on the amd64
image on 2026-10-30, arm64 and riscv64 from the next chain. **Not covered:** the decode on a host
without the wheel.

## Roadmap

Every item is open until its row says otherwise. Each repository's backlog names the IDs.

### Milestone 0: groundwork in the hub and ModelANT

| ID | Work | Repo |
|---|---|---|
| LAI-H1 | Require the GenAI library and both headers in the Linux artifact check; the header copy fails instead of `\|\| true`. Done 2026-10-30. | hub |
| LAI-H2 | Build GenAI with llguidance on Windows. Needs a Windows chain to prove. | hub |
| LAI-H3 | This page: the decisions, the contract, the model search order. Done 2026-10-30. | hub |
| LAI-H4 | A fixture that writes a tiny GenAI model, its config and tokenizer, so no test loads a model file ([§ The test model](#the-test-model)). Done 2026-10-30. | hub |
| LAI-H5 | The image smoke's GenAI tier 4 decodes the test model on every arch instead of reporting `generate()` as unproven. Done 2026-10-30; arm64 and riscv64 prove it at the next chain. | hub |
| LAI-M1 | ModelANT's licence rule, README and model guide follow [§ Licences](#licences). Done 2026-10-30 (`scripts/license_policy.py`); its release notes still state Apache-2.0 for every model. | ModelANT |
| LAI-M2 | The `text-generation-v1` contract and its release check. Done 2026-10-30. | ModelANT |
| LAI-M3 | GenAI export and package scripts. Done 2026-10-30 (`scripts/export_genai.py`): a reproducible `.tar.xz` and a `.deb`; no `.msi` yet. | ModelANT |
| LAI-M4 | The first release, SmolLM2-135M-Instruct for CPU; then the default chat model. `smollm2_135m_instruct-v1` published 2026-10-30; the default chat model is open. | ModelANT |

### Milestone 1: text in every repository

| ID | Work | Repo |
|---|---|---|
| LAI-A1 | `kataglyphis.text_generation` over `ort_genai.h`, beside the detector; the execution provider comes from the config. Done 2026-10-30: GenAI is loaded at run time, and the provider is an argument of `initialize`. | AccelerANTgine |
| LAI-A2 | C API with opaque handles and a token callback. An ABI change for OmniAccelerANT's plugin. Done 2026-10-30 (`kataglyphis_c_api.h`); the plugin does not call it yet. | AccelerANTgine |
| LAI-A3 | nanobind class with a lock, CLI `chat`, a `[text_generation]` config section. Done 2026-10-30 without the config section, which nothing would read yet. | AccelerANTgine |
| LAI-O1 | A text crate over `ort_genai_c.h`, loaded dynamically and verified like ORT; the endpoint through `ureq`. Done 2026-10-30 (`crates/text`): a GenAI that does not embed the chain's build tree is refused. | OxidANT |
| LAI-O2 | CLI `chat` and `embed`. Done 2026-10-30: `chat` on both backends, `embed` on an endpoint. | OxidANT |
| LAI-O3 | FRB `api/text.rs` with a `StreamSink` for tokens. Done 2026-10-30. | OxidANT |
| LAI-P1 | `orchestrant/genai/`, `orchestrant-chat`, and `orchestrant-serve` as an OpenAI-compatible server over GenAI. Done 2026-10-30. | OrchestrANT |
| LAI-P2 | `orchestrant-bench` measures the chain's own engine next to Ollama and GenieX. Done 2026-10-30: `backends.json` names it `chain-genai`. The first figures are SmolLM2 alone on the amd64 build host's CPU; a run beside Ollama and GenieX needs their hosts. | OrchestrANT |
| LAI-F1 | The AI Playground page (`aiPlayground`) with streaming and the speed figures. Done 2026-10-30. | OmniAccelerANT |
| LAI-F2 | Endpoint settings on every platform; local through LAI-O3 on Windows and Linux. Done 2026-10-30; the web build fetches whole answers, and the settings are not saved yet. | OmniAccelerANT |
| LAI-F3 | Chat widgets: message list, Markdown answer, input. Done 2026-10-30 (`lib/Widgets/Chat/`). | ANThology |

### Milestones 2 to 5

| Milestone | IDs | Work |
|---|---|---|
| 2 NLP and search | LAI-O5, LAI-P3, LAI-P4 | Embeddings in OxidANT; the NAS document AI; classification, entities, summaries and translation between German and English with a JSON schema. |
| 3 Speech | LAI-A4, LAI-F4 | A GStreamer audio appsink and Whisper captions as `textoverlay` and WebRTC data; microphone input in the app. |
| 4 Language meets vision | LAI-O4, LAI-P5, LAI-F5 | ObservANT's `/ask` and a daily summary over `/visits`; `yolo-monitor --describe`; questions on the Stream page. |
| 5 Extensions | LAI-H6 and spikes | GenAI for Android; HailoRT GenAI on Hailo-10H; QNN in process; a tool-calling agent over OrchestrANT's metrics; speech output. |

## Fetching a released model

A consumer's `llm.lock` pins the archive like any other data file, and the hub fetcher unpacks it:

```text
# sha256                                                          file                               url
b3853a1cd5c0af0d604fdae0b3d495a2f3d4ec7ab0653704b4e6b896d5a27f8f  smollm2_135m_instruct-cpu.tar.xz  https://github.com/Kataglyphis/ModelANT/releases/download/smollm2_135m_instruct-v1/smollm2_135m_instruct-cpu.tar.xz
```

`fetch-data-lock.py --lock llm.lock --dest DIR --extract` leaves the GenAI model directory at
`DIR/smollm2_135m_instruct-cpu/`. The release's `contract.tar.gz` holds the cases a binding replays
against it, such as "What is the capital of France?" decoding to "The capital of France is Paris."

## Rules every item keeps

- ORT and GenAI come from the chain only: [`onnxruntime-single-source.md`](onnxruntime-single-source.md).
- Weights live in ModelANT and arrive by lock.
- A test asserts tokens. "The model loads" is not a pass.
- GenAI has no free-threading marker. Python imports it lazily, and a free-threaded run asserts
  that it is absent.
- Every new gate is mutation-tested.
