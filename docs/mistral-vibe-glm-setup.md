<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Mistral Vibe + GLM-5.2 Setup

How to run **Z.ai GLM-5.2** — the open-weights model Mistral has hosted on La
Plateforme since 2026-08-11 — as the coding agent in **Mistral Vibe**, both in
the CLI and the VS Code extension.

Vibe is the agent formerly called Le Chat; its coding surface (`vibe for code`)
ships as a CLI and a VS Code extension. GLM-5.2 is not a Mistral model — it is a
third-party open model running on Mistral's infrastructure, under the same
regional controls and service commitments as Mistral's own models.

> **Why this page lives here.** The Kataglyphis repos are worked on by AI coding
> agents. This is the setup guide for one of them, so any contributor (human or
> agent) can reproduce the working config without reverse-engineering it from a
> log file. The errors and fixes in the troubleshooting table were all found
> live on 2026-08-28 — including two that produce no log entry, only garbled
> TUI output.

---

## Prerequisites

| Need | Where |
|---|---|
| Mistral Vibe CLI | `curl -LsSf https://mistral.ai/vibe/install.sh \| bash` or `uv tool install mistral-vibe` |
| Mistral account + API key | [console.mistral.ai/api-keys](https://console.mistral.ai/api-keys) (La Plateforme / Mistral Studio) |
| VS Code ≥ 1.94.0 | only if you want the IDE panel — the CLI works standalone |

Verify the CLI is on PATH after install:

```bash
vibe --version
```

## 1. Get a Mistral API key

1. Sign in at [console.mistral.ai](https://console.mistral.ai).
2. Go to **API Keys** and create a new key.
3. Copy it immediately — it is shown once.

A real Mistral key is roughly 32 alphanumeric characters. If what you have is
shorter or reads like a placeholder (`DEIN…`, `your-key-here`), it is not a real
key and every request will fail with `HTTP 401`.

## 2. Write `~/.vibe/config.toml`

Vibe stores its config in `~/.vibe/config.toml` (Windows: `%USERPROFILE%\.vibe\config.toml`).
The block below is the known-good config for GLM-5.2 on the EU endpoint:

```toml
active_model = "zai-glm-5-2"

[[providers]]
name = "mistral-eu"
api_base = "https://api.eu.mistral.ai/v1"
api_key_env_var = "MISTRAL_API_KEY"
api_style = "openai"
backend = "mistral"

[[models]]
name = "zai-glm-5-2"
provider = "mistral-eu"
alias = "zai-glm-5-2"
display_name = "Z.ai GLM 5.2"
temperature = 1.0
thinking = "off"
supports_images = false
input_price = 1.4
output_price = 4.4
cached_input_price = 0.14
auto_compact_threshold = 800000
```

### Field reference

| Field | Value | Why |
|---|---|---|
| `name` | `zai-glm-5-2` | The exact model ID the Mistral API expects. Not `glm-5.2`, not `glm5.2`, not `glm-5-2` — those all return `Invalid model`. |
| `provider` | `mistral-eu` | Matches the `[[providers]]` block below. Use `mistral-eu` for the EU endpoint, or point `api_base` at `https://api.mistral.ai/v1` for the US endpoint. |
| `backend` | `"mistral"` | Uses the official Mistral SDK backend, which maps Vibe thinking levels to the API's `reasoning_effort` parameter. The `"generic"` backend sends the raw level string (`"max"`) which the Mistral API rejects — it only accepts `"none"` or `"high"`. The default Mistral provider in Vibe ships with `backend = "mistral"`. |
| `alias` | `zai-glm-5-2` | What shows in the model picker. Keep it identical to `name` to avoid `/model` confusion. |
| `display_name` | `Z.ai GLM 5.2` | Human-readable label in the picker. Optional but useful when multiple models are configured. |
| `thinking` | `"off"` | GLM-5.2's model card lists no reasoning mode. Setting any non-`"off"` value makes the backend send a `reasoning_effort` parameter the model does not support, producing garbled output in the TUI. |
| `supports_images` | `false` | GLM-5.2 is text-only. |
| `input_price` | `1.4` | Cost per million input tokens (USD). Lets Vibe track session cost. From the [model card](https://docs.mistral.ai/models/zai-glm-5-2). |
| `output_price` | `4.4` | Cost per million output tokens (USD). |
| `cached_input_price` | `0.14` | Cost per million cached input tokens (USD). |
| `auto_compact_threshold` | `800000` | The model has a 1M-token context window. Compact at 800K to leave headroom. |
| `active_model` | `zai-glm-5-2` | Must not be empty — an empty `active_model` means Vibe starts with no model selected. |

## 3. Set the API key

The key is **not** stored in `config.toml`. Vibe reads it from the environment
variable named by `api_key_env_var` (here `MISTRAL_API_KEY`). The easiest way to
set it persistently is the built-in setup flow:

```bash
vibe --setup
```

This opens a terminal prompt; paste the key from step 1. Vibe writes it to
`~/.vibe/.env` and future sessions pick it up automatically.

To verify the key is loaded without starting an interactive session:

```bash
# quick smoke test — model replies and exits
vibe -p "Reply with: OK" --max-turns 1 --auto-approve --output text
```

## 4. VS Code extension (optional)

The **Mistral Vibe VS Code** extension (`mistralai.mistral-vibe-code`, on the
Marketplace) runs the same bundled agent as the CLI. It reads the **same**
`~/.vibe/config.toml` and `~/.vibe/.env`, so once the CLI is configured the
extension picks up GLM-5.2 with no extra setup.

To install from inside VS Code:

1. `Ctrl+Shift+X` to open Extensions.
2. Search **Mistral Vibe**.
3. Install the one published by **Mistral AI** (`mistralai`).
4. Open the Vibe panel from the activity bar, or run
   **Mistral Vibe: Open Mistral Vibe** from the Command Palette.

If the extension needs credentials and none are configured yet, it opens a
terminal setup flow that runs `vibe --setup` — step 3 above.

---

## Troubleshooting

Every row below was hit live on 2026-08-28. The log is at
`~/.vibe/logs/vibe.log`.

| Symptom (log message) | Cause | Fix |
|---|---|---|
| `Invalid model: glm-5.2` / `Model 'glm-5.2' is not available on mistral` | Wrong model ID in `config.toml` — the API rejects anything that is not exactly `zai-glm-5-2`. | Set `name = "zai-glm-5-2"` (and `alias` to match). |
| `Invalid API key. Please check your API key and try again.` (on **every** model, including `mistral-medium-3.5`) | `~/.vibe/.env` contains a placeholder or stale key, or `MISTRAL_API_KEY` is unset. | Run `vibe --setup` and paste a real key from [console.mistral.ai/api-keys](https://console.mistral.ai/api-keys). |
| `HTTP 401` at startup (`Admin-managed config not applied` / `Connector catalog is unavailable`) | Same root cause — the bad key fails before any model call. | Same fix — set the key. These warnings clear once auth works. |
| **Garbled / strange output in the TUI** (no log entry; the model answers but the display is wrong) | `backend = "generic"` sends `reasoning_effort: "max"` raw — the Mistral API only accepts `"none"` or `"high"`. The `"mistral"` backend maps levels correctly (`"max"` → `"high"`), but GLM-5.2 has no reasoning support so the parameter should not be sent at all. | Set `backend = "mistral"` **and** `thinking = "off"`. With thinking off, no `reasoning_effort` is sent regardless of backend. |
| Startup warning about `thinking` / reasoning mode | `thinking = "max"` set for a model whose card lists no reasoning mode. | Set `thinking = "off"`. Vibe's own migration code does the same for `devstral-small-latest` (`"Force thinking='off'; it has no reasoning support"`). |
| No model selected on startup; `/model` shows nothing active | `active_model = ""` in `config.toml`. | Set `active_model = "zai-glm-5-2"`. |
| Model not in the picker at all | `[[models]]` block missing or `provider` does not match any `[[providers]]` `name`. | Ensure `provider = "mistral-eu"` matches the provider block, and the model block is a top-level `[[models]]` table. |

### Quick health check

```bash
# 1. is the CLI installed?
vibe --version

# 2. is the key set? (prints length only, never the key)
powershell -NoProfile -Command "echo $env:MISTRAL_API_KEY.Length"

# 3. does the model answer?
vibe -p "Reply with: OK" --max-turns 1 --auto-approve --output text
```

If step 3 prints `OK`, the full chain — key, endpoint, model ID — is correct.

---

## References

- **GLM-5.2 model card** (features, context, pricing): <https://docs.mistral.ai/models/zai-glm-5-2>
- **Mistral Vibe product page**: <https://mistral.ai/products/vibe/code/>
- **VS Code extension — install & auth**: <https://docs.mistral.ai/vibe/code/vs-code-extension/install-authenticate>
- **Vibe CLI configuration**: <https://docs.mistral.ai/vibe/code/cli/configuration>
- **Reasoning on Mistral** (`reasoning_effort` parameter, supported models): <https://docs.mistral.ai/studio/conversations/reasoning>
- **GLM-5.2 on Mistral announcement** (2026-08-11): <https://mistral.ai/news/regional-inference-open-models-new-compute/>
- **API keys**: <https://console.mistral.ai/api-keys>
