# Linux consumer templates

Copy-and-edit starting points for the bash side. (The PowerShell equivalent is
[`../../windows/templates/`](../../windows/templates/README.md); the consumer
`AGENTS.md` skeleton is in [`../../templates/`](../templates/README.md).)

Copy `antfrastructure.sh` to `<your-repo>/scripts/linux/lib/antfrastructure.sh`
and adjust `KATAGLYPHIS_REPO_ROOT_RELATIVE` if it does not sit three levels
below the repo root. Nothing else.

**A consumer with no submodule is a supported shape.** `ANTFRASTRUCTURE_DIR`
still wins when set; otherwise the bootstrap takes `third_party/ANTfrastructure`
when it exists and `antfrastructure-tools` (a plain sibling clone at the repo
root) when it does not. One repo hand-rolled that probe because this template
could not express it, which is how a seventh bootstrap variant gets born. The
error text follows the same fact: it only offers `git submodule update` when
`.gitmodules` actually names that path, and otherwise says to clone or to point
`ANTFRASTRUCTURE_DIR` at a checkout — a `git submodule update` in a repo with no
such submodule prints "No submodule mapping found" and sends the reader hunting
a submodule that never existed.

`renovate-local.sh` beside it is the second template: a copy-and-edit wrapper
whose header is one link to
[`dependency-updates.md`](../../../docs/dependency-updates.md) plus a two-line
per-repo slot. Seven copies of that wrapper existed with headers between 50 and
106 lines, each carrying a different half of the same explanation and most of it
stale. It also does the `GITHUB_COM_TOKEN` fallback, which is the one thing a
wrapper genuinely owns: without that token the GitHub-hosted managers are
rate-limited into reporting nothing, which looks exactly like "nothing is
behind".

## Why this is copied rather than consumed

It is the file that *finds* the submodule, so it cannot live inside it — the
same chicken-and-egg as `Resolve-BuildModule.ps1`. Copying **one** file is fine.
Copying six different ones is the failure mode, and that is what was measured on
2026-08-11:

| Repo | Bootstrap |
|---|---|
| BeschleunigerBallett | `source_module()` in `lib/common.sh` |
| OmniAccelerANT | `antfrastructure_path` / `antfrastructure_source` |
| AccelerANTgine (then `KataglyphisCppInference`) | `_ANTFRASTRUCTURE_CORE` |
| OrchestrANT | `_DRIVER`, re-inlined in every wrapper |
| WebDavClient | `ANTFRASTRUCTURE_SETUP_SCRIPT` + `_DRIVER` |
| jotrockenmitlocken | `ANTFRASTRUCTURE_DIR` / `ANTFRASTRUCTURE_SCRIPTS_DIR` |

Different search orders, different error text, different working-directory
assumptions. WebDavClient's sourced a path that had moved upstream and failed
with nothing but bash's own "No such file or directory" — the guard that would
have named the cause existed in another repo's copy.

## The three entry points

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/antfrastructure.sh"

antfrastructure_source linux/scripts/01-core/logging.sh          # load a library
db="$(antfrastructure_path linux/scripts/lib/coverage.sh)"       # resolve a path
antfrastructure_exec linux/scripts/02-toolchain/python/ci_tests.sh "$@"   # delegate
```

`antfrastructure_exec` is the wrapper pattern, and it exports `WORKSPACE_ROOT`
before handing off. That line is not optional: upstream's `detect_workspace`
derives the workspace from the sourcing script's own location, which for a
*delegated* driver resolves inside `third_party/ANTfrastructure/`
rather than the consuming repo — so every tool would run against the submodule
tree. It honours a pre-set value and still overrides to `/workspace` in the
container, so CI is unaffected either way.

## What not to do

Do not add project-specific behaviour here. A wrapper that needs an extra step
(WebDavClient installs `patchelf` before packaging) does that in the wrapper,
around the `antfrastructure_exec` call — not inside this file, which every repo
holds a copy of.
