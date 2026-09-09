<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Dependency updates — Renovate, run locally

**The rule, owner directive 2026-09-09:** dependency upgrades across every repo
in the family are driven by **Renovate run as a local CLI**, through
`linux/scripts/renovate-local.sh`. Not by hand, and not by waiting for a bot.

```bash
# what is behind, in this repo, according to THIS repo's renovate.json
third_party/ContainerHub/linux/scripts/renovate-local.sh .

# ...and move the submodules it named
third_party/ContainerHub/linux/scripts/renovate-local.sh --apply .
```

Consumers reach it through their own thin wrapper, named `renovate-local.sh` and
placed wherever that repo already keeps its ContainerHub wrappers -
`scripts/linux/` in BeschleunigerBallett, OmniAccelerANT and OrchestrANT, but the
flat `scripts/` in jotrockenmitlocken. Same shape as `run-lint-gates.sh` there.

## Before you change the script

Three non-obvious rules shape
[`linux/scripts/renovate-local.sh`](../linux/scripts/renovate-local.sh), and each
one cost a measurement to find. Each has its own section below:

1. It **detects**, it cannot write — [it detects, it does not write](#the-one-thing-to-understand-it-detects-it-does-not-write)
2. A bare `git submodule update --remote` is forbidden here — [why `--apply` refuses some submodules](#why---apply-refuses-some-submodules)
3. The apply half needs the git that wrote the working tree — same section.

## Why local, when a `renovate.json` already exists everywhere

Every repo here carries a `.github/renovate.json` that extends the shared preset
at this repository's [`default.json`](../default.json). That preset exists for one
line — enabling the `git-submodules` manager, which Renovate **disables by
default**, and which is why no gitlink in this family has ever been watched by
anything.

None of it runs. **The Renovate GitHub App has never been installed on any of
these repositories.** The configs are not wrong — all six validate, plain and
under `--strict` — they are simply inert. Installing the App remains worth doing
(it is the only thing that opens PRs on a schedule and produces the dependency
dashboard), but the local CLI is what makes the same answer available now, and it
stays useful afterwards: it tells you what a bot would propose without waiting
for one.

There is also nothing else watching. **No gate in this repository checks gitlink
freshness** — no `verify_*.py` looks at it. That is how two nested ContainerHub
pins (in AccelerANTgine and OxidANT) drifted 54 commits without a single red
build.

## The one thing to understand: it detects, it does not write

`--platform=local` **cannot write.** Renovate's own `platform/local/index.js`
hard-forces `dryRun`, and a non-dry run leaves the working tree byte-identical —
measured on 44.71.0, not inferred from the docs. Anyone expecting "Renovate
updates the files" will conclude the script is broken.

So the loop has two halves, and the script owns both:

| Half | Who does it | What it is |
|---|---|---|
| Decide | Renovate CLI | reads the repo's own config, reports what is behind |
| Apply | `git submodule update --remote -- <explicit paths>` | moves the gitlinks |

For managers other than `git-submodules` (npm, dockerfile, github-actions), the
script reports and you apply the change yourself — there is no safe generic
"apply" for those, and pretending otherwise would be worse than the gap.

## Why `--apply` refuses some submodules

A bare `git submodule update --remote` moves **every** gitlink. For a submodule
that declares no `branch =` it does not skip — it walks the submodule to the
**remote's default branch**.

This was established by experiment, not from the manual: a synthetic
superproject whose submodule declares no branch, against an upstream whose
default branch is deliberately named `trunk`, had `trunk` checked out and staged
by a bare `--remote`.

In this family that has a name. BeschleunigerBallett's `third_party/FUZZTEST` is
pinned to the tip of a **frozen** `release_<date>` line; a bare `--remote` walks
it 82 commits onto `main`, which is precisely what the paragraph in its
`.gitmodules` exists to prevent — and which that paragraph wrongly claimed was
impossible until 2026-09-09.

So `--apply`:

* passes **explicit paths**, never the bare form;
* includes a submodule **only if it declares `branch =`** in `.gitmodules`, and
  prints the ones it skipped with the reason;
* never uses `--recursive`, which additionally dirties nested submodules' own
  working trees with gitlink changes the superproject cannot commit;
* **stages nothing and commits nothing.** It prints `git submodule summary` and
  stops. Reviewing the move is yours.

Renovate has the same blind spot, incidentally — it reports FUZZTEST as behind
too. The difference is that its version is a PR you can close, while a bare
`--remote` is already in your index. That is why `renovate.json` holds that one
path to `dependencyDashboardApproval`.

## Pins, and why Node is one of them

`NODE_VERSION` and `RENOVATE_VERSION` live in
[`linux/scripts/01-core/versions.env`](../linux/scripts/01-core/versions.env),
like every other tool this repo bootstraps on demand. Both are marked
`# noforward` — no image installs them.

Node is pinned because Renovate 44 declares `"node": "^24.11.0"` and dies on
Node 22 with `TypeError: RegExp.escape is not a function`, an error that names
nothing relevant. A PATH copy of node is used only when it is already ≥ 24;
otherwise the pinned tarball is downloaded once, **SHA256-verified**, and cached
per version under `~/.cache/kataglyphis` (override with `RENOVATE_LOCAL_CACHE`).
Renovate itself is installed into a user-owned npm prefix — no sudo, nothing
global.

## Scoping, and a trap worth knowing

The script defaults to `--managers git-submodules`. Widen it deliberately:

```bash
scripts/linux/renovate-local.sh --managers git-submodules,github-actions,dockerfile .
```

An **unscoped** run throws dozens of `spawn flutter ENOENT` / `spawn dart ENOENT`
rejections on the Flutter repos: the npm install carries no language toolchains,
so managers that shell out to one fail noisily without failing the run.

No token is needed for submodules — the `git-submodules` manager uses the
`git-refs` datasource, i.e. anonymous `git ls-remote`, and `git@github.com:` URLs
are rewritten to `https://` automatically. Other managers will warn that a
GitHub token would give better results; supply one with
`RENOVATE_TOKEN=$(gh auth token)` when you care about those.

## Full fidelity, when the report is not enough

`--platform=local` does not resolve `extends`, so it does not prove the shared
preset works. That needs the GitHub platform in dry-run — which still writes
nothing:

```bash
RENOVATE_TOKEN=$(gh auth token) \
  node "$(scripts/linux/renovate-local.sh --print-bin)" \
       --platform=github --dry-run=full \
       --enabled-managers=git-submodules Kataglyphis/BeschleunigerBallett
```

That prints the branches it would open, e.g.
`renovate/third_party-imgui-digest`.

## Where the moving parts live

| Thing | Path |
|---|---|
| The script | [`linux/scripts/renovate-local.sh`](../linux/scripts/renovate-local.sh) |
| Version pins | [`linux/scripts/01-core/versions.env`](../linux/scripts/01-core/versions.env) |
| Shared Renovate preset | [`default.json`](../default.json) |
| This repo's own config | [`.github/renovate.json`](../.github/renovate.json) |
