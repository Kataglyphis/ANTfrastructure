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

**Under about 100 lines, badges included:** the `readme-length` gate fails a root README over 100
lines, in the hub's preflight and in every consumer's lint gates
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
