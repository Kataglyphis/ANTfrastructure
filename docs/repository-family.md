<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# The Kataglyphis repositories

One owner, one build image and one set of rules cover every repository below. This page holds
what is true for all of them, so each README stays a short overview that links here for the rest
(owner, 2026-10-19).

## The repositories

| Repository | What it is | Who vendors or fetches it |
| --- | --- | --- |
| [OmniAccelerANT](https://github.com/Kataglyphis/OmniAccelerANT) | Flutter app for AI inference on Windows, Linux, Android and the web, and ObservANT, the installable camera that spots cats | nobody: it is the top of the tree |
| [OxidANT](https://github.com/Kataglyphis/OxidANT) | The Rust core: the workspace crates, ObservANT's producer, the flutter_rust_bridge API | submodule of OmniAccelerANT and BeschleunigerBallett |
| [AccelerANTgine](https://github.com/Kataglyphis/AccelerANTgine) | The C++ inference core and its Python bindings | submodule of OmniAccelerANT |
| [ANThology](https://github.com/Kataglyphis/ANThology) | The shared Flutter/Dart UI package | submodule of OmniAccelerANT and jotrockenmitlocken |
| [BeschleunigerBallett](https://github.com/Kataglyphis/BeschleunigerBallett) | C++23 Vulkan renderer and acceleration playground | nobody |
| [OrchestrANT](https://github.com/Kataglyphis/OrchestrANT) | Python AI prototyping package, the LLM benchmark lab and its viewer | its app environment is baked into the build images |
| [ANTfrastructure](https://github.com/Kataglyphis/ANTfrastructure) | The build images, the CI actions and reusable workflows, the quality gates, and this page | submodule of the code repos, including ANThology; DocumANTation uses a separate checkout to avoid a cycle |
| [DocumANTation](https://github.com/Kataglyphis/DocumANTation) | Markdown to a LaTeX book or Beamer slides, and the theme every docs site uses | submodule of ANTfrastructure |
| [ModelANT](https://github.com/Kataglyphis/ModelANT) | ML models under permissive, Llama or Gemma licences with their obligations on record, one release each | fetched by SHA-256: OxidANT, OmniAccelerANT and OrchestrANT through a lock, AccelerANTgine through `sha256sum -c` |
| [AssetANT](https://github.com/Kataglyphis/AssetANT) | 3D scenes and textures, one archive per release | fetched by SHA-256 lock: BeschleunigerBallett |
| [WebDavClient](https://github.com/Kataglyphis/WebDavClient) | Python client that downloads files and folders from WebDAV storage, in CI for example | nobody |
| [jotrockenmitlocken](https://github.com/Kataglyphis/jotrockenmitlocken) | The owner's website and blog, a Flutter web app | its build is what the hub's `:webserver` image serves |
| [Kataglyphis](https://github.com/Kataglyphis/Kataglyphis) | The GitHub profile page | nobody |

The archived repositories on the same account are read-only and follow none of this. Models and
scenes live outside the code on purpose: [`data-repositories.md`](data-repositories.md).

## How a repository is laid out

| File | What it holds |
| --- | --- |
| `README.md` | The overview: what the project is, how to start, where the docs are (the rule is below) |
| `docs/` | The guides. The docs site on each repository's homepage is built from them |
| `AGENTS.md` | Rules for coding agents and new contributors, from the [`AGENTS.md` template](../shared/templates/README.md) |
| `BACKLOG.md` | Known work that is not done yet, in the format the agentic loop reads |
| `CHANGELOG.md` | What changed, newest first; a repository with a release keeps one, since the release notes come from it ([naming rules](adopting-in-a-new-project.md#the-rest-of-the-naming-rules-in-one-place)) |
| `LICENSE` | MIT almost everywhere, see [Licence](#licence) |

A data repository (ModelANT, AssetANT) and the profile page carry fewer of these.

## The README rule

**A README is the front page, read in a minute.** It says what the project is and where to
read on; everything else has a page of its own. In this order:

1. **Header:** the repository's own ant logo (`images/logo.svg`, from DocumANTation's
   `scripts/make_repo_logos.py`), the name, and the tagline in one line.
2. **Badges:** the CI lanes first; dependency, social and donate badges after them, in the same block.
3. **One paragraph:** what it does and for whom.
4. **Highlights:** at most six bullets of one line each.
5. **Quick start:** clone, then the one command that builds or runs it. A screen at most.
6. **Documentation:** a table with one row per guide, plus the docs site and `AGENTS.md`.
7. **Footer:** one line to this page for contributing and contact, and the `LICENSE` link.

**At most 100 lines, 700 words and 160 characters a line.** Badges count toward the lines only. A
line that is only a link is exempt from the words and the width. The `readme-length` gate checks all
three, in the hub's preflight and in every consumer's lint gates. A README already over the words or
the width has census rows that may only fall
([`code-quality-tooling.md` § README length](code-quality-tooling.md#readme-length-readme-length)).
[`README.md.template`](../shared/templates/README.md.template) is that shape, ready to copy.

What leaves the README:

- **A procedure, flag list, measurement, troubleshooting table or piece of history** goes to a
  page in that repository's `docs/`, and the README links to it.
- **Anything that is true for more than one repository** goes to this hub, here or on the page
  [`INDEX.md`](INDEX.md) names, and every README links to it instead of repeating it.
- **Contributing, contact and licence boilerplate** is this page's. A README says what is
  different about its own repository and nothing more.

**Link to another repository with an absolute URL** on its `develop` branch, such as
`https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/INDEX.md`. GitHub does not
follow a relative link into a submodule, so a README link to
`third_party/ANTfrastructure/docs/…` works in a checkout and is a 404 on the repository page.
`AGENTS.md`, which agents read in a checkout, keeps its relative links.

**A README that is rendered somewhere else as well links its own files absolutely too.** Four
places show a README away from GitHub, and a relative link is a 404 in each:

| Where | Because of |
| --- | --- |
| PyPI, as the long description | `readme = "README.md"` in `pyproject.toml` |
| The rustdoc front page | `#![doc = include_str!("../README.md")]` in `src/lib.rs` |
| The `index.html` of a `dart doc` site | `dart doc` always renders the README there |
| A Sphinx site | the docs build copies the README into `docs/source/` |

Such a README loads its logo from `raw.githubusercontent.com` and gives every code block a
language, so that rustdoc runs none of them as a doc test.

## Contributing

- **Issues and pull requests are welcome** in every repository. Fork it, branch in your fork,
  and open the pull request against `develop`.
- **The repositories keep two branches.** All work lands on `develop`; `main` moves only by the
  owner's fast-forward to a commit whose every lane is green, and each such push is a release:
  [`branch-and-release-strategy.md`](branch-and-release-strategy.md).
- **Clone with the submodules:** `git clone --recurse-submodules`, or
  `git submodule update --init --recursive` in a clone you already have. A build is supported at
  the recorded gitlinks only:
  [`adopting-in-a-new-project.md` § Bumping the pin](adopting-in-a-new-project.md#bumping-the-pin).
- **Build and test with the script CI runs, in the image CI uses**, and reproduce a failure
  there before pushing: [`linux-build-basics.md`](linux-build-basics.md),
  [`windows-builds.md`](windows-builds.md). On Windows the bash scripts run in Git Bash and the
  PowerShell ones in `pwsh` 7, never Windows PowerShell 5.1.
- **Install the repository's pre-commit hook once.** Its `AGENTS.md` names the command; it runs
  CI's first gates in seconds.
- **Commit messages read `type(scope): what changed`**, with `feat`, `fix`, `docs`,
  `refactor`, `test`, `ci` or `chore`. `[ci <lane>]` in the message asks for a lane beyond
  Linux x64.
- **Docs change in the same commit as the behaviour they describe**, and read like a developer
  wrote them: short and precise, no filler, no marketing, no repetition.
- **Dependencies move through Renovate as a local CLI**, never by hand:
  [`dependency-updates.md`](dependency-updates.md).
- **Search with ripgrep** (`rg`): `winget install --id BurntSushi.ripgrep.MSVC -e --scope user`
  on Windows, `apt install ripgrep` on Linux.
- **Terminal multiplexers the owner uses beside them:** [tmux](https://github.com/tmux/tmux/wiki)
  and [zellij](https://zellij.dev/), and [psmux](https://github.com/marlocarlo/psmux) on Windows.

## Licence

- **The code is MIT** in every repository but ModelANT, whose scripts are Apache-2.0: each
  repository's `LICENSE`, and an `SPDX-License-Identifier` header where the repository uses them.
- **Bundled third-party software keeps its own licence**:
  [`third-party-licenses.md`](third-party-licenses.md).
- **A model or a scene carries its own licence**, recorded with its release:
  [`data-repositories.md`](data-repositories.md).

## Contact

Jonas Heinle: [jonasheinle.de](https://jonasheinle.de),
[@Cataglyphis_](https://twitter.com/Cataglyphis_), <jonasheinle@googlemail.com>.

Report a security problem to that address or through the repository's GitHub security advisory
form, never in a public issue.

## Contributing reusable work

Consumers push reusable work upstream rather than keep local copies (BeschleunigerBallett's
AGENTS.md states this as a rule). Wiring a new project to the hub (submodule, module resolver,
Windows and Linux container builds, the agentic loop, launchers, CI actions) is a checklist in
[`adopting-in-a-new-project.md`](adopting-in-a-new-project.md). Read it before hand-rolling any of
that in a consumer. When adding to the hub:

- Reuse before adding. Search the current repository and its submodules for an existing
  implementation before creating functionality. Reuse or extend the canonical repo or submodule
  surface; when none exists, add it once to a shared repo and wire consumers to it. Keep
  consumer-specific values as parameters. If a hard technical boundary prevents reuse, record the
  reason and keep the copy tied to its canonical source.
- PowerShell 7 (pwsh) is the standard shell and the Windows containers' default SHELL. Every
  `.ps1`/`.psm1` declares `#requires -Version 7.0` on line 1 (or directly under the SPDX header),
  before any `param()`.
- Two tracked files omit it on purpose, both pinned 5.1-parsable by a suite. They are the script
  that installs pwsh and the delete guard, which must not fail open on a host without `pwsh`. The two
  scripts in `linux/ansible/scripts/` omit it too: they can run under Windows PowerShell 5.1 on a
  managed host. Two Pester suites also lack it: `HostMaintenance.ToolLookup.Tests.ps1` and
  `StevedoreInventory.Tests.ps1`.
- PowerShell file names have three shapes: PascalCase `Verb-Noun.ps1` with a `Get-Verb`-approved
  verb for scripts, `Windows<Area>.<Facet>.psm1` for modules, `<Subject>.Tests.ps1` for suites.
- Three tracked files sit outside all three on purpose. The delete guard is registered by that
  exact string, so a rename silently unregisters it. The files in
  `windows/scripts/build/rocm-checks/` are named after the component they check (`FFmpeg.ps1`). A
  `verb-noun-name.ps1` spelling anywhere is stale, not a variant: the scripts were renamed.
- PowerShell scripts go in `windows/scripts/modules/` with `Export-ModuleMember`; consumers resolve
  them ANTfrastructure-first with a vendored fallback. The resolver is a copied template:
  [`shared/windows/templates/Resolve-BuildModule.ps1`](../shared/windows/templates/README.md).
- Exporting a function a build script calls directly is two edits: `Export-ModuleMember` in the
  owning module, and the re-export list if the script reaches it through one. Module-internal use
  needs neither, so an omission is invisible on a dev box and surfaces as `CommandNotFound` hours
  into a container build. Two suites hold the two directions (every called name resolves; every
  listed name exists); neither replaces the other.
- The two-consumer test. What a second consumer needs belongs here, not vendored twice. Moving one
  up, turn its project-specific values into parameters whose defaults keep the original behaviour,
  so the vendoring consumer can delete its copy with no behaviour change.
- Avoid mutual submodule links. This hub vendors DocumANTation; that consumer calls reusable
  workflows with `hub-checkout: true` instead of linking this hub back into its Git tree.
- Document the symptom, not just the fix: platform traps are found by recognising an error message,
  not by reading code.
- Keep functions free of consumer-specific paths, preset names and build directories; pass those
  in as parameters.
- Deleting is a consumer change. A hub file may be removed only when the consumer inventory
  (`linux/scripts/verify_consumer_inventory.py`, over every repo in `.github/consumers.json`)
  reports it named by nobody. The deleting commit names the consumer commits that dropped the
  reference.
- A "zero callers" grep of this tree is no evidence. Consumers pin a submodule commit and reach
  modules by name or by backslash path, so they neither break at delete time nor appear in the
  grep. Four sweeps made that mistake; the last deleted three live files, restored a week later.
- Bash file names. New files are kebab-case. The snake_case names under `linux/scripts/`
  (`02-toolchain/python/ci_*.sh` and `build_python.sh`, `02-toolchain/rust/cargo_*.sh`,
  `_*_guard.sh` and `_cargo_wrapper.sh`, `version_util.sh`, `01-core/python_uv.sh`,
  `05-frameworks/flutter/flutter_checks.sh`, `06-packaging/package_archive.sh`) and
  `linux/webserver/scripts/flutter_integration_smoke_test.sh` are frozen. Consumer wrappers
  resolve them by path, so a rename breaks consumers for no structural gain.
- Workflow file names are kebab-case, fleet-wide, one file per platform and arch (`linux-x64.yml`,
  `windows-x64.yml`), with display names `<Platform> <Arch> · <what>`. The hub's reusable workflows
  (`python-ci-*`, `container-ci-windows`, `lint-gates`, `submodule-pins`, `build-docs`, the
  docs-site lane, and `release-publish`) keep their file names for good. Consumers call them at
  `@develop`, so a rename breaks the fleet in one push. Convention and the fleet's rename table:
  [`adopting-in-a-new-project.md` § Workflow file names and display names](adopting-in-a-new-project.md#workflow-file-names-and-display-names).

## Reuse invariants

Rules for reusing hub code and measuring reuse across the family. Each row is one rule.

| Rule |
|---|
| Keep scripts used repeatedly for development, verification or host maintenance in the owning repository; parameterize machine-specific values and document their use instead of regenerating the scripts for each task. Keep one-off evidence and scratch probes separate. |
| For Bash and PowerShell, review `verify_hub_reuse.py --root <consumer> --hub <hub> --report-only` as well; an advisory CI report does not authorize another local copy. |
| The weekly consumer inventory also measures cross-repository Bash/PowerShell overlap among active owned nonfork repos. Review its ignored `logs/reports/consumer-reuse.md` before adding a shared helper; overlap remains advisory, while missing checkouts or inventory coverage fail. |
| The reusable report job fails for an owned nonfork consumer whose pinned Hub lacks that scanner; keep the direct submodule current so reuse stays measured. |
| On Windows, its copied-bootstrap drift proof runs through PowerShell first. |
