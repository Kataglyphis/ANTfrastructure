# Publishing over FTP

Every project in this family publishes something over FTP — a docs tree, a
built web app, or both — and every one of them reached
`SamKirkland/FTP-Deploy-Action` directly to do it. That produced eleven deploy
steps across eight workflows, written with three different pin spellings, five
different ways of making the built files readable, and two different answers to
the only question that matters when an upload fails: *does this red the lane?*

[`../.github/actions/deploy-over-ftp/action.yml`](../.github/actions/deploy-over-ftp/action.yml)
is the one answer. It owns the pin, owns the permission fixup, and answers that
question the same way every time: **a failed publish fails the job.** That is
not an input, and the section on it below says why it is not.

## The eleven call sites this replaces

Measured 2026-09-09 across the five top-level repos plus the three owned
submodules (`AccelerANTgine`, `OxidANT`, `ANThology`). Vendored
`third_party/ContainerHub` copies are the same two hub workflows and are not
counted twice. Line numbers are the committed ones; the step is the stable
handle.

| Repo | Step | Pin | On upload failure | Readability fixup |
|---|---|---|---|---|
| ContainerHub | `python-ci-linux.yml:201` | SHA `110f9186` (v4.4.0) | fails the lane | host `chmod -R 755` + `ls -la` |
| ContainerHub | `build-docs.yml:106` | SHA `110f9186` (v4.4.0) | fails the lane | host `chmod -R 755` + `ls -la` |
| jotrockenmitlocken | `dart.yml:157` (main site) | tag `v4.4.0` | fails the lane | none |
| jotrockenmitlocken | `dart.yml:166` (dev wasm site) | tag `v4.4.0` | fails the lane | none |
| jotrockenmitlocken | `dart.yml:182` (dev site) | tag `v4.4.0` | fails the lane | none |
| jotrockenmitlocken | `dart.yml:196` (doc site) | tag `v4.4.0` | fails the lane | none |
| BeschleunigerBallett | `Linux.yml:545` | tag `v4.4.0` | `continue-on-error: true` | none |
| OmniAccelerANT | `dart_on_native_linux.yml:210` | tag `v4.4.0` | fails the lane | `chown` inside the docs build, guarded by `CI=true` |
| OxidANT | `rust_ubuntu26_04.yml:272` | tag `v4.4.0` | `continue-on-error: true` | host `sudo chown -R "$USER:$USER"` |
| ANThology | `dart.yml:63` | tag `v4.3.6` | fails the lane | host `sudo chown -R` + `sudo chmod -R 755` |
| AccelerANTgine | `linux_run.yml:139` | tag `v4.3.6` | fails the lane | host `chmod -R 755` guarded by `-d` |

Eleven steps, seven repositories — and an eighth that publishes without owning
one of these lines: `OrchestrANT` calls the hub's `python-ci-linux.yml`, whose
`deploy-docs` input defaults to `true`, so the hub's own row is its row too.

Three facts fall out of that table.

**The pin is not one pin.** Three spellings, two commits. Two sites carry the
digest of v4.4.0; seven carry the mutable tag `v4.4.0`, which resolved to that
same commit `110f9186c050f71550953127052e77650219c287` when the API was asked on
2026-09-09; two carry `v4.3.6`, which is a different commit (`a51268f6`). So
**nine of the eleven have no digest**, and the tag under seven of them can be
moved without producing a diff anywhere in this family.

None of those nine is outside a promise it never made: all seven repositories
holding these sites extend the shared preset
(`"extends": ["github>Kataglyphis/ContainerHub"]`), and `default.json` extends
`helpers:pinGitHubActionDigests` — exactly the rule that would replace those
tags with digests. The reason it has not is the one recorded in every one of
those `renovate.json` files: the Renovate app is not installed on these
repositories, so the config is inert. Until it is, this action's single
digest-pinned `uses:` is the only thing actually holding a pin for a consumer
that adopts it.

**The failure policy is a habit, not a decision.** There are two policies across
the eleven sites, not three: nine fail the lane, and two
(`BeschleunigerBallett`, `OxidANT`) carry `continue-on-error: true`. Nothing in
the nine says the question was ever asked; both of the two carry a written
reason, and both reasons apply just as well to the nine. That symmetry is the
argument for deciding it once, centrally — and the decision this action makes is
not the tolerant one.

**The permission fixup is copied, not shared.** Six sites carry one and five
carry none, and the six are five *distinct* implementations: no two repos wrote
it the same way, except the hub's own two workflows. Three of the eleven —
`python-ci-linux.yml`, `build-docs.yml` and `AccelerANTgine`'s `linux_run.yml` —
only `chmod`, and a `chmod` alone cannot do what those steps are for. See the
next section.

