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

# show every write it would make, and make none of them
third_party/ContainerHub/linux/scripts/renovate-local.sh --apply --dry-run .

# ...and make them: gitlinks move with git, every other ecosystem is one
# value rewritten on one line, and the lockfile beside it is refreshed
third_party/ContainerHub/linux/scripts/renovate-local.sh --apply .
```

Consumers reach it through their own thin wrapper, named `renovate-local.sh` and
placed wherever that repo already keeps its ContainerHub wrappers -
`scripts/linux/` in BeschleunigerBallett, OmniAccelerANT and OrchestrANT, but the
flat `scripts/` in jotrockenmitlocken. Same shape as `run-lint-gates.sh` there.

## Before you change the script

Nine non-obvious rules shape
[`linux/scripts/renovate-local.sh`](../linux/scripts/renovate-local.sh) and the
three python modules beside it, and each one cost a measurement to find. Each
has its own section below:

1. It **detects**, it cannot write — [it detects, it does not write](#the-one-thing-to-understand-it-detects-it-does-not-write)
2. A line is found by the manager's **own syntax**, never by searching for the old value — [how one value gets rewritten](#how-one-value-gets-rewritten)
3. The edit is **audited by a real parser**, before and after — [the edit is audited by a real parser](#the-edit-is-audited-by-a-real-parser)
4. A refusal is a **result**, and carries its own exit code — [the mechanics of a refusal](#the-mechanics-of-a-refusal)
5. Every path it writes to is **inside the checkout** — [nothing outside the checkout](#nothing-outside-the-checkout)
6. A run writes **all** of its files or **none** of them — [all of it, or none of it](#all-of-it-or-none-of-it)
7. An edited manifest whose lock is stale is half a job — [lockfiles are part of the job](#lockfiles-are-part-of-the-job)
8. A bare `git submodule update --remote` is forbidden here — [why `--apply` refuses some submodules](#why---apply-refuses-some-submodules)
9. The apply half needs the git that **wrote** the working tree — [which git runs the apply half](#which-git-runs-the-apply-half)

## Why local, when a `renovate.json` already exists everywhere

Every repo here carries a `.github/renovate.json` that extends the shared preset
at this repository's [`default.json`](../default.json). That preset exists for one
line — enabling the `git-submodules` manager, which Renovate **disables by
default**, and which is why no gitlink in this family has ever been watched by
anything.

None of it runs on GitHub. **The Renovate GitHub App is installed on none of
these repositories, and it is not going to be** — owner decision, 2026-09-09:
"die renovate github app wird nicht installiert. benutze immer renovate cli".

The configs are not wrong, and they are not idle either: all eight validate,
plain and under `--strict`, and the local CLI reads exactly these files — the
preset, the git-submodules manager and the grouping rules all take effect
through it. What the family gives up is the scheduled PR and the dependency
dashboard. What it keeps is the same answer on demand, from a tool that needs no
permissions on the account and leaves no bot commits in the history.

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
| Apply, gitlinks | `git submodule update --remote -- <explicit paths>` | moves the gitlinks |
| Apply, manifests | `renovate_locator.py` + `renovate_planner.py` | rewrites one value on one line, then refreshes the lock |

A manager with no locator of its own is **refused by name**, not guessed at:

```
NOT APPLIED - the report named these, but the locator would not place the
value without guessing. The reason is exact; edit them by hand:
  dockerfile  Dockerfile  ubuntu  22.04 -> 26.04  -- no exact locator for
  manager 'dockerfile'; this tool refuses to edit a syntax it cannot parse
```

## How one value gets rewritten

This is the section to read before touching
[`linux/scripts/renovate_locator.py`](../linux/scripts/renovate_locator.py).

An earlier version of the apply half located the line to edit by **searching for
the old value** and then narrowing to a candidate near a line that mentioned the
dependency. It was withdrawn, because a text search is a heuristic wearing a
match's clothes. Measured, with rc 0 in every case:

* a `requirements.txt` whose first line is `# ruff is managed by renovate` and
  whose second is `black==0.9.0`, against a report naming **ruff**, wrote
  `black==0.16.6`;
* a `pubspec.yaml` declaring only `http_parser: 1.1.0`, against a report naming
  **http**, wrote `http_parser: 1.6.0`;
* a workflow using only `actions/checkout-extra@v4`, against a report naming
  **actions/checkout**, wrote `actions/checkout-extra@v5`.

`--dry-run` did not reveal any of it: it printed the right dependency name
against the wrong line.

So the rule is now the opposite one. **The line is found by the manager's own
syntax, anchored on the dependency NAME. The old value is never searched for —
it is only ever confirmed on a line that was already located.**

| Manager | What counts as a declaration | Where the value is |
|---|---|---|
| `github-actions` | a `uses:` key of a **step** (a sequence item) or of a **job** (`jobs.<id>.uses`), whose value splits at the **last** `@` into `<dep>` or `<dep>/<path>` | the ref after that `@` |
| `pub` | a key whose whole key **is** the dep, in a top-level `dependencies` / `dev_dependencies` / `dependency_overrides` mapping | the scalar after the colon |
| `pip_requirements` | a PEP 508 line whose name **normalises** to the dep (PEP 503: `-`, `_`, `.` and case all fold) | the specifier, up to any `;` marker |
| `pep621` | a quoted PEP 508 string inside a dependency **array** — `[project] dependencies`, an `optional-dependencies` group, `build-system.requires`, `dependency-groups` | the specifier inside that string |
| `pre-commit` | the `rev:` of the sequence item whose **own** `repo:` resolves to `<owner>/<repo>` | the `rev:` scalar |
| `cargo` | a key in `[dependencies]` / `[dev-dependencies]` / `[build-dependencies]` — optionally under `[workspace.…]` or `[target.<cfg>.…]`, optionally one segment deeper for one crate (`[dependencies.serde]`) | the bare string, or the inline table's `version` |
| `npm` | the dep's key inside a **top-level** dependencies object of `package.json` | the version string |

The three "what counts" columns that read oddly are the ones that were wrong.
A `uses:` is not a step's just because the line spells `uses:` — a `with:` input
named `uses`, and a `uses:` printed inside a `run: |` block, were both being
rewritten. A cargo table is not a dependency table just because its last
segment is `dependencies` — `[package.metadata.dependencies]` was read as one.
And an npm key is not a dependency because the object above it is called
`dependencies` — the finder popped its object stack on every `]` without ever
pushing on `[`, so it could not say which object a key was in at all. All three
now parse the document rather than the line.

Five properties follow, and
[`linux/scripts/tests/test-renovate-local.sh`](../linux/scripts/tests/test-renovate-local.sh)
holds a fixture for each:

1. **The located line names the dep in that manager's syntax.** A comment
   declares nothing. `http` is not `http_parser`, `torch` is not `torchvision`,
   `actions/checkout` is not `actions/checkout-extra`, and a `"onnxruntime"`
   sitting in `[project] keywords` is not a pin — that last one was a real false
   positive, found by running the locator over OrchestrANT's own
   `pyproject.toml`, and it is why `pep621` reads the TOML table first.
2. **Exactly one line, or a refusal.** Zero matches is a refusal too, never a
   fallback to searching. So is a declaration written in a form the locator
   cannot read: a pubspec spelling `http` as a `hosted:` map with the version
   nested under it used to have its `dependency_overrides` entry rewritten
   instead — the report's dependency, the wrong declaration of it. A line
   carrying no value now refuses the whole group and prints `(no value)` beside
   its line number.
3. **The value is confirmed on that line before anything is written.** A
   declaration carrying something the report did not predict means something
   moved, and the run says so instead of guessing:
   `'http' is declared at line(s) 3:2.0.0, and none of them carries the reported
   current value 1.1.0 -- something moved, so nothing is written`.
