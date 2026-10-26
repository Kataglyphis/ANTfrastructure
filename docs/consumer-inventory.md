<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Consumer inventory — proving who calls this hub

## Why a grep was not enough

Three deletions in this repository have had to be restored. Every one of them
was justified the same way: a search found no caller. The search was right about
the machine it ran on and wrong about the world — the caller lived in a
repository that was not checked out there.

That failure mode cannot be fixed by grepping harder. A hub cannot see its
consumers, so the list of them has to be **declared**, kept under review, and
walked from a clean clone every time the question is asked.

## The consumer inventory

Two files, one workflow.

The declared inventory names all 20 active repositories owned by Kataglyphis: the hub,
its original eleven family consumers, and eight other active projects and forks. Archived
repositories are excluded because they cannot receive this live CI integration. ModelANT
and AssetANT remain named because their release/check workflows call hub actions.
The large LLVM fork makes the weekly clean-clone check more expensive, so its job has a
60-minute timeout; clone or scan failure remains fatal.
Path reachability is supplemented by the runtime [image acceptance](image-acceptance.md)
checks; a file that exists can still reject arguments or produce the wrong result.

| Piece | Path |
|---|---|
| The declared list of consumers and of the entry-point classes | `.github/consumers.json` |
| The checker that clones them and grades the entry points | `linux/scripts/verify_consumer_inventory.py` |
| The checker for active consumer CI quality calls | `linux/scripts/verify_consumer_quality_wiring.py` |
| The shared Bash/PowerShell overlap scanner | `docs/scripts/verify_fleet_reuse.py` |
| The weekly run that produces the report | `.github/workflows/consumer-inventory.yml` |

A failed weekly run **files or updates a GitHub issue** titled
`consumer-inventory: integrity failure`, labelled `documentation`, with
`logs/reports/consumer-inventory.md` as the body (the issue-filing step in that workflow,
`if: failure()`, job-scoped `issues: write`). It updates the open issue instead
of opening a second one, and it does not suppress the failure: the run is still
red. This exists because the answer changes when a *consumer* changes, which this
repository never sees — so the only reader of a Monday-morning red run would
otherwise be whoever happened to open the Actions tab.

Run it against clones:

```bash
python3 linux/scripts/verify_consumer_inventory.py --report logs/reports/consumer-inventory.md
```

Run it against checkouts you already have, with no network at all:

```bash
python3 linux/scripts/verify_consumer_inventory.py --offline \
    --local-root /c/GitHub --report logs/reports/consumer-inventory.md
```

`--local-root DIR` picks up `DIR/<name>` for every consumer whose name matches a
directory there; `--local NAME=PATH` names one explicitly. Under `--offline` a
consumer with neither is a **failure**, not a skip.

## Fleet script reuse report

The same weekly workflow reads GitHub's active, owned, nonfork repository list,
then measures Bash and PowerShell overlap across those repositories using the
checkouts already obtained by the inventory. It uploads
`logs/reports/consumer-reuse.md` as a separate artifact. The script reuses the
existing token and function readers, omits generated/vendor trees, and excludes
declared shared copies only after the shared-config drift checker passes. A
consumer such as DocumANTation needs no Hub submodule to be measured. The list
must contain the Hub and every active owned nonfork repo must have a declared
checkout; missing entries and broken inputs fail. Findings remain advisory.

To reproduce the report with sibling local checkouts, run:

```bash
mkdir -p logs/reports
gh api --paginate '/users/Kataglyphis/repos?type=owner&per_page=100' \
  --jq '.[] | select(.fork == false and .archived == false and .owner.login == "Kataglyphis") | .full_name' \
  > logs/reports/owned-active-repos.txt
python3 docs/scripts/verify_fleet_reuse.py --hub . --local-root .. \
  --owned-list logs/reports/owned-active-repos.txt \
  --report logs/reports/consumer-reuse.md
```

`--checkout NAME=PATH` can supply or override one checkout. A private owned repo
requires `CONSUMER_INVENTORY_TOKEN` in CI; the workflow then uses the authenticated
owner inventory. The public fallback sees only public repos. Reports and the API
list stay under ignored `logs/`. The report caps detailed unit pairs at 100 while
retaining total and per-repository counts, and lists widely copied blocks above
the scanner's idiom cutoff. A token overlap is a lead for code review; different
token structure can hide equivalent behavior.