## What the action does

Three steps, in this order.

**1. Preflight the upload tree.** Validates every input, normalises `local-dir`
and `server-dir`, repairs access to the tree and then *proves* it. Anything
wrong here fails the job: a misconfiguration is not a flaky upload, and there is
no switch that changes that.

**2. The upload**, `SamKirkland/FTP-Deploy-Action` pinned by digest — one
`uses:` line for the whole family. It carries `continue-on-error: true`
unconditionally, and that is not tolerance: it exists so the step below can turn
a raw non-zero exit into an annotation that names the cause. The upload step
decides nothing on its own.

**3. Re-raise a failed publish.** Reads the upload's outcome: `success` passes;
`failure` and `cancelled` exit 1 with an error annotation; and any *other*
value — including the empty string — also exits 1, reported as this step's own
defect rather than the upload's. That last branch exists because `outcome` is
the one link in the chain that cannot be tested off a runner (see the
verification section), and reporting a green publish as a failed one would be
the worse of the two ways to be wrong.

The preflight closes three failure modes the raw call sites carry. All three
were read off the pinned code — action `v4.4.0` at digest `110f9186`, whose
`package.json` depends on `@samkirkland/ftp-deploy` `^1.2.5`, bundled into
`dist/index.js`.

*An empty tree deletes the live site.* `deploy()` diffs the local tree against
the server's `.ftp-deploy-sync-state.json` and puts everything missing locally
into `diffs.delete`. A docs build that silently produced nothing therefore does
not "publish nothing" — it unpublishes the site. The preflight refuses to sync a
tree with no files, and it counts the way the *upload* will count rather than
the way `find` would:

- `**/.git*`, `**/.git*/**` and `**/node_modules/**` are discounted, because
  those are the library's `excludeDefaults` and this action passes no `exclude`
  of its own. A tree holding only `node_modules/` — or only a `.gitignore` —
  looks non-empty to `find` and completely empty to the library, which is
  precisely the unpublish this guard exists to stop.
- the sync-state file is discounted *on top of* that, and this part is **not**
  mirroring the excludes: the library does upload its state file. It filters it
  out of the normal upload batch and then uploads it by name at the end. A
  leftover state file is simply not content, so a tree holding nothing else is
  still an empty publish.

*`chmod -R 755` does not make a root-written tree publishable.* The library
writes its state file **into** `local-dir` before it connects
(`createLocalState`, called before the `ftp.Client` is even constructed). A tree
the container wrote as root at mode 755 is readable by the runner and writable
by nobody but root, so the upload fails after the connection is open — and the
three sites that only `chmod` cannot fix that. Where passwordless `sudo` exists
the preflight takes ownership first, which is what `OxidANT` and `ANThology` do
by hand; where it does not, the two probes that follow decide. The mixed case —
a runner-owned directory holding root-owned files — is caught by those probes
rather than by an ownership test on the top directory, which reports that tree
as fine.

*A `local-dir` without a trailing slash is a hard error.* `getDefaultSettings`
throws `local-dir should be a folder (must end with /)`, and throws the matching
`server-dir` message for the same reason. Both checks sit at the top of
`getDefaultSettings`, which the library entry point calls before it builds a
client, so at this digest **neither of them is a post-connection failure** —
both are an immediate throw whose message names the input but not the caller.
The hub's `python-ci-linux.yml` passes its `docs-artifact-path` input straight
through, and that input is a consumer-supplied string. The preflight normalises
both values to exactly one trailing slash instead, stripping *every* trailing
slash before adding one, so `site//` becomes `site/` rather than surviving into
`site//.ftp-deploy-sync-state.json`.

## Why a failed upload cannot be tolerated

There is no `best-effort` input, no `continue-on-error` a caller can reach, and
no annotation level below `::error::`. The verdict step is named "Re-raise a
failed publish", and every path through it that is not `success` exits 1.

That is a policy call, not an oversight, and the reasoning is short. The action
cannot tell a dropped control socket from an expired password, because the
upload exits the same way for both. A tolerated failure therefore does not
tolerate flakiness — it tolerates *any* reason the publish stopped working, and
a lane that has stopped publishing while staying green is the exact defect this
action was written to make visible. A warning that repeats every night is not
weather; it is a site nobody has read the annotation for.