4. **Idempotence is structural.** Re-applying the same report re-reads the file,
   finds the dep's own line already at the new value, and prints `already
   applied`. There is no "did we do this already" memory to get out of step.
   For that to hold, a line that states no version **here** must not count as a
   declaration: `clap = { workspace = true }` in a member's `[dependencies]`
   delegates to `[workspace.dependencies]`, and counting it made the second
   `--apply` over OmniAccelerANT's own `Cargo.toml` refuse — the workspace table
   was at the new value, the inheriting line carried nothing, and the two
   disagreed forever. A path or git dependency is skipped for the same reason.
5. **`--dry-run` prints the file, the line NUMBER and both texts**, so the plan
   is reviewable without opening the file:

   ```
   file edit(s) -- <file>:<line>, then that line before and after:
     pubspec.yaml:3  http  1.1.0 -> 1.6.0
     -   http: 1.1.0
     +   http: 1.6.0
   ```

### When several lines declare the same dependency

A report row describes **one** pin. Renovate emits one row per occurrence, so
the planner groups rows by *(file, dep, old, new)* and hands the locator the
count. Then:

* **counts agree** — every located line carries the same old value and receives
  the same new one, so the rewrite is identical under any assignment of rows to
  lines. There is nothing left to guess, and all of them are written. This is
  the ordinary case for a workflow that uses `actions/upload-artifact@v7.0.1` in
  two steps, which
  `.github/workflows/dart_on_native_linux.yml` in OmniAccelerANT does.
* **counts disagree** — one reported update, two pins in the file. Which line
  the row means is not knowable, so **nothing is written** and both line numbers
  are printed.

## The edit is audited by a real parser

Everything above is about finding the right line. This section is about not
having to be right.

Five waves of adversarial fixtures were run against
[`renovate_locator.py`](../linux/scripts/renovate_locator.py). Each closed the
cases it found; each was followed by a wave that found new ones. The last three,
all measured on 2026-09-10, all legal syntax, all writing the **wrong**
declaration at rc 0:

* a YAML **anchor** on the dependencies key. `dependencies: &deps` puts a value
  after the colon, so a line-level reader never opens the mapping under it —
  the whole section disappears from its view, `dependency_overrides` becomes the
  only `pub` section it can see, and that entry is what `--apply` rewrote.
* a UTF-8 **BOM** before the first TOML table header. The BOM defeats the
  `[project]` match, so the table the reader thinks it is in is the one *before*
  it, and the `[dependency-groups]` entry is what got written.
* the block scalar header spelled **`|2-`**. YAML 1.2 permits the indentation
  indicator on either side of the chomping indicator, `|-2` was recognised and
  `|2-` was not, so the body of a `run:` block was read as document structure
  and a workflow that was merely being *printed* had its `uses:` rewritten.

The pattern is the point. A hand-rolled parser for YAML, TOML and JSON cannot be
emptied of edge cases by iteration, and a sixth wave would have found a seventh.
So the guarantee changed **kind** rather than getting another patch.

### The invariant

[`renovate_audit.py`](../linux/scripts/renovate_audit.py) reads what the file
**means**, with the parser the ecosystem itself uses — PyYAML for YAML, the
standard library's `tomllib` for TOML, `json` for JSON — and it does this twice:

1. **before** the edit, to work out which *paths* in the parsed document declare
   the reported dependency at the reported old value, and what each of them must
   read afterwards;
2. **after** the edit, over the bytes read back **off disk**;

and then it diffs the two structures. What is allowed is exactly this:

> One leaf per reported update differs. Each is at a path that declares the
> reported dependency. Each goes from the reported old value to the reported new
> one. Nothing else in the document differs — no key added, none removed, no
> second value moved, and the file still parses.

Anything else is a refusal. After a write, a refusal puts **every** file of the
run back to the bytes it had and exits non-zero.

The paths come from the parse and **never** from the locator. That is the whole
point: the check does not verify that the locator was consistent with itself, it
audits the result against an independent reading of the same file. A locator
that picks the wrong line writes a change at a path the audit did not sanction,
and is caught for that alone — whatever the reason it went wrong, including
reasons nobody has thought of yet.

The comparison is of the **parsed structure**, not of text. PyYAML discards
comments and formatting, so a textual comparison is not available — and is not
wanted. "The meaning changed in exactly one place" is the invariant that
matters, and it is the one being checked.

### Where it fires, and what each refusal costs

| When | What it sees | What it does |
|---|---|---|
| planning a group | the file as it stands | `SKIP` with the reason; the run's other files still apply, `--dry-run` prints it, rc **2** |
| the pre-flight | every group of one file together, **and** the text the write would produce | rc **1**, nothing written in any file |
| after the write | the file read back off disk | every file of the run put back, rc **1** |

The first row is why one awkward manifest does not block a whole update run — and
why it is rc 2 rather than 0; see [the mechanics of a
refusal](#the-mechanics-of-a-refusal). The third is the one the safety rests on:
a file *is* briefly written before it is audited, and the window is closed by
`os.replace` (so the file is always the old bytes or the new ones, never a
prefix) plus the copy `renovate-local.sh` already takes beside every target
before the first write.

The second row now runs the third row's check too, over the text the write
*would* produce. `verify` predicts, `edit` proves — deliberately two readings
rather than one, because a simulation proves a string and only reading the file
back proves the **file**. In normal operation the prediction means a bad edit is
refused before a byte moves; the read-back stays as the check that does not
trust the write.

### Four decisions, argued

**A manifest that does not parse before the edit is not touched.** It cannot be
audited, and writing a value into a file whose meaning cannot be read is
precisely what the five waves kept doing. The refusal names the parser and what
it objected to.

**A leading BOM is stripped, on both sides.** `tomllib` and `json` reject one
outright, so keeping it would refuse every manifest a Windows editor has saved.
It is an artefact of the byte stream rather than a member of any of these
grammars, and no construct can span it, so removing it cannot move a value —
and removing it identically before and after keeps the diff honest.

**Anchors and aliases are counted by path, not by node.** An alias makes one
YAML node reachable at several paths, and a text edit cannot change it at one of
them without changing it at all of them. So an aliased declaration reads as more
than one changed leaf and the run refuses, rather than reporting a blast radius
of one line when the real one is two. That is the conservative reading and it is
the true one.

**`requirements.txt` gets a parser of its own**, because there is no standard
one and a line-level check for this format alone would be the exception that
eats the rule. It is small and deliberately not line-shaped: comments and blanks
are dropped, pip's backslash continuations are joined, and each requirement is
split into name, extras, specifier, options and marker. Splitting is what makes
the diff mean something — rewriting the version moves the `spec` field and
nothing else, so a write that also disturbed a marker or a `--hash` shows up as
a second changed leaf.

**A pin carrying `--hash` digests is refused by name.** `pip-compile
--generate-hashes` writes `ruff==0.9.0 \` and a `--hash=sha256:…` continuation
that pip joins straight back on. Splitting those digests out of the specifier is
what lets this tool *see* them, and what it does when it sees them is **refuse**:
the digests describe the artefacts of the release being replaced, nothing here
recomputes them — that is `pip-compile`'s job, and this tool knows no lock
command for a requirements file — and pip does not fall back to an unverified
download, so a version moved on its own leaves a file nobody can install from.
That is the same verdict [lockfiles are part of the
job](#lockfiles-are-part-of-the-job) reaches about an edited manifest beside a
stale lock.

Until 2026-09-10 that decision was argued here and **reachable by nothing.** The
locator read `ruff==0.9.0 \` as the value `==0.9.0 \`, which matched no reported
current value, so such a file was refused one step earlier and with the wrong
reason — *"something moved, so nothing is written"*, about a pin that had not
moved. The locator now joins pip's continuations the way pip does, the pin is
located, and the refusal is the true one:

```
pip_requirements  requirements.txt  ruff  ==0.9.0 -> ==0.16.6  -- [0].spec
declares 'ruff', and this requirement is pinned by digest
(--hash=sha256:abc), and those digests describe the release being replaced.
Nothing here recomputes them -- re-run pip-compile -- and pip rejects a
requirements file whose hashes do not match, so the version is not moved on
its own
```

### What this costs

**PyYAML is now required** to write a YAML manifest — a workflow, a pubspec, a
pre-commit config. Without it the run ends saying so. There is no fallback,
because the only available fallback is the line-level reading this section
exists to stop resting on. TOML and JSON need nothing that is not in the
standard library.

### The proof

[`test-renovate-audit.sh`](../linux/scripts/tests/test-renovate-audit.sh)
carries the three cases above and, for each, asserts **two** things: that the
run refused, and that the locator *alone* still picks the wrong line. A fixture
that went green because the locator quietly started getting it right would prove
nothing about this guarantee, so `_locator_says` runs the locator by itself and
the expected wrong answer is written down.

The post-write half is proved where it can only be proved — by being wrong on
purpose. A plan file naming the wrong line is handed straight to the apply half:
every pre-flight passes (the file declares the dependency exactly once), the
edit *is* written, and the audit catches where it landed and puts the file back.
The same plan aimed at the right line still applies, so the check is not merely
refusing everything.

One case is not a fixture at all but a defect this found. `newValue` arrives
from the report, which is JSON another program wrote, and it goes into the file
as text: a value carrying a `"` closes the JSON string it lands in and opens a
second key. Nothing that reads the file *as it stands* can see that. The audit
reads the file as it *ends*, sees a path that was not there before
(`dependencies.evil`), and undoes the run.

## The mechanics of a refusal

Everything above is about *deciding* to refuse. This section is about what a
refusal then costs, and every item in it is a defect measured on **2026-09-10**
against a tool whose decisions were already right. They share a shape: the run
printed the correct thing and then behaved as though it had not.

### What a caller branches on

**A refusal used to exit 0.** A `pubspec.yaml` whose `dependencies:` key carries
a YAML anchor, as the only update in the report, printed the refusal in full and
exited **0** — byte-identical, to anything reading `$?`, to a repository with
nothing behind. Every plan-time refusal landed in that class: the locator would
not place the value, the parser would not sanction the edit, the repo's own
config sent the update to a human, a submodule declares no `branch =`. Those are
all the same fact — *the report named an update and this run did not write it* —
and it is not the same fact as *there was nothing to write*.

So `renovate-local.sh` has three codes for a run that finished, and 128+n for one
that was stopped. They answer different questions:

| rc | What it means | The tree | What to do |
|---|---|---|---|
| **0** | every reported update is now at its new value, or already was | consistent, and up to date | review and stage |
| **2** | the run completed, but at least one reported update was **not** applied | consistent — everything else applied | a human applies the rest; the list is in the output |
| **1** | the run could not complete | where it started: nothing written, or everything written — manifests, lockfiles **and gitlinks** — was put back | fix the cause and re-run |
| **130 / 143 / 129 / 141** | SIGINT / SIGTERM / SIGHUP / SIGPIPE | put back first — see below | re-run when ready |

Two is the family's "the tool could not do its job" (`docs/code-quality-tooling.md`,
*"Exit 2 is never a pass"*). One stays what it was, because *the run aborted* and
*the run refused one update of five* are different facts with different
consequences — and a caller that treats them alike will retry the wrong one.

