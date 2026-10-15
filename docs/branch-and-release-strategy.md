# Branches, CI rounds and releases

**Owner rule for every repository of the family (2026-10-15).** It replaces the
2026-09-24 rule that every platform lane runs on every push. Which repository
follows it today: [`ci-build-triggers.md`](ci-build-triggers.md).

## The rule

1. **`develop` is the default branch.** All work is committed there.
2. **Every push to `develop` runs the Linux x64 lane** (`linux-x64.yml`: the lint
   gates, the build, the tests, the docs), and so does every pull request. No other
   platform lane starts on its own. Path-filtered helpers such as
   `submodule-pins.yml` keep their filters.
3. **Every other lane runs on request.** Linux arm64, Windows x64 and arm64,
   Android, web and whatever else a repository builds run when a commit message
   asks for them with `[ci <lane>]`, or when someone starts them by hand.
4. **`main` is the release branch.** It moves only by a fast-forward to a
   `develop` commit whose **full round**, every lane, is green.
5. **Every push to `main` makes a release, and only when every lane is green.**
   `release.yml` runs all lanes once more on that commit and publishes
   `v<version>` only if every one of them passes.

## Asking for a lane in a commit message

Write `[ci <word>]` anywhere in the message. A lane's name is its workflow file name
without `.yml`, and a lane `<os>-<arch>` answers to each part of its name:

| Token | Runs |
| --- | --- |
| `[ci all]` | every lane: the full round |
| `[ci windows]` | `windows-x64` and `windows-arm64` |
| `[ci arm64]` | `linux-arm64` and `windows-arm64` |
| `[ci windows-arm64]` | that lane alone |
| `[ci android]`, `[ci web]` | that lane |
| `[ci windows android]` | several words in one token: both Windows lanes and Android |

```text
fix(plugin): link order on arm64 [ci arm64]
feat(windows): DirectML by default [ci windows]
chore(release): 2.1.0+3 [ci all]
```

- **Every commit of a push counts**, not only the newest: a token in the second of
  five commits still runs its lanes.
- Case does not matter. `[ci-windows]` or `(ci windows)` is not a token.
- A word that names no lane is a warning in the run's log, not an error.
- `[skip ci]` is GitHub's own and still skips every workflow, Linux x64 included.