The same run inspects each consumer's tracked CI workflows. A detected call to
`lint-gates.yml` must pass literal `ratchets: true`; a direct `run-lint-gates.sh`
call must pass `--ratchets`. Disabled or nonfatal calls fail the inventory. The
report lists consumers with no detected call as advisory. Deleting every lint
call or hiding one behind a wrapper is outside this check; review the advisory
rows before treating the family as fully covered. To check one local consumer
without cloning the family, run `python3
linux/scripts/verify_consumer_quality_wiring.py --root <consumer-root>`.

## What counts as reachable

The report grades every entry point into exactly one of four states, and the
distinction that matters is between the second and the third:

| Verdict | Meaning | What it licenses |
|---|---|---|
| reached by a consumer | Some repository other than this one executes it | Changing it is a breaking change for the named repos |
| hub-internal only | This repository executes it; nobody else names it | Refactor freely; it is not published surface |
| mentioned, never reached | Named in prose or in a comment, run by nothing | Deleting it breaks a document, not a build |
| named by nobody | No repository in the inventory names it at all | The candidate list for deletion |

A hit is **reached** when it sits somewhere that runs: a `uses:` value, a `run:`
line, a `source`/`Import-Module`/`include()` call. It is **mentioned** when it
sits in a Markdown or reStructuredText page, in a `.allow` row, or on a line
that opens a comment. A hub script named in a consumer's changelog keeps nothing
alive, and a report that counted it would hand back the same false confidence
the grep did.

## Entry points are declared, not guessed

`entry_point_classes` in the inventory expands globs into the concrete entry
points to grade. A class that expands to zero files fails the run — a silently
empty class would quietly shrink the surface being examined.

Two classes carry an `alias`, because their entry points are not reached by
path at all:

- `windows-module` — a consumer writes `Resolve-BuildModulePath -Name
  'WindowsBuild.Common'`. Grading on the path alone reported all
  twenty-two modules dead.
- `cmake-module` — a consumer puts the hub's `cmake/` on `CMAKE_MODULE_PATH`
  and writes `include(Sanitizers)`.

An alias hit is discarded when the consumer owns a file of that basename: its
own module shadows the hub's, so the reference is not evidence about the hub.

For a root file slated for deletion, a one-off class can use `"match": "root-file"`.
It counts a consumer path only when it is explicitly qualified with the hub's
name or submodule path, and a hub path only when rooted at `${REPO_ROOT}` or
`${HUB_ROOT}`. A bare `requirements.txt` may mean a consumer's own file, a
temporary export or a generic helper default, so it is not evidence about the
hub root file. Review dynamic and unqualified paths separately; the static
inventory cannot prove where they resolve at runtime. Remove the temporary
class when deleting the file, since an empty class correctly fails the run.

## What makes the run fail

Only integrity failures — never the verdicts themselves. The counts are a
report for a human; these are defects, alongside a detected CI lint call with
disabled ratchets or suppressed failure:

1. **A consumer cannot be obtained.** The clone failed, the checkout is missing,
   or `--offline` was given without a local path for it. A skip here would turn
   "no caller found" into a lie shaped exactly like the truth.
2. **A consumer is not a git checkout, or has no tracked files.** A partial tree
   would under-report callers.
3. **A dangling reference.** An executable line in any scanned repository names
   a hub path that does not exist. Comments are exempt: a comment recording that
   a path was removed is prose about the hub, not a broken call.
4. **The inventory does not parse, or declares no self consumer.** Without a row
   marked `self`, nothing can separate hub-internal use from a real caller.
5. **A workflow naming a lint call does not parse.** The quality call check
   cannot safely grade that call from partial YAML. A detected lint call with
   inactive or nonfatal settings also fails. Malformed workflows with no lint
   reference remain advisory here; their syntax is owned by the workflow lint.

## Keeping the list true

The inventory is only as good as its `consumers` array, so the file carries a
second array, `unconfirmed`, for repositories that an audit has *named* but
nobody has *verified*. The checker prints how many are still open on every
successful run. Each row must end one of two ways: promoted into `consumers`
with `confirmed: true`, or deleted because the repository does not exist.

Treat a `named by nobody` verdict as a lead, not a licence, while that array is
non-empty. It is a statement about the repositories in the list — nothing more.
