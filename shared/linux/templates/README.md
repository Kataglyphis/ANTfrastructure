# Linux consumer templates

Copy-and-edit starting points for the bash side. (The PowerShell equivalent is
[`../../windows/templates/`](../windows/templates/README.md); the consumer
`AGENTS.md` skeleton is in [`../../templates/`](../templates/README.md).)

| File | Copy to | Then |
|---|---|---|
| `containerhub.sh` | `<your-repo>/scripts/linux/lib/containerhub.sh` | Adjust `KATAGLYPHIS_REPO_ROOT_RELATIVE` if it does not sit three levels below the repo root. Nothing else. |

## Why this is copied rather than consumed

It is the file that *finds* the submodule, so it cannot live inside it — the
same chicken-and-egg as `Resolve-BuildModule.ps1`. Copying **one** file is fine.
Copying six different ones is the failure mode, and that is what was measured on
2026-08-11:

| Repo | Bootstrap |
|---|---|
| BeschleunigerBallett | `source_module()` in `lib/common.sh` |
| Inference-Engine | `containerhub_path` / `containerhub_source` |
| KataglyphisCppInference | `_CONTAINER_HUB_CORE` |
| Orchestr-ANT-ion | `_DRIVER`, re-inlined in every wrapper |
| WebDavClient | `CONTAINERHUB_SETUP_SCRIPT` + `_DRIVER` |
| jotrockenmitlocken | `CONTAINERHUB_DIR` / `CONTAINERHUB_SCRIPTS_DIR` |

Different search orders, different error text, different working-directory
assumptions. WebDavClient's sourced a path that had moved upstream and failed
with nothing but bash's own "No such file or directory" — the guard that would
have named the cause existed in another repo's copy.

## The three entry points

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/containerhub.sh"

containerhub_source linux/scripts/01-core/logging.sh          # load a library
db="$(containerhub_path linux/scripts/lib/coverage.sh)"       # resolve a path
containerhub_exec linux/scripts/02-toolchain/python/ci_tests.sh "$@"   # delegate
```

`containerhub_exec` is the wrapper pattern, and it exports `WORKSPACE_ROOT`
before handing off. That line is not optional: upstream's `detect_workspace`
derives the workspace from the sourcing script's own location, which for a
*delegated* driver resolves inside `ExternalLib/Kataglyphis-ContainerHub/`
rather than the consuming repo — so every tool would run against the submodule
tree. It honours a pre-set value and still overrides to `/workspace` in the
container, so CI is unaffected either way.

## What not to do

Do not add project-specific behaviour here. A wrapper that needs an extra step
(WebDavClient installs `patchelf` before packaging) does that in the wrapper,
around the `containerhub_exec` call — not inside this file, which every repo
holds a copy of.