The `on-request.yml` workflow reads the tokens through the hub's
[`requested-lanes`](../.github/actions/README.md#requested-lanes) action and calls
each lane it picks. A push without any `[ci ` in its messages costs nothing: the
reading job is skipped, so no runner starts.

## Running a lane by hand

Every lane workflow has `workflow_dispatch`. In the browser: *Actions* → the workflow →
*Run workflow*, with a branch. From a terminal:

```bash
gh workflow run windows-x64.yml --ref develop                       # one lane
gh workflow run on-request.yml --ref develop -f lanes="windows web" # several
gh workflow run on-request.yml --ref develop -f lanes=all           # the full round
```

`--ref` takes any branch, so a pull request's branch can be tried on Windows the
same way. The run uses that branch's newest commit at the moment it starts.

## Merging into `main`

Only the owner moves `main`; an agent prepares the merge and stops there.

1. **Prepare the release on `develop`.** Raise the version in the repository's
   manifest and turn the CHANGELOG's `## Unreleased` into `## <version> — <date>`,
   with a new empty `## Unreleased` above it. Put `[ci all]` in that commit's message.
2. **Wait for the full round on that commit.** Every run must be green, and the
   `on-request.yml` run must have run every lane rather than skipped one:

   ```bash
   sha=$(git rev-parse develop)
   gh run list --commit "$sha" --json name,conclusion --jq '.[] | "\(.conclusion) \(.name)"'
   gh run view <on-request run id> --json jobs --jq '.jobs[] | "\(.conclusion) \(.name)"'
   ```

   `skipped` is not `success` here: [`github-cli-pipeline-monitoring.md`](github-cli-pipeline-monitoring.md).
3. **Fast-forward `main` to exactly that commit.**

   ```bash
   git push origin "$sha":main
   ```

   git refuses this when it is not a fast-forward. Then `main` holds a commit `develop`
   lacks: merge `main` into `develop` first and start again at step 2.

## The release

A push to `main` starts `release.yml`:

1. **Version check, about a minute.** The version must have a CHANGELOG section and
   no release yet; otherwise the run stops here. Every merge into `main` is a release,
   so every merge carries a new version.
2. **Every lane**, called as reusable workflows in this one run.
3. **The release job**, which `needs:` every lane. It runs only when all of them
   succeeded. It tags the commit `v<version>` and publishes the GitHub release with the
   packages the lanes built in this run, a `SHA256SUMS`, and the version's CHANGELOG
   section as notes.

A red lane means no tag and no release. A flaky failure is rerun with `gh run rerun
<id> --failed`, and the release job follows once the rerun is green. A real failure is
fixed on `develop` and merged again.

## How a repository implements it

| File | Triggers |
| --- | --- |
| `linux-x64.yml` | `push` to `develop`, `pull_request`, `workflow_dispatch`, `workflow_call` |
| every other lane (`linux-arm64.yml`, `windows-x64.yml`, …) | `workflow_dispatch` and `workflow_call` only |
| `on-request.yml` | `push` to `develop` and `workflow_dispatch` (input `lanes`): one job reads the tokens, one job per lane calls it |
| `release.yml` | `push` to `main` and `workflow_dispatch`: the version check (on `main` only, so a dispatch elsewhere releases nothing), one job per lane, the release job |

A calling job looks the same in both:

```yaml
  windows-x64:
    needs: request
    if: contains(needs.request.outputs.lanes, ' windows-x64 ')
    # The union of what the lane's own jobs ask for; less fails the run at start.
    permissions:
      contents: read
      security-events: write
    uses: ./.github/workflows/windows-x64.yml
    secrets: inherit
```

- **Permissions.** A called workflow's jobs get at most what the calling job grants.
  Grant less than a lane's job declares and GitHub rejects the whole run before any
  job starts: *The nested job '…' is requesting '…', but is only allowed '…'*.
- **Concurrency.** Each lane keeps its own `group: <lane>-${{ github.ref }}` with
  `cancel-in-progress: true`, so a newer request for the same lane on the same branch
  replaces an older one. A skipped calling job never starts the lane, so an ordinary
  push never cancels a round someone asked for.
- **The group is the lane's literal name, never `${{ github.workflow }}`.** Inside a
  called workflow `github.workflow` is the caller's name, so every lane
  `on-request.yml` calls would share one group and cancel or queue behind each other.
  OxidANT's lanes used it until they moved (2026-10-15).
- **Artifacts.** `release.yml` holds every lane's uploads in one run, so artifact
  names must differ across lanes.
- **Pushes, not tags, start a release.** The tag is the release job's output. Nothing
  listens for `push: tags`.
- OmniAccelerANT is the reference: its `on-request.yml`, `release.yml` and
  `scripts/linux/publish-release.sh`.

## Why this shape

- **Linux x64 on every push, the rest on request.** Every push used to start every
  lane, the Windows ones near an hour each, and the newest push cancelled the round
  in flight. On 2026-10-12 that cancelled 77 of OmniAccelerANT's 142 push runs. The
  Linux x64 lane catches most breakage, and the platform lanes run when a change is
  about them or a release is near.
- **One `on-request.yml`, not an `if:` in every lane.** A lane triggered on every push
  with its jobs skipped still enters its concurrency group, and its empty run cancels
  the requested round in flight. A skipped calling job starts nothing. The token
  parsing lives in one tested script instead of a copied expression in every lane.
- **The release round runs again on `main`.** The packages are then built from the
  tagged commit in the same run, and "all green" holds by construction (`needs:`).
  The price is one more full round per release, on runners that are free for public
  repositories.
- **No branch ruleset with required checks.** GitHub counts a job skipped by its `if:`
  as passed for a required check, so a commit whose full round nobody asked for would
  pass it.
- **The release workflow does not move `main` itself.** `GITHUB_TOKEN` cannot be given
  the `workflows` permission, and GitHub refuses its pushes that bring in changes under
  `.github/workflows/`, which nearly every release has.