rc **1** also covers one case that is not the current run's fault: an *earlier*
`--apply` over the same checkout was killed before it could finish or undo
itself, so this run refuses to read a tree that may be half-applied. See [a kill
cannot be trapped, so it is declared
instead](#a-kill-cannot-be-trapped-so-it-is-declared-instead).

Three consequences worth stating plainly:

* **Partial success is not success.** A run that applies nine of ten exits 2. rc
  0 from `--apply` is a promise about *every* update the report named.
* **`--dry-run` exits what `--apply` will exit** for every verdict a *plan* can
  reach. There is exactly one class where the two differ, it is the class no
  plan can predict, and it is [pinned by a case rather than
  claimed](#what-a-dry-run-cannot-promise).
* **"already applied" is not a refusal.** A second `--apply` over the same
  report reports `DONE` and exits 0. Nothing was behind.

### The dry run predicts the write

`print_dry_run` claimed to show *"the exact writes this would make, and nothing
else"*, and did not run the post-write audit. Measured: a report whose `newValue`
carried a `"` printed a clean plan at rc 0 under `--dry-run`, and `--apply` then
refused it after the write. The plan a reviewer approved was not the plan.

The pre-flight now runs that audit too, over the text the write *would* produce,
without writing it. Both invocations give the same exit code and the same
sentence. `verify` predicts; `edit` still proves — see the table under [where it
fires](#where-it-fires-and-what-each-refusal-costs) for why both are kept.

### A key written twice

`http: 1.1.0` twice in one `dependencies:` mapping is legal YAML and resolves
last-wins. A line reader resolves it last-wins too — so the locator and PyYAML
**agreed**, the edit landed on the winner, the audit sanctioned it, and the file
was left declaring one dependency at two different values at rc 0.

The asymmetry is what proved it an oversight rather than a policy: a plan aimed
at the *shadowed* copy was already caught, because the winner never moves. So a
repeated key is refused, in every format that lets one be written: PyYAML is
driven through a loader that raises on one, `json` through an object hook that
does the same, and `tomllib` already refuses. A manifest that says two things
about one dependency is not one this tool edits.

### An audit that raises defeats the rollback

The audit is what *triggers* the rollback, so an audit that dies takes the
rollback with it. Measured: a `newValue` nesting 1200 arrays — which `json`
parses without complaint — made the recursive walk that compares the two
documents hit python's recursion limit, and the `RecursionError` travelled out of
the audit, past `_put_back()`, and left the hostile write on disk at rc 1.

Two fixes, because either alone would leave the hole:

* the walk is **iterative** and bounded by a declared depth as well as a declared
  path count, so a deep document is a *refusal* with a reason rather than an
  exception;
* **any** exception from the audit now takes the same road an audit *failure*
  does — every file back, and a message naming what raised. The rollback does not
  rest on the auditor being correct, because resting on that is the thing the
  auditor was written to replace.

### A signal is not a clean exit

`refresh_locks` is where a real `cargo update` or `npm install` spends minutes,
and it is the worst possible moment to stop: the manifests are written and a
lockfile is half-written. Measured, at exactly that point:

| Signal | rc | What was left |
|---|---|---|
| SIGINT (Ctrl-C) | **0**, printing *"Nothing is staged or committed"* | manifest written, lock half-written, copies deleted |
| SIGTERM (a CI cancel) | 143 | the same |
| SIGHUP | 129 | the same |
| SIGPIPE (`\| head`, `\| less` then q) | **not trapped at all** | fatal by default: the run died at whatever byte it had reached |

All four are now trapped, run the same undo a failed lock tool gets, and exit
the conventional 128+n. And the copies beside the run are deleted only when the
run **settled** — every file written and its locks refreshed, or every file
proven put back one by one. `RESTORE_FAILED is empty` was not that test: it is
also empty when no restore was ever attempted, which is precisely the state a
signal left behind while `cleanup()` deleted the only copies there were.

**SIGPIPE is the one a human actually sends,** and it was the one left out.
`renovate-local.sh --apply … | head -n 9` closes the pipe as soon as head has
its nine lines; the next `printf` then kills the run outright. Measured at three
cut points on the same fixture — at 3 and 6 lines nothing had been written yet
but a directory of copies was stranded in `TMPDIR`; at 9 the manifest was at its
new value with the lockfile never refreshed. Exactly the half-applied tree the
rest of this section exists to prevent, reached by typing `| head`.

Worse, the *caller* could not see it. In a pipeline `$?` is head's status, which
is 0 — so a killed run reads as a passing one unless `set -o pipefail` is on.
(This cost the owner two repositories out of a scan in one day.) Trapping the
signal is what makes the rc reachable at all: with the trap, the run undoes its
writes and exits **141**, and `pipefail` surfaces it.

One detail the trap has to get right: after SIGPIPE, stdout is a pipe nobody is
reading, so every line of the undo report would go nowhere. `on_signal` moves to
**stderr** for that signal alone — which `| head` leaves open — so the person who
typed the pipe still learns what was put back.

One limit, found while writing the fixture and worth knowing rather than
papering over: **a run started in the background with `&` cannot trap SIGINT at
all.** POSIX requires an asynchronous command to be given `SIGINT` and `SIGQUIT`
ignored, and a shell cannot trap a signal that was ignored on entry — so a
backgrounded `--apply` simply keeps going, which is what "ignored" means. SIGTERM
and SIGHUP are unaffected, and a CI cancel sends SIGTERM. The suite restores the
two dispositions before launching, so what it measures is the Ctrl-C a person
actually types rather than its own launcher.

### Putting back means the times too

`renovate_planner.py edit` restored the bytes and the mode of a rolled-back file
and stamped it with *now*. The preservation anyone saw through
`renovate-local.sh` came from that script's own `cp -p` copies, one layer up — so
the guarantee was not where the contract is written. A manifest carrying a fresh
mtime is a change to every timestamp-driven tool downstream (make, ninja, cargo,
a watcher) over an edit that was undone. The planner now restores the times as
well, and a case drives the planner *alone* to pin it there.

### The proof, and that it can fail

The three suites carry these:
[`test-renovate-exit.sh`](../linux/scripts/tests/test-renovate-exit.sh) for the
exit codes, the signals, the rollback across both halves and the marker a kill
leaves behind,
[`test-renovate-audit.sh`](../linux/scripts/tests/test-renovate-audit.sh) for the
duplicate key, the raising audit, the dry-run prediction and the mtime.

Each guarantee also has an entry in the [mutation
gate](code-quality-tooling.md#the-mutation-gate-mutations) that neuters it — the
exit code set back to 0, the traps removed (SIGPIPE among them), the gitlink
snapshot skipped, the settle moved back between the two halves, the marker never
written, the refusal that reads it deleted, the duplicate-key raise removed, the
`os.utime` dropped — and the manifest records that its suite then goes red. All
fifteen were re-run after this wave and every one bites. A test that passes with
its fix removed is the failure this repository keeps finding, and none of these
is one.

## Nothing outside the checkout

The report is JSON that another program wrote, and its `packageFile` is a path.
Nothing used to check that the path stayed in the repository being applied to.
Measured 2026-09-10: a report whose `packageFile` was **absolute** made `--apply`
rewrite a file outside the checkout and exit **0**; a `../` path did the same.

So every path is resolved against the target root, and one that does not land
inside it ends the run:

```
the report names '/tmp/elsewhere/pubspec.yaml', which is not a file inside
/home/me/repo; nothing written
```

Both sides are resolved with `realpath`, which makes `..`, an absolute path and
a symlink pointing out of the tree one question with one answer — and makes a
symlinked manifest inside the tree resolve to the real file, so the link is not
replaced by a copy. The check sits where a path **enters** the module — once
over the report, once over the plan file — rather than at each use, because a
check at each use is a check somebody eventually forgets.

## All of it, or none of it

A run that writes half of what it planned is worse than one that writes nothing,
and there were five ways to get one. All five were measured on 2026-09-10, and
all five are closed — the first three below, then [the gitlink
half](#the-gitlink-half-is-part-of-the-unit) and [SIGPIPE](#a-signal-is-not-a-clean-exit):

* **A truncating write.** `open(path, "w")` truncates before it writes, so an
  error in between leaves *no* manifest. Each file is now written to a temp file
  in its own directory and `os.replace`d onto the target: the file is the old
  bytes or the new ones, never a prefix of either. The mode is carried over
  (`mkstemp` creates `0600`). This is also why a manifest whose **directory**
  cannot be written is refused rather than written in place.
* **A plan that walks its files.** Two files in one plan, the second read-only:
  the first was rewritten and the user got a `PermissionError` traceback. Every
  target of the plan is now re-read, contained and proven writable — the file
  opened for update, the directory given a temp file — before the first byte
  goes anywhere. `--dry-run` runs that same pre-flight, so it *predicts* the
  refusal instead of printing a clean plan for a run that would half-apply.
* **A lock tool that fails.** The pre-flight proves the tool **exists**; it
  cannot prove the tool will succeed. A `cargo` that exited 1 left two manifests
  rewritten and one lockfile half-refreshed. The manifest half is now one unit:
  every file it is about to write is copied aside first, and a lock tool that
  fails puts **all** of them back — manifests and lockfiles — and exits
  non-zero. There is no switch to keep the edits, for the same reason there is
  no switch to tolerate a stale lock.

### The gitlink half is part of the unit

Running the manifest half **first** was supposed to make an undone run leave the
whole tree where it started. It did not, and the reason is one line: `apply_files`
ended by *settling* — declaring the tree the good copy and releasing the copies
beside it — and settling happened one line before `apply_submodules` began.

So the two halves were ordered such that the first threw away its safety net
before the second ran. Measured on 2026-09-10, on a superproject with a manifest
and a branch-tracking submodule whose remote was unreachable:

```
rc 1
pubspec.yaml   http: 1.6.0     <- written
git status     M pubspec.yaml
backup copies  gone
```

rc 1 is documented as *the tree is where it started*. It was not.

Two things were missing, and both are now there:

* **A gitlink was never snapshotted.** The undo walks the list of copied files,
  which holds manifests and lockfiles only — so a signal during the submodule
  half undid *nothing at all*, while the header, the docs and the report all
  promised otherwise. Each submodule the run would move now has its position
  recorded before anything is written: the commit **and** the ref it is attached
  to. Both matter, because `git submodule update --remote` leaves a submodule
  **detached** at the new tip, so restoring the sha alone hands a branch checkout
  back as a detached one. Putting it back is `git -C <path> checkout <ref-or-sha>`,
  and the result is read back and compared — a checkout that reports success and
  leaves `HEAD` elsewhere is exactly what this half exists to catch.
* **One snapshot, one settle, across both halves.** `run_apply` takes the
  snapshot before either half writes and settles only after both have finished.
  A failure or a signal anywhere between them puts back everything: manifests,
  lockfiles, gitlinks.

`git submodule update --remote` over several paths is itself **not atomic** — it
walks them in order and one failure leaves the earlier ones moved — which is
precisely why its failure now takes the same undo everything else does, rather
than printing advice about `git submodule update --init` and exiting.

A submodule with **no checkout** is recorded as such and left alone: `--remote`
over an uninitialised path prints `not initialized` and exits 0 without touching
it (measured), so there is nothing to put back and nothing to pretend about.

### A copy nobody can place is not a backup

The copies beside a run are named `0`, `1`, `2` — `restore_targets` indexes them
by position. That is fine while the process is alive and holds the list. It is
useless once it is not: after a kill, the directory held files literally called
`0` and `1`, and the only record of where either belonged had died with the
process.

So the mapping is written to disk as each copy is taken, in a `MANIFEST` beside
them, and it is written for a human rather than for the script:

```
renovate-local.sh kept these copies of the ORIGINAL bytes.
checkout: /home/me/repo
put one back by hand with: cp -p /tmp/tmp.XXXX/<n> /home/me/repo/<path>

<n>	<path>
0	Cargo.toml
1	Cargo.lock
```

### A kill cannot be trapped, so it is declared instead

SIGINT, SIGTERM, SIGHUP and SIGPIPE can all be trapped, and are. **SIGKILL
cannot be** — nor can an OOM kill, nor a power cut. For those, "fully applied or
exactly as it started" is not a promise anything can keep.

What *was* wrong is what happened next. Measured: a run killed mid-refresh left
`Cargo.toml` at its new value beside a `Cargo.lock` that was never refreshed —
and the **next** run over the same report exited **0**, reporting `already
applied — the dependency's own line is at the new value`. The wreckage rendered
as good news, which is the one outcome worse than the wreckage.

So before the first byte is written, the run drops a marker in the checkout's own
git directory (`.git/renovate-local-inflight`) naming everything it is about to
touch, and deletes it when the run settles or is proven put back. It lives in
`.git` deliberately: per-checkout, surviving the process, impossible to commit by
accident, and found by the next run whatever `TMPDIR` that run was given.

Every subsequent run — `--report` included, because a report over a half-applied
tree is exactly the misleading answer above — reads that marker first and
**refuses**, at rc 1, printing what the dead run was doing and the way out:

```
REFUSING to run: an earlier --apply over this checkout was KILLED before
it could either finish or undo itself, so this tree may be HALF-APPLIED
...
Put the tree right, THEN delete the marker:
  git -C /home/me/repo status                          # see what moved
  git -C /home/me/repo checkout -- <path>...           # a tracked file back
  git -C /home/me/repo submodule update -- <path>...   # a gitlink back
  rm /home/me/repo/.git/renovate-local-inflight
```

The advice is deliberately **git-based** rather than pointing only at the copies:
`git checkout --` works from the repository itself, so it still works if the
copies in `TMPDIR` have since been cleaned away.

There is deliberately **no flag that clears the marker**. A switch to carry on
over a known half-applied tree is the tolerated failure this whole section exists
to refuse; deleting one named file is a decision a human makes, and it is theirs
either way — put the tree back first, or keep what is there having reviewed it.

One marker survives on purpose: a rollback that got **stuck**, where a file
genuinely would not go back. That tree really is not where it started, so the
next run really should refuse.

### What a dry run cannot promise

`--dry-run` exits what `--apply` will exit for every verdict a *plan* can reach —
the locator would not place a value, the parser will not sanction the edit, a
path is unwritable, a lockfile is ambiguous, a lock tool is missing, a submodule
declares no branch, the repo's own config sends an update to a human. Measured
across those, the two agree.

They differ on exactly one class, and it is worth naming rather than hiding:
**a tool the pre-flight proved present, which then fails when it runs.** A
`cargo` that exits 1; a `git submodule update --remote` whose fetch cannot reach
the remote. Measured, `--dry-run` exits 0 and `--apply` exits 1.

No plan can predict those without *running* the tool, and running it is the write
`--dry-run` exists not to do. So the promise `--dry-run` makes is not "the same
number"; it is **the same tree**:

> whichever of the two you ran, the checkout is untouched.

That is the property a reviewer actually needs, and it is what makes the
differing code safe — rc 1 there means the run met a failure and put everything
back, which is what rc 1 means everywhere else. `(X15)` in
[`test-renovate-exit.sh`](../linux/scripts/tests/test-renovate-exit.sh) runs both
over identical fixtures and asserts the manifests and the gitlink match
afterwards, so the class cannot quietly grow to include one where they do not.

## Lockfiles are part of the job

A manifest edited without its lockfile refreshed is half a job, and the half
that lands in a commit is the wrong one. So the lock tool is part of the
**pre-flight**: the run works out which lockfiles its edits would invalidate,
and refuses before writing a single byte if the tool that owns one is missing.

Which lock a manifest has is a question for the **tree**, never for a table.
`pep621 -> uv.lock` was hardcoded here, so a `pyproject.toml` sitting beside a
`poetry.lock` produced no lock job at all: the manifest was rewritten, the lock
left stale, and the run printed `none of the edited manifests has a lockfile` at
rc 0. So each manager below lists the locks it *can* own, and the one that
exists beside the manifest is the one that does.

| Manager | Lockfile, whichever is there | Refreshed with |
|---|---|---|
| `pep621` | `uv.lock` / `poetry.lock` / `pdm.lock` | `uv lock` / `poetry lock` / `pdm lock` |
| `cargo` | `Cargo.lock` | `cargo update -p <dep>@<declared range>` |
| `pub` | `pubspec.lock` | `dart pub get`, or `flutter pub get` when the pubspec declares `flutter` |
| `npm` | `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml` | `npm install --package-lock-only --ignore-scripts` / `yarn install --mode update-lockfile` / `pnpm install --lockfile-only` |

`pip_requirements`, `pre-commit` and `github-actions` have no lockfile, and are
applied with no tool on `PATH` at all.

### A workspace member's lock is at the root

The same bug class, on the other axis: there the *name* was resolved from a
table, here the *directory* was. `lock_target` looked only in
`dirname(<manifest>)`, and a workspace **member** has no lockfile of its own —
cargo, npm, pub and uv all keep one at the workspace root. Measured 2026-09-11 on
a cargo workspace: `crates/foo/Cargo.toml` rewritten `=1.0.100 -> =1.0.200`, the
root `Cargo.lock` byte-identical, rc **0** — and with no `cargo` on `PATH` at
all, which is the worse half. A manifest with no lock job is a manifest with no
tool to be *missing*, so the pre-flight's "a missing tool is a refusal" never
ran.

So the search goes **up** — but only to an ancestor that *declares* a workspace
of this manager's kind (`[workspace]`, `"workspaces":`, a top-level `workspace:`,
`[tool.uv.workspace]`), and to nothing else. "Walk up until some ancestor has a
lockfile" is the bug in the other direction: `app/pubspec.yaml` beside an
unrelated root `pubspec.lock` would get a lock job pointed at a file it has
nothing to do with, and `dart pub get` run in `app/` would create
`app/pubspec.lock` — collateral, from the guard next door. The declaration is
what makes an ancestor's lock this manifest's lock. Beside the manifest is still
searched **first**, so a member carrying its own lock owns it.

The tool then runs in the directory that owns the **lockfile**, not the
manifest's: `npm install --package-lock-only` in a member directory writes a
member-level lock instead of refreshing the root one, which is a second stale
lock rather than none. (K21), (K22) and (K23) hold the three directions.

**Several** lockfiles beside one manifest is a refusal, not a precedence rule —
which tool owns the project is not knowable from the tree, and picking one is
how a lock goes stale behind a green run:

```
REFUSING to apply: a manifest this run would edit sits beside SEVERAL
lockfiles, and which tool owns it is not knowable from the tree. Picking
one is how a lock goes stale behind a green run, so nothing is written:
  pyproject.toml sits beside uv.lock, poetry.lock
```

There is deliberately **no switch to tolerate a stale lock**. A missing tool is
a hard refusal with nothing written:

```
REFUSING to apply: a manifest this run would edit has a lockfile, and the
tool that owns it is missing. An edited manifest beside a stale lock is
worse than an unedited one, so nothing is written:
  Cargo.lock needs 'cargo', which is not on this PATH
```

### When the manifest already carries the new value

A report whose `currentValue` and `newValue` are the **same string** is a
**lockfile-only** update: the declared range already covers the release Renovate
found, and the lockfile is the thing that is behind. The plan writes the line to
itself, byte for byte, for one reason — an edit is what registers the lockfile
job, and the lock tool is the actual update.

The read-back audit therefore sanctions a declaration that was never expected to
move. Until 2026-09-11 it counted the no-op as "the declaration the report named
was left alone" and failed the whole run, which made `--apply` unusable in any
cargo manifest with an in-range release available — measured on OxidANT, 20 of
its 21 cargo rows were exactly this shape. `(G2)` in
[`test-renovate-local.sh`](../linux/scripts/tests/test-renovate-local.sh) pins
both halves: the manifest line stays byte-identical, and `cargo update -p <dep>`
still runs.

The lock command carries the declared range as a package-id spec —
`cargo update -p wgpu@30` — because a bare name is ambiguous the moment the
lockfile holds two versions of the crate: `cargo update -p wgpu` stops with
`specification 'wgpu' is ambiguous` once wgpu 29 and wgpu 30 are both in the
lock (measured on OxidANT). `cargo_spec` strips the requirement operators,
because a package-id spec takes a partial version and rejects `=2.12.0` with
"unexpected version requirement", and falls back to the bare name for a value
that is not a dotted number.

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

## Which git runs the apply half

The two halves can need **different gits**, and on this Windows host they do. The
report half needs node, which lives in WSL. The apply half needs the git that wrote
the working tree: a Windows checkout (`core.autocrlf=true`) read by Linux git shows
every text file as modified.

That is not cosmetic. `git submodule update --remote` over several paths is **not
atomic** — it walks them in order, and one submodule it cannot check out makes git
abort THAT checkout while the ones already done stay moved. Observed on 2026-09-09:
a run from WSL moved `third_party/IMGUI`, then failed on `third_party/NLOHMANN_JSON`,
leaving BeschleunigerBallett half updated with a non-zero exit.

So the script:

* tells a genuinely dirty tree from the wrong git with `--ignore-cr-at-eol` — if
  every difference is a CR, it is the git that is wrong, not the tree;
* switches to `git.exe` (via `wslpath -w`) when it is reachable, and says so;
* **refuses up front** when it is not, rather than applying part of the change.

The report half is safe from anywhere; it only reads.

### The nested submodule that no end-of-line option can reach

`--ignore-cr-at-eol` is only half of that separation, and until 2026-09-10 the
missing half made `--apply` refuse in **five of seven** family repos over a
difference of zero bytes.

`third_party/DocumANTation` sits two levels down inside every ContainerHub
checkout. On a Windows checkout read by Linux git every text file in it differs
by a CR, so it is always dirty — and a dirty submodule makes its parent's gitlink
read as:

```
-Subproject commit 9cdd84dcba86fd5764156a85f9fcc80a861b2fcd
+Subproject commit 9cdd84dcba86fd5764156a85f9fcc80a861b2fcd-dirty
```

The two shas are **equal**. The whole difference is the `-dirty` suffix git
appends after running its own status *inside* the submodule — a status that does
not inherit `--ignore-cr-at-eol`, which is why no end-of-line option can reach
it. Measured on all four consumer ContainerHub checkouts from WSL that day
(Linux git 2.53.0 over `/mnt/d`): identical shas every time.

`--ignore-submodules=dirty` fixes it, and it is not an ignore of anything a run
writes. Measured against a fixture (git 2.55.0) in all five directions:

| the tree | plain | with the option |
|---|---|---|
| nested submodule's worktree dirty | rc 1 | **rc 0** — the bug |
| nested gitlink at another **commit** | rc 1 | rc 1 — still seen |
| a superproject file edited | rc 1 | rc 1 — still seen |
| both at once | rc 1 | rc 1 — still seen |
| everything clean | rc 0 | rc 0 |

`dirty`, never `all`: `all` also hides a gitlink that genuinely **moved**, which
is the one thing `--apply` exists to write. Cases (H1)–(H4) in
[`test-renovate-local.sh`](../linux/scripts/tests/test-renovate-local.sh) pin
every row above, and (H3) is red against `all`.

**Both** questions in `classify_one` take the option. Given it to the first only,
the false refusal merely changes its name: the tree comes back clean, falls
through to the `elif`, and the second diff — which carries no end-of-line option
either — reads the same `-dirty` suffix as a line-ending disagreement and refuses
with "wrong git for this working tree" instead. (H1) asserts the absence of
**both** messages for that reason.

Ignoring nested dirt for the *decision* must not destroy it: (H4) runs the real
apply over a dirty nested submodule and reads the uncommitted bytes back
afterwards.

## Pins, and why Node is one of them

`RENOVATE_NODE_VERSION` and `RENOVATE_VERSION` live in
[`linux/scripts/01-core/versions.env`](../linux/scripts/01-core/versions.env),
like every other tool this repo bootstraps on demand. Both are marked
`# noforward` — no image installs them.

Node is pinned because Renovate 44 declares `"node": "^24.11.0"` and dies on
Node 22 with `TypeError: RegExp.escape is not a function`, an error that names
nothing relevant. It is deliberately **not** the canonical `NODE_VERSION`, which is
26.8.1 for the images: Renovate declares `engines.node "^24.11.0"`, major 24 only,
so one name cannot serve both. A node already on `PATH` is used only when its major
**matches** the pin rather than merely exceeding it;
otherwise the pinned tarball is downloaded once, **SHA256-verified**, and cached
per version under `~/.cache/kataglyphis` (override with `RENOVATE_LOCAL_CACHE`).
Renovate itself is installed into a user-owned npm prefix — no sudo, nothing
global.

## Scoping, and a trap worth knowing

The script now **detects** its managers: every manager whose own
`managerFilePatterns` match a file this tree tracks, printed with the file that
selected it. The patterns come from Renovate itself (probed once per Renovate
version and cached), so this is detection rather than a per-repo table, and a
manager Renovate ships **disabled** — `pre-commit`, `git-submodules` — is
enabled for the run from the global config layer, which is why every
`.pre-commit-config.yaml` in this family was invisible before.

Narrow it deliberately when you only care about one ecosystem:

```bash
scripts/linux/renovate-local.sh --managers git-submodules,github-actions .
```

Scope it because an **unscoped run is slow**. Scoped to `git-submodules` a repo
reports in about four seconds; unscoped, on OmniAccelerANT, it was still going
after fifteen minutes, because it walks every manager it can detect. Custom
managers (`custom.regex`) are never auto-detected — name them explicitly.

(An earlier version of this page said an unscoped run throws `spawn flutter ENOENT`
/ `spawn dart ENOENT` on the Flutter repos. That was never measured and is **false**:
two runs on OmniAccelerANT, at `LOG_LEVEL=warn` and `=debug`, produced zero.)

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

## Nothing else in the repo moved

[`renovate_audit.py`](../linux/scripts/renovate_audit.py) proves **exactly one
value changed in this file**. Until 2026-09-10 nothing proved **and nothing else
in the repo changed** — and an ecosystem updater touches more than the manifest
and its lockfile.

On OmniAccelerANT that day, `dart pub upgrade --major-versions` moved ONE
constraint (`permission_handler ^12.0.1 -> ^13.0.2`), 204 lines of
`pubspec.lock` with it, and **deleted three tracked files** —
`lib/l10n/app_localizations*.dart`, generated outputs whose `.arb` sources had
not changed. Committing that would have removed three translation files under a
message about `permission_handler`.

Provenance, because a number nobody re-measured is how a page goes wrong: the
constraint and the 204 lines are read off `fab1e86`, the commit that landed the
bump. The three deletions are the **owner's report**, and the commit is
consistent with it — `fab1e86` touches `pubspec.yaml` and `pubspec.lock` and
nothing else, so the deletion happened in the working tree and was caught before
it was staged. Catching it is what this guard makes automatic.

### What counts as collateral

Not a list of suspect directories. The boundary is **the rollback's own reach**:

* **EXPECTED** — everything the run took a copy of (`BACKUP_PATHS`: every
  manifest it edited and every lockfile a lock job named) plus every gitlink it
  snapshotted (`APPLY_PATHS`).
* **COLLATERAL** — every other path git reports as moved.

Tying the guard to the undo means the two cannot drift apart: a path the tool can
put back is a path it is allowed to have moved, and there is no third category to
keep in step by hand.

**Not collateral: anything `.gitignore` covers.** Those paths cannot reach a
commit — `git add -A` does not stage them — so they cannot be the accident this
guard prevents. `.dart_tool/`, `build/`, `node_modules/` and `target/` are
therefore silent, by the repo's own declaration rather than by a table in the
script. A file that is both ignored and **tracked** is still caught: git reports
a tracked path under its real status whatever `.gitignore` says.

**Silent is not the same as unmentioned.** That argument is about
*committability*, and it says nothing about the human's loss. Measured
2026-09-11: a lock tool deleted an ignored, untracked `secrets.env` with real
content in it, and the run printed that everything had been put back without
ever naming the file. So the ignored paths are listed before the run and again
after it, and any that **vanished** are named — together with the fact that
nothing here can put them back, because no copy of an ignored path is taken. It
is still not a refusal; (K18) pins that it is not silent either.

That listing is `--ignored=traditional -unormal`, which collapses an ignored
*directory* to one entry while still naming an ignored *file* individually. That
is what keeps the second walk affordable, and it is exactly the resolution the
report can honestly claim: a file deleted from **inside** an ignored directory is
not visible to it, and the run says so where it prints the list.

**Ownership is an exact match, not a substring.** `tree_owned` tested
`case " ${BACKUP_PATHS[*]} " in *" $1 "*`, a substring test over a space-joined
list, and git C-quotes a path that needs it — a plain space is enough
(` M "app one/pubspec.yaml"`). Measured 2026-09-11, both directions were wrong at
once on one fixture: the run **refused over its own manifest**, because
`"app one/pubspec.yaml"` never equals the plain path it copied aside, while the
two tracked files the tool really deleted — `app` and `one/pubspec.lock`, each a
substring of an owned path — were neither named nor put back. The comparison is
now element by element over the arrays, and git's quoting is undone before
anything is compared. (K15) and (K16) hold the two directions apart.

### The contract

Collateral is **neither silently kept nor silently reverted**:

1. Every collateral path is **named**, with what happened to it.
2. The whole run is **undone** — manifests, lockfiles and gitlinks — which is the
   rc 1 contract that already existed.
3. The run **fails**.

There is deliberately no flag to accept it. "Apply the update anyway and let the
human notice the three deleted translation files" is exactly the tolerated
failure this tree refuses.

The counter-argument, stated because it is real: a repo whose *tracked* generated
files are rewritten by its own package manager will now refuse **every** run.
That is the correct outcome where the *content* moved, and the fix is in that
repo — gitignore the generated outputs, or make them stable — not a switch here.
A tool that exposes the problem is doing its job; a tool that carries a flag past
it is not. The one case where the content did **not** move is separated below,
and separated by measurement rather than by assertion.

### A rewrite that is only line endings

OmniAccelerANT declares `flutter: generate: true` and an `l10n.yaml` with
`arb-dir: lib/l10n`, and `lib/l10n/app_localizations{,_de,_en}.dart` are
**tracked**. The `pub` lock command for a Flutter pubspec is `flutter pub get`,
which regenerates exactly those three.

Measured 2026-09-11 with the real toolchain
(`ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`) over a copy of the
repo, per file:

| | `app_localizations*.dart` | `pubspec.lock` (owned by the run) |
|---|---|---|
| `git status --porcelain` | ` M` | ` M` |
| `git diff --quiet HEAD` | 1 | 1 |
| `git diff --quiet --ignore-cr-at-eol HEAD` | **0** | 1 |
| identical once CR is removed | yes | no |

`flutter pub get` writes LF; the checkout holds CRLF. The bytes moved and the
**content** did not, and `--ignore-cr-at-eol` separates that from a real rewrite
cleanly — it says 0 for the three generated files and 1 for the lockfile the run
legitimately changed, in the same reading.

Treated as ordinary collateral, that would refuse **every** `pub` update on this
repo forever over a difference that is not one — and a guard that cries wolf on
every run is a guard somebody switches off. So such a path is:

1. **named**, under its own heading, with what happened to it;
2. **put back** from `HEAD`, so the working tree keeps the bytes it had and the
   next `git add -A` has nothing to sweep up;
3. **proven** back, exactly as any other collateral is — and if it will not go
   back the run refuses after all.

Naming it and putting it back is what makes not refusing honest; without either,
this would be a tolerated failure wearing a measurement as a costume. It is the
same reading of the same flag the pre-flight already makes about the same
question (`classify_one`, and *The nested submodule that no end-of-line option
can reach*). (K19) holds the line-ending case; (K20) holds the case where the
content moved **as well**, which still refuses.

### Putting it back, and the one case where this tool must not

A collateral path that was **clean before the run** is put back with git, because
git holds the bytes and no copy was taken: a tracked path is checked out, a file
the tool created is removed, and the result is **proven** by re-reading the same
comparison.

**From `HEAD`, never from the index.** It was `git checkout -- <path>`, which
restores from the **index**, so any tool that stages what it did defeated the
undo completely. Both shapes measured 2026-09-11:

| what the tool did | `git checkout -- <path>` | left behind |
|---|---|---|
| staged a **deletion** | exits 1, `pathspec … did not match` | file **gone**, `D  lib/gen.dart` |
| staged a **modification** | a **no-op** | the **tool's** bytes, `M  lib/gen.dart` |

and in both the run then printed that the path had been put back. `git checkout
HEAD -- <path>` rewrites the index as well as the working tree, so it unstages in
the same move (measured: status clean afterwards). A file the tool *created* and
staged is removed from the index too, or it reads `AD` — which is not "as it
started" by any reading. (K12) and (K13).

**And the proof was dead code.** `restore_collateral` re-reads the tree
afterwards and calls a path that still moved *stuck*, which is what keeps the
copies beside the run and the in-flight marker in place. Under this file's
`set -uo pipefail` that check could never fire: the set difference it ran ends
with `grep -Fxv -f`, which exits **1 when it selects no lines** — that is, when
no porcelain line *disappeared*, which is the normal case and always the case
over a tree that was clean before the run. The 1 propagated out of the pipeline,
the condition was false for every path, `TREE_STUCK` stayed empty, and the run
reported a full undo, cleared the wreckage marker and deleted the only copies of
the bytes. Deterministic, 10 runs out of 10.

The fix is that "no lines selected" is **data**, so the function that produces
the answer says so with an explicit `return 0` — not a `|| true` sprinkled at
each call site, which would have hidden a genuine `grep` failure along with it.
The one failure those greps can really have, an input they cannot read, is ruled
out first in the main shell, where a refusal is still possible: inside a pipeline
or a process substitution an `err` would end only the subshell and hand the
caller a truncated answer to read as a whole one. (K11).

A path that was **already dirty** is not touched at all. The human's own
uncommitted work is in it, this run never owned it, and `git checkout` over it
would destroy the very thing the pre-flight refuses to write over. That case is
reported under its own heading and the run still fails. It is the one state in
which "exactly as it started" is not available, and the tool says so rather than
implying otherwise.

### How a change is seen

`git status --porcelain=v1 -uall`, before and after, with the differing lines
compared in **both directions** — an untracked file a tool deletes *leaves* the
listing rather than joining it.

That is not sufficient on its own, and (K3) in
[`test-renovate-collateral.sh`](../linux/scripts/tests/test-renovate-collateral.sh)
is the case that proved it: a path that was ` M` before and is ` M` after
produces the **same porcelain line** whatever the tool did to its bytes. So the
paths that were already listed are additionally **hashed** (`git hash-object
--no-filters`) before and after. The cost of that is the size of the human's work
in progress, not of the repo.

### The same flag, two questions

**No `--ignore-submodules` in that snapshot**, and that is the opposite of what
the pre-flight does. One flag, two callers, two different
questions, and the tension is worth stating rather than resolving by copy:

| | asks | reading | needs `--ignore-submodules=dirty` |
|---|---|---|---|
| `classify_one` (pre-flight) | is the **human's** tree clean enough to write into? | absolute | **yes** — a dirty *nested* submodule makes its parent's gitlink read `<sha>-dirty` against the same sha, for a reason that is none of this run's business |
| `tree_status` (the guard) | what did the ecosystem **tool** touch? | differential | **no** — the same snapshot is taken before and after, so a nested submodule that read `-dirty` before still reads it after and cancels |

The flag had been copied from the first into the second, where it means "do not
look inside submodules". Measured 2026-09-11: a lock tool deleted a **tracked**
file and created an untracked one inside a submodule, and the whole run exited
**0** having reported nothing. Not hypothetical for this family — OmniAccelerANT's
pubspec declares `anthology: path: third_party/ANThology`, that path **is** a
submodule, and a superproject's `.gitignore` does not apply inside one.

What the guard can then do about it is limited, and it says so: a gitlink reads
` M` for anything at all inside it, and no checkout of that path reaches what
moved. So it is named as a submodule, the run is undone and **refused**, and the
path is reported under *could NOT be put back* with the copies kept — rather than
undone silently or, as before, not seen. (K14).

### What the guard does not watch

The scope was never stated, and a passing run closed with `Nothing is staged or
committed. Stage the paths you reviewed.` — which a human reading it just after
an undo message will over-read. Measured 2026-09-11: a lock tool deleted a file
in a **sibling** directory, created another there, and wrote into the home
directory, and the run said not one word about any of it.

Watching outside the checkout is not the ask; every ecosystem tool writes to
`~/.pub-cache`, `~/.cargo/registry` and `~/.npm` as a matter of course, and a
guard that refused over those would be useless. **Saying so** is the ask, so
every `--apply` that gets as far as running an ecosystem tool now prints what it
watched and what it did not, on the refusing path and the passing one alike.
(K17).

### The manifest, across the lock tools

The audit proves one value moved the moment the edit lands. The lock tools run
**after** that, in the manifest's own directory, and several of them rewrite the
manifest they are handed — `flutter pub get` normalises a pubspec, `npm install`
reorders `package.json`. Any such rewrite is covered by nothing.

So the manifest's bytes are hashed between the proof and the tools, and compared
once the tools are done. A tool that rewrote an audited manifest **undoes the
run** and says which guarantee it voided.

### What can be said about a lockfile

A lockfile is legitimately rewritten **wholesale** — one constraint bump moved 204
lines of OmniAccelerANT's `pubspec.lock`, 46 resolved versions across 48 packages
(read off `fab1e86`, the commit that landed it) — so there is no "exactly
one leaf changed" to assert, and pretending otherwise would be the more dishonest
of the two options. The claim is narrower, and it is printed rather than implied:

| | |
|---|---|
| **REFUSED** | the file is gone, or empty, or no longer parses by the real parser for its format (`tomllib` for `Cargo.lock` / `uv.lock` / `poetry.lock` / `pdm.lock`, `json` for `package-lock.json`, PyYAML for `pubspec.lock` / `pnpm-lock.yaml`) |
| **REPORTED**, never a refusal | whether the dependency this run moved is **named** in it. A missing name is usually wrong and occasionally right — an optional or platform-gated dependency need not resolve on this host — so it goes to a human instead of becoming a verdict this tool cannot justify |
| **NOT CHECKED**, and said so | that the lock **resolves** the new constraint, or is internally consistent. Only the ecosystem's own tool can say that, it already ran, and its exit code is the answer — a non-zero one has undone the run by the time this is reached |
| **NOT CHECKED**, format | `yarn.lock` v1 is a bespoke format with no stdlib parser. "There and not empty" is the whole claim, and the run prints exactly that |

That reading is taken **twice**, and the two mean different things. Before the
first byte an unreadable lockfile is the **tree's** problem and the run refuses
without writing; afterwards the same reading is the **tool's** problem and the run
is undone. Without the pre-flight the second could not tell them apart and would
have blamed this run for a file that was already broken.

## The fleet

One entry point over every repo the family has, from the top or from any one of
them: [`renovate-fleet.sh`](../linux/scripts/renovate-fleet.sh).

```bash
linux/scripts/renovate-fleet.sh                     # report every repo
linux/scripts/renovate-fleet.sh --apply --dry-run   # the whole plan, no writes
linux/scripts/renovate-fleet.sh --apply
linux/scripts/renovate-fleet.sh --only ContainerHub,OrchestrANT
linux/scripts/renovate-fleet.sh --here              # this repo only, no fleet
linux/scripts/renovate-fleet.sh --timeout 120       # a tighter per-repo budget
```

**Run it from WSL, not from Git Bash.** `renovate-local.sh` needs a python that
runs, and on this machine both `python3` and `python` on the Git Bash `PATH` are
the Microsoft Store app-execution-alias stub: measured 2026-09-11, `python3 -c
pass` exits **49** and prints *"Python wurde nicht gefunden"*, and so does
`python`. Its probe therefore fails and no fleet run is possible from Windows
unless `PREFLIGHT_PYTHON` names a real interpreter. Every measurement on this
page was taken through
`MSYS_NO_PATHCONV=1 wsl -d Ubuntu-26.04 -- bash …`.

### The fleet is found, not written down

The root is climbed to the outermost superproject, so running this from inside
`third_party/OxidANT` means the same thing as running it from the top. The
members are the directories **beside** that superproject, one level deep, that
are git checkouts whose remote has **the same owner as the root's** — read from
the root's own `origin`, never from a name list here.

One level deep, and not a recursive sweep. Measured 2026-09-11: eight checkouts
under `D:\GitHub` carry the ContainerHub identity and **none** of them is under
`_ratchet/` or `_hubgate_logs/` — but those two directories do hold **six**
throwaway checkouts (`_ratchet/scratch/gitlab/{fresh,fresh2,super,work}`,
`_ratchet/scratch/tw/BB`, `_hubgate_logs/head1`), and a recursive sweep is what
would reach them. A fleet that writes into a scratch clone is the accident this
whole file is shaped around, so the depth bound is the guard. (An earlier
version of this paragraph said "eight ContainerHub checkouts, two of them
scratch". Re-measured: eight carry the identity, none is scratch, and the eight
are the own checkout plus seven vendored — which is what the section below
already said.)

That rule is deliberately wider than "the projects you were thinking of". On
this machine it also finds `Kataglyphis` and `llvm-project`. `llvm-project` is
the owner's own **fork** (`github.com/Kataglyphis/llvm-project`), so it really is
a member by the rule above and hiding it would be a name list by another name;
it is also 180,573 tracked files, which is why the per-repo budget below exists.
The plan prints every member before anything runs, and `--skip llvm-project` (or
`--only`) narrows it. A default that quietly dropped repos would be the same
silence this whole page is about — which is also why the run now names what it
could **not** place.

Three headings say what was found and not run, so "not touched" is a statement
rather than a silence:

* **a sibling with no `origin`.** Identity here *is* `remote.origin.url`, so a
  checkout without one has no owner to compare and cannot be placed. It used to
  be dropped by a bare `|| continue` and appeared in no plan, no summary and no
  heading at all. Measured 2026-09-11 on this machine, that silently skipped a
  real directory: `_flutter-probe`, a checkout with no remotes at all. Now it is
  named, with the remotes it *does* have, and `git -C <dir> remote add origin
  <url>` is the way to bring one in. A repo whose only remote is called
  `upstream` is the same case and reads the same way.
* **a sibling belonging to somebody else**, named and not run.
* **an uninitialised submodule** — see *Order* below.

Measured over the real family, 2026-09-11 (report mode, injected report, no
network, 16s): seven members, ordered ContainerHub → Kataglyphis → llvm-project
→ BeschleunigerBallett → OmniAccelerANT → OrchestrANT → jotrockenmitlocken, with
seven vendored ContainerHub copies named and not touched, six repos of the
owner's named as having no own checkout, twenty further vendored checkouts
counted as somebody else's, and one unplaceable sibling named.

### Order

ContainerHub is pinned by everyone; a consumer bumped before the hub lands points
at a commit that does not exist yet. So a repo runs **after** every fleet repo it
vendors.

The rank is the number of distinct fleet identities the repo vendors,
transitively, and sorting on it **is** a valid topological order for one reason:
if A vendors B then A's dependency set contains B's *and* B itself, so
`|deps(A)| > |deps(B)|`, always. No topological sort, and the number it sorts on
is a fact a reader can check by eye.

**That proof assumes the walk can SEE deps(B), and an uninitialised submodule
means it cannot.** Measured 2026-09-11 against the first version: `acon` vendors
`zdep`, `zdep` vendors `hub`, and `acon`'s copy of `zdep` has `hub`
de-initialised — everything beneath the missing checkout was invisible, both
ranks came out 1, and `acon` was ordered **before** the repo it vendors. A fresh
clone that has not run `git submodule update --init --recursive` is exactly that
state, and nothing said a word about it. Two things changed:

* the walk no longer skips an uninitialised submodule. `.gitmodules` still
  carries its url, so the dependency **edge** is kept even though the subtree
  under it is not readable, and every such hole is **named** in the plan with the
  repo that declares it and the command that fills it;
* the dependency sets are closed transitively over the fleet itself. When the
  invisible submodule is a repo the fleet already has its own checkout of, its
  dependencies have already been read *there*, so unioning them in recovers the
  rank exactly. In the fixture above the order comes out hub → zdep → acon.

What is left genuinely unknowable is an uninitialised copy of a repo that has
**no** own checkout: nothing on the machine can say what it vendors. That is why
the heading says the rank is a floor rather than a fact, instead of the plan
quietly being wrong.

Equal ranks are **normal**, not a cycle — four consumers of one hub all rank 1
and have no ordering constraint between them. A real cycle is A vendoring B while
B vendors A, and that is checked for directly over the sets the walk produced
(before the closure above, which would make a three-repo cycle look like a
mutual pair it is not) and **reported**, because with a cycle there is no correct
order.

**The honest limit, which no ordering can fix:** this tool commits nothing and
pushes nothing. Inside one fleet run a consumer cannot see a hub change that has
not been pushed — the gitlink half moves to the tip of the branch on the
**remote**. The order is therefore the order to **land** the results in, and the
run prints it as exactly that.

### The same repo, checked out several times

Measured on this machine by remote identity, re-measured 2026-09-11:
ContainerHub has **eight** checkouts — its own, plus seven vendored inside the
family (one each in BeschleunigerBallett, OrchestrANT and jotrockenmitlocken;
three under OmniAccelerANT, via its own `third_party`, via OxidANT and via
AccelerANTgine; one under BeschleunigerBallett's OxidANT). DocumANTation also has
eight, OxidANT two, ANThology two. (The brief for this work said six; eight is
what the tree says.) A fleet that ran `--apply` in each would leave several
divergent working trees of **one** repository and hand a human the job of
deciding which to commit. That is how work got lost twice in one day.

So: **a repo is updated where it lives as a repository, and the pointers to it
are moved where it is vendored.** Those are two different jobs and both already
exist — the second is the gitlink half of the vendoring repo's own run. A
vendored checkout is therefore never a fleet member, and it is **named**, with
the repo that owns the pointer to it.

**"Named" is not "never written", and the heading used to claim it was.** No
Renovate update is ever *applied* inside a vendored copy — but moving the pointer
is `git submodule update --remote`, which fetches and checks the new commit out
**inside that working tree**. Measured 2026-09-11 on a fixture that drives the
real gitlink path: the vendored hub went `31a4445 → 256c4c6` and a new tracked
file appeared in it. The heading now says that, because a promise this tool does
not keep is worse than no promise.

#### Two OWN checkouts of one repository

A second clone beside the first, a `git worktree`, a `ContainerHub-2` kept for a
bisect: all three carry the same `origin`, so all three used to be **members**,
and `--apply` wrote the same update into every one of them. Measured 2026-09-11
on a fixture: `hub` and `hub2` with one identity both appeared in the run order,
both had `pubspec.yaml` rewritten, both rows said rc 0, and `hub2` was named
nowhere — not even under the heading above, which is about *vendored* copies.
That is precisely the accident the design exists to prevent.

The fleet cannot know which of the two a human pushes from, and guessing is how
work gets lost. So it **refuses**, by name, before anything is written, and the
human answers with `--only` or `--skip <directory name>`. The check runs over the
*selected* set, so `--skip hub2` really does settle it and the run goes ahead.

A repo of the owner's with **no own checkout** — DocumANTation, awesome-beamer,
smile, OxidANT, ANThology and AccelerANTgine, **six** of them on this machine
(an earlier draft said four; six is what the tool prints and what a re-run on
2026-09-11 measured) — gets its own heading: the fleet moves the pointers to it
and does not update it, and says to clone it beside the others to bring it in.
Somebody else's upstreams (glm, imgui, fuzztest, …) are pointer targets and
nothing else, so they are counted rather than listed: twenty of them, measured
2026-09-11 over 56 vendored rows in all, 36 of which are the owner's.

### Stopping it

**Ctrl-C stops the fleet.** That is a fix, not a description: until 2026-09-11
`renovate-fleet.sh` had no `INT`/`TERM`/`HUP`/`PIPE` trap at all, and the one
trap it did have was `EXIT`. Measured on a six-repo fixture, SIGINT sent to the
process **group** while repo 1 was mid-apply: the repo did the right thing, but
the fleet then **applied the five remaining repositories** and exited on their
composed rc. Nothing anywhere said "you interrupted this and I carried on".
Writing to somebody's repositories after they have said stop is the worst thing
this tool can do.

What happens now:

* the signal reaches the whole group, which is what a terminal's Ctrl-C sends —
  so `renovate-local.sh` gets it too and rolls its own tree back;
* bash defers the fleet's handler until the child it is waiting on returns, so
  the rollback finishes *first* and is never cut in half by the fleet exiting;
* **no repo after that one is started.** The summary lists what was already
  written, then names every repo that was **not run**;
* the exit code is the signal's: **130** for SIGINT, 129 SIGHUP, 141 SIGPIPE,
  143 SIGTERM. It is not folded into the 0/1/2 contract, because "you stopped
  this" is a different answer from "a repo was broken";
* a repo that exits 129/130/143 on its own stops the fleet too, even when this
  shell was not signalled — somebody killing the child is still a stop request.

One trap for the suite that tests this, worth knowing anywhere else: a
background command in a **non-interactive** shell has SIGINT set to `SIG_IGN`,
an ignored disposition survives `exec`, and a shell cannot trap a signal that was
ignored on entry. A test that launches the fleet with `cmd &` and no `set -m`
therefore proves nothing — it passes against a fixed tool and a broken one alike
(measured: `setsid` → rc 0 and "FINISHED WITHOUT INTERRUPT"; `set -m` → rc 130
and the trap firing).

### One repo failing does not stop the others

Each repo runs in its own invocation and its rc is recorded. The summary is one
row per repo — **which repo, which phase, what exit code, and what that code
means for that phase** — because a report writes nothing and "every reported
update is at its new value" would be a claim about an apply that never happened.

Two phases have their own rcs: `preflight`, which the fleet itself runs, and then
`report` / `plan` / `apply`, which is `renovate-local.sh`'s own contract.
Preflight refuses a repo when:

* git will not name a git dir there;
* an earlier `--apply` left its in-flight wreckage marker;
* **a merge, cherry-pick, revert, rebase or bisect is still in progress.** HEAD
  is on a branch and the git dir is nameable, so nothing else catches it — and
  measured 2026-09-11 the fleet applied straight into a conflicted merge
  (`MERGE_HEAD` present, `UU README.md`, HEAD on `main`), rc 0, merge still in
  progress afterwards. The next `git commit -a` finishes *that* merge and carries
  the renovate edit into it, under the merge's own message, where nobody will
  look for it. Each state is named with the command that ends it;
* **HEAD is detached** — this tool leaves you to commit, and a commit made on a
  detached HEAD is the work that gets lost. This is checked **last**, on purpose:
  a rebase also detaches HEAD, and `git switch <branch>` in the middle of a
  rebase is actively wrong advice.

### A repo cannot hold the fleet: `--timeout`

Every repo runs under a wall clock, **600s by default**, and `--timeout <s>`
changes it. A repo that runs out of time is TERMed (with 30s to put its tree back
before the KILL), its row says it ran past the budget, and **the fleet goes on to
the next one**.

Why it exists: measured 2026-09-11, one
`git status --porcelain --ignore-submodules=dirty` over `llvm-project` did not
finish in **300s** from WSL across the `/mnt/d` mount — the same command takes
**1s** natively in Git Bash on `D:`. So the cost is the mount, not the repo, and
that is exactly the point: a fleet cannot know in advance which repo on which
path will be slow, and before this a run that reached one could not be stopped
from the keyboard either.

`timeout --foreground` is load-bearing rather than decoration: without it,
`timeout` puts the child in a **new process group**, and the Ctrl-C that signals
*this* group would never reach `renovate-local.sh` — the repo would keep writing
while the fleet was trying to stop. And a budget nothing can enforce is not a
budget, so a run with `--timeout` above zero and no `timeout` on `PATH` is
**refused**, naming `--timeout 0` as the thing a human can type to accept that
one repo may hold the run for ever.

The fleet's own exit code composes the per-repo ones: **1 beats 2 beats 0**.
"Something is broken" is a different answer from "something needs a human", and
any rc outside the contract at all — a crash, a budget kill — is the first, never
the second. An interrupt overrides all of them with 128 + the signal.

`--dry-run` prints the whole plan, passes `--dry-run` down to every repo, and
writes nothing anywhere.

## The source of truth has to be visible too

`RUFF_VERSION` in
[`versions.env`](../linux/scripts/01-core/versions.env) is the family's one pin
for ruff. It carried **no `# renovate:` annotation**, so Renovate could not see
it — while the consumer copies that are *required to match it* were perfectly
visible. Renovate reported `ruff ==0.16.4 -> ==0.16.6` against OrchestrANT's
`pyproject.toml` and said nothing at all about the key that pin has to equal.

Four more keys had the same shape, found by asking which values are declared both
here and in a file one of Renovate's own managers already reads:

| key | the consumer copy Renovate already saw |
|---|---|
| `RUFF_VERSION` | OrchestrANT `pyproject.toml` `"ruff==0.16.4"`, and its `.pre-commit-config.yaml` `rev:` |
| `ONNXRUNTIME_GENAI_VERSION` | OrchestrANT `"onnxruntime-genai==0.15.2"` — whose own comment says "keep in sync with ContainerHub ONNXRUNTIME_GENAI_VERSION" |
| `ONNXRUNTIME_VERSION` | the version that pin resolves, named in the same file |
| `PYTORCH_VERSION` | OrchestrANT `"torch==2.13.0"` and `torch @ git+…@v2.13.0` |
| `TORCHVISION_VERSION` | OrchestrANT `"torchvision==0.28.0"` |

Every datasource was checked against the upstream's real tag shape
(`git ls-remote`, 2026-09-10) before it was written: `pypi` for `RUFF_VERSION`,
whose value is the bare `0.16.4` that PyPI and the consumer's `ruff==` pin both
use, and `github-tags` for the four whose value is a `v`-prefixed tag carried
verbatim. A datasource returning a differently *shaped* string is worse than no
annotation: it reports an "update" that is not the same kind of value.

[`test-renovate-annotations.sh`](../linux/scripts/tests/test-renovate-annotations.sh)
holds the shipped files to it: every `# renovate:` line in `versions.env` must be
**matched** by the customManager regex in `.github/renovate.json`. An annotation
the regex does not match — a stray blank line, a second comment between it and
its key, a datasource carrying a character outside its class — is the same
silence, and nothing checked for it before.

### What was NOT annotated, and why

**90 further keys** have a known upstream (`bump_versions.py` names it, in
`SPECS` or `REPORT`) and no annotation. They are not the same finding and they
were not annotated blind. Each needs the right datasource, depName and often an
`extractVersion`, and a wrong one produces a confident wrong answer on the
dependency dashboard — `SQLITE3_WASM_VERSION` is the worked example: it is
genuinely the RUFF shape (the consumers pin `sqlite3: ^3.3.1` in a `pubspec.yaml`
Renovate reads), but `simolus3/sqlite3.dart` tags releases as
`sqlite3_web_js-0.2.5`, so neither `github-tags` nor a guessed prefix is right and
the correct annotation was not established. It is recorded here rather than
guessed at.

## Where the moving parts live

| Thing | Path |
|---|---|
| The script | [`linux/scripts/renovate-local.sh`](../linux/scripts/renovate-local.sh) |
| The fleet: every repo the family has, in an order it can be landed in | [`linux/scripts/renovate-fleet.sh`](../linux/scripts/renovate-fleet.sh) |
| Which git owns the tree, whether it is clean, and what ELSE moved | [`linux/scripts/renovate-tree.sh`](../linux/scripts/renovate-tree.sh) |
| The lockfile half: which lock, whose tool, the copies and the undo | [`linux/scripts/renovate-locks.sh`](../linux/scripts/renovate-locks.sh) |
| Report parsing, packageRules, the plan and the write | [`linux/scripts/renovate_planner.py`](../linux/scripts/renovate_planner.py) |
| Which line declares a dependency | [`linux/scripts/renovate_locator.py`](../linux/scripts/renovate_locator.py) |
| What the file MEANS, before and after the edit | [`linux/scripts/renovate_audit.py`](../linux/scripts/renovate_audit.py) |
| The world the suites run in | [`linux/scripts/tests/renovate-fixtures.sh`](../linux/scripts/tests/renovate-fixtures.sh) |
| The suite that holds every refusal to its word | [`linux/scripts/tests/test-renovate-local.sh`](../linux/scripts/tests/test-renovate-local.sh) |
| What an ecosystem tool did BESIDE the manifest | [`linux/scripts/tests/test-renovate-collateral.sh`](../linux/scripts/tests/test-renovate-collateral.sh) |
| The fleet: order, duplicates, and one repo failing | [`linux/scripts/tests/test-renovate-fleet.sh`](../linux/scripts/tests/test-renovate-fleet.sh) |
| Every `# renovate:` line is matched by the regex that reads it | [`linux/scripts/tests/test-renovate-annotations.sh`](../linux/scripts/tests/test-renovate-annotations.sh) |
| The suite that lets the locator be wrong and checks the result | [`linux/scripts/tests/test-renovate-audit.sh`](../linux/scripts/tests/test-renovate-audit.sh) |
| The suite for how a run ENDS: exit codes and signals | [`linux/scripts/tests/test-renovate-exit.sh`](../linux/scripts/tests/test-renovate-exit.sh) |
| Version pins | [`linux/scripts/01-core/versions.env`](../linux/scripts/01-core/versions.env) |
| Shared Renovate preset | [`default.json`](../default.json) |
| This repo's own config | [`.github/renovate.json`](../.github/renovate.json) |

The suite runs Renovate not at all: it injects a measured report through
`RENOVATE_LOCAL_REPORT` and a resolved config through `RENOVATE_LOCAL_CONFIG`,
which is also how a human re-runs `--apply` over a report they already have.
Lock tools are proved two ways — `uv lock` for real against a copy of
OrchestrANT's own `pyproject.toml` and `uv.lock` (278 packages resolved,
`ruff v0.16.4 -> v0.16.5`, 42 lines of `uv.lock` rewritten), and the rest by
stub binaries that record the argv they were handed.