| | outcome |
|---|---|
| Upload succeeded | step passes |
| Upload failed or was cancelled | `::error::`, job fails |
| Upload outcome unreadable | `::error::`, job fails, named as this action's own defect |
| Bad input (`protocol`, `port`, `dry-run`, `log-level`, `timeout`) | job fails, before connecting |
| `local-dir` missing, empty, multi-line, unreadable, unwritable, or nothing but slashes | job fails, before connecting |
| `local-dir` holds no publishable files | job fails, before connecting |

**What the two `continue-on-error` sites should do instead.** Both wrote the
same reason: the build, the tests and the packaging all passed before the docs
push, so a flaky upload must not red the lane.

- *Read the job result, not the run result.* A failed publish step already
  leaves the build and test steps green and individually reported. Nothing is
  lost by letting the run go red except the impression that it was fine.
- *Re-measure the flakiness before naming it.* The preflight turns the most
  common "flaky FTP" — an unwritable tree, an empty docs build, a missing
  trailing slash — into a named failure that happens before a socket is opened.
  Adopt the action first; if uploads still fail after that, the failure is now
  specific enough to fix, and `timeout` and `protocol` are inputs.
- *Gate the publish, do not silence it.* If the docs push genuinely should not
  run on a given branch or event, that belongs in the step's `if:` — which is
  what `build-docs.yml` already does with `github.event_name == 'push'`. An
  `if:` that skips is honest; a `continue-on-error` that hides is not.
- *Prove a new call site with `dry-run: 'true'`.* It reports the file count and
  the permission verdict without touching the server.

A call site that still passes `best-effort:` is not silently ignored. Because
the input does not exist, `linux/scripts/lint-workflows.sh` fails on it and
actionlint names the ten inputs that do.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `server`, `username`, `password` | yes | — | Passed to the upload step's `with:` only. They never reach a `run:` block, so they are never on a command line. |
| `local-dir` | yes | — | Required deliberately: the library's default is `./`, which would publish the whole checkout. Normalised to exactly one trailing slash; a value that is nothing but slashes is refused rather than resolved to `/`. |
| `server-dir` | no | `''` | Empty means the library default (`./`). A non-empty value gets the same trailing-slash normalisation as `local-dir`, and is refused if it is nothing but slashes. |
| `protocol`, `port`, `dry-run`, `log-level`, `timeout` | no | `''` | Pass-throughs, each validated in the preflight so a typo names itself instead of surfacing as a connection error. Empty is not "set to nothing": the upstream action declares no defaults, and its parser maps an empty string to `undefined`, which is what makes the library apply its own (`ftp`, `21`, `false`, `standard`, `30000`). |

`exclude`, `state-name`, `security` and `dangerous-clean-slate` are deliberately
**not** exposed. No call site needs them, and `exclude` in particular is a trap:
a value passed there *replaces* the library's defaults
(`**/.git*`, `**/.git*/**`, `**/node_modules/**`), so the obvious use — "also
skip this one folder" — quietly starts publishing `.git` to the web server.
Adding it later is three lines, plus a repeat of those defaults here, plus a
matching change to the preflight's empty-tree count, which mirrors that set.

Outputs: `outcome` (`success`/`failure` of the upload itself — only ever
readable as `failure` from a step with `if: always()`, because the action fails
the job on that value) and `file-count` (publishable files found before the
sync, counted with the excludes above).

## Adopting it in a workflow

Before, with the fixup step it needs:

```yaml
      - name: Fix permissions for the built docs
        run: |
          chmod -R 755 ./docs/_build/html/
          ls -la ./docs/_build/html/

      - name: 📂 Sync files to domain
        uses: SamKirkland/FTP-Deploy-Action@110f9186c050f71550953127052e77650219c287 # v4.4.0
        with:
          server: ${{ secrets.SERVER }}
          username: ${{ secrets.USERNAME }}
          password: ${{ secrets.PW }}
          local-dir: "./docs/_build/html/"
```

After — the fixup, the pin and the policy all move inside:

```yaml
      - name: 📂 Sync files to domain
        uses: Kataglyphis/ContainerHub/.github/actions/deploy-over-ftp@main
        with:
          server: ${{ secrets.SERVER }}
          username: ${{ secrets.USERNAME }}
          password: ${{ secrets.PW }}
          local-dir: ./docs/_build/html/
```

Keep the `if:` guards where they are — they are per-lane policy, not deploy
policy. `build-docs.yml`'s `github.event_name == 'push'` guard is what stops a
pull request publishing to production, and this action deliberately does not
second-guess it.

## What this change does not do

Nothing calls the action yet. The eleven sites above are untouched on purpose:
adopting it is a per-repo change, and for the two lanes that currently tolerate
a failed upload it is also a per-repo policy change — neither belongs in the
commit that creates the thing. The two hub workflows (`python-ci-linux.yml`,
`build-docs.yml`) are the natural first adopters, since they already sit at the
right pin.

Note for whoever does adopt it in `python-ci-linux.yml`: that workflow's
`chmod -R 755` step becomes redundant, and its `docs-artifact-path` input no
longer has to end in a slash.

One gap to close with, or before, the first adoption:
`.github/workflows/actions-selftest.yml` `uses:` eleven of the twelve actions in
`.github/actions/`, and `deploy-over-ftp` is the one it does not. That self-test
is what makes actionlint hold every action's declared inputs and outputs on
every push, so until this action appears there, renaming one of its inputs
breaks a consumer rather than the hub. Its runtime half needs a real server and
is not the part that matters here; a statically linted call site is.

## How this was verified

Everything below was re-run on 2026-09-09 against this tree. Nothing in this
section is carried over from an earlier revision.

- **43 scenarios, all green.** A harness parses `action.yml` with `PyYAML`,
  pulls both `run:` blocks out of the parsed document, and executes them the way
  the runner invokes a composite bash step
  (`bash --noprofile --norc -e -o pipefail <file>`), with the step's own `env:`
  block supplying the inputs. Covered: the happy path and its `file-count`;
  trailing-slash normalisation of `local-dir` and `server-dir` (absent, single,
  multiple); a missing tree; a file passed as `local-dir`; an empty tree; a tree
  holding only a stale state file; a tree holding only `node_modules/`; a tree
  holding only `.gitignore` and `.git/`; `node_modules/` not inflating the count
  of a real tree; empty, multi-line and all-slashes `local-dir` and `server-dir`;
  every accepted value and one rejected value of `protocol`, `log-level`,
  `dry-run`, `port` and `timeout`; and all five outcomes the verdict step can
  see (`success`, `failure`, `cancelled`, empty, unknown).
- **Ownership cases against real ext4 fixtures**, built by a root helper and then
  run as the unprivileged user: a root-owned mode-755 tree fails with
  `upload tree is not writable`; a runner-owned directory holding a root-owned
  mode-640 file fails with `upload tree is not readable` and names the file; the
  same at mode 644 passes, because the upload needs no more than that; and a
  `sudo` that exists and answers `-n true` but elevates nothing fails loudly
  with `chown`'s own message rather than continuing.
- **The upstream claims were read off the pinned bundle**, downloaded at digest
  `110f9186`: `excludeDefaults = ["**/.git*", "**/.git*/**",
  "**/node_modules/**"]` and its use as the fallback when no `exclude` is
  passed; `createLocalState` called before the client is constructed; both
  "should be a folder (must end with /)" throws sitting at the top of
  `getDefaultSettings`, which the entry point calls first; the state file being
  filtered out of the upload batch and then uploaded by name; and the default
  table (`./`, `./`, `ftp`, `21`, `false`, `standard`, `30000`, `loose`). The
  tag-to-digest resolutions in the table above came from the GitHub API the same
  day.
- **`linux/scripts/lint-workflows.sh` — `actionlint 1.7.12` and
  `shellcheck 0.11.0`, both at the pins in `linux/scripts/01-core/versions.env`
  — reports `WORKFLOW LINT OK` for this repository with the action in the tree.**
  Run again against a throwaway repo whose only workflow `uses:` the action:
  also `WORKFLOW LINT OK`. Run a third time against that same fixture with
  `best-effort: 'true'` added to the call: `WORKFLOW LINT FAILED`, with
  actionlint reporting `input "best-effort" is not defined` and listing the ten
  that are. That is what proves it resolved the composite rather than skipping
  it — and that a call site left on the old input cannot pass the gate.
- **`shellcheck 0.11.0` directly over both extracted `run:` blocks**: clean.

Not verified here, and named rather than implied:

- No FTP server was contacted. Every upload-side claim in this file is read off
  the pinned bundle or exercised through the preflight, never through a
  connection.
- The `sudo` *success* path — passwordless sudo present and actually elevating —
  was not exercised, because the machine this ran on has no passwordless sudo.
  Only its failing and absent branches were.
- `steps.<id>.outcome` for a `continue-on-error` step *inside* a composite
  action cannot be produced off a runner. The verdict step's handling of every
  value was tested by setting the variable directly; what the runner actually
  puts there was not. That is the whole reason the step treats an unrecognised
  value as its own defect instead of as a failed publish.
- `actionlint` has no schema for action metadata files, so linting `action.yml`
  directly only reports that it is not a workflow. A composite action is graded
  by linting a workflow that calls it — which is what the fixture runs above do,
  and what `actions-selftest.yml` does not yet do for this action.
