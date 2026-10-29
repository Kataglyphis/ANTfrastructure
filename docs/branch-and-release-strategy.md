# Branches, CI rounds and releases

**Owner rule for every repository of the family (2026-10-15).** It replaces the
2026-09-24 rule that every platform lane runs on every push. Which repository follows it
today: [`ci-build-triggers.md`](ci-build-triggers.md).

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
5. **Every push to `main` makes a release, if every lane is green.** `release.yml`
   runs all lanes once more on that commit and publishes `v<version>` only if all pass.

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
- **A token anywhere in the message counts, prose included.** A body that says "the earlier
  `[ci all]` round was green" asks for every lane: OmniAccelerANT's 3cb1674 started all five
  that way when it meant only `[ci web]`. To mention a token, leave out its brackets.
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

`--ref` takes any branch, so a pull request's branch can be tried on Windows the same way; the
run uses that branch's newest commit at the moment it starts.

## Merging into `main`

Only the owner moves `main`. An agent prepares the merge and stops there, unless the owner
tells it in that turn to push; it then checks step 2 itself and pushes exactly that commit
(OmniAccelerANT's 2.1.0, 2026-10-15).

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
3. **The release job**, which `needs:` every lane, so it runs only when all of them
   succeeded. It tags the commit `v<version>` and publishes the GitHub release with the
   packages the lanes built in this run, a `SHA256SUMS`, and the version's CHANGELOG
   section as notes.

**Checking a download:** put `SHA256SUMS` beside the files you took from the release and run
`sha256sum --check --ignore-missing SHA256SUMS`.

A red lane means no tag and no release. A flaky failure is rerun with `gh run rerun
<id> --failed`, and the release job follows once the rerun is green. A real failure is
fixed on `develop` and merged again.

Both the version check and the release job run the hub's
`linux/scripts/06-packaging/publish-github-release.sh`: `--version-file` names `pubspec.yaml`,
`Cargo.toml`, a `CMakeLists.txt` (its first `project()` call's literal `VERSION`) or a
`VERSION.txt` (read by `version_util.sh --file-version`, which never falls back to a branch name),
`--changelog` the file whose `## <version>` or `## [<version>]` section becomes the notes, `--name`
the release title, then `--check` or `--assets <dir>`. It refuses a version that is released
already, a version without a section, notes over GitHub's 125000 characters, a GitHub that does
not answer and an empty directory (`test-publish-github-release.sh`, 34 assertions).

### Before a repository's first release

The five consumers that followed OmniAccelerANT on 2026-10-16 met three traps:

1. **The version file can lag the CHANGELOG.** WebDavClient's `VERSION.txt` said 0.0.1 while its
   CHANGELOG already recorded 0.9.0, so its first release would have gone backwards: pick a version
   above every one the CHANGELOG names, and keep the version in one file (its docs read it).
2. **A version may be released already** under an older scheme (OrchestrANT's v0.0.30, a pushed
   tag): `--check` refuses it, so raise it first.
3. **The `[Unreleased]` entries become the version's section** (`## [<version>] - <date>`, a new
   empty `[Unreleased]` above it); `--check` then says `v<version> is not released yet and has its
   CHANGELOG section`.

Then a dry run on `develop` (`gh workflow run release.yml --ref develop -f dry-run=true`; the input
is `dry-run`, not `dry_run`) runs every lane and lists the release's files, and the owner's
fast-forward of `main` releases that commit.

## Collecting the release files

`linux/scripts/06-packaging/collect-release-assets.sh [options] <artifacts dir> <out dir>` turns the
run's uploads, one folder each as `actions/download-artifact` writes them, into one flat directory of
release files. It fails when two files would get one name, when it collects nothing, and on an
`--expect` the release would lack. `download-artifact` extracts a lone upload without its folder, so
`release-publish.yml` passes `--lone-upload` when `artifacts` names one upload literally; files outside
any upload fail without it rather than drop out of the release. An upload named `*-docs-site` or `docs-site-*` is always skipped:
`build-docs.yml` uploads the site in the same run.

| Option | Does |
| --- | --- |
| `--skip UPLOAD_GLOB` | an upload that is no deliverable |
| `--include PATH_GLOB` | collect a file whose `<upload>/<path>` matches |
| `--exclude PATH_GLOB` | never collect such a file (`*/bundle/*`) |
| `--only-from PATH_GLOB=UPLOAD_GLOB` | a file every lane builds alike ships from these uploads only |
| `--rename PATH_GLOB=NAME` | collect such a file as `NAME` |
| `--flatpak-arch-from-suffix` | `--rename '*.flatpak={stem}-{machine}.flatpak'`: the packagers name a flatpak without its arch |
| `--zip UPLOAD_GLOB[/DIR]=NAME` | the upload's folder, or its `DIR`, as one zip; a matching upload without `DIR` fails |
| `--unpack UPLOAD_GLOB` | collect from the contents of the upload's tarballs |
| `--expect NAME` | the release must carry `NAME` |
| `--strict` | an upload neither skipped nor collected from fails |
| `--lone-upload NAME` | the artifacts directory is the one upload `NAME`, unless it holds a `NAME` folder |
| `--version V`, `--options FILE` | the value of `{version}`; more options, one per line |

Globs are `case` patterns, so `*` crosses `/`. A `NAME` takes `{version}`, `{stem}` (the file's name
without its last extension), `{arch}` (the last `x64`, `arm64` or `riscv64` word of the upload's
name) and `{machine}` (`x86_64`, `aarch64`, `riscv64`). An options file holds its globs unquoted; a
quoted one fails, since it would match nothing. `tests/test-collect-release-assets.sh` runs the
script over each consumer's uploads with that consumer's options, the `<repo>.options` blocks there.

## The reusable release workflow

`.github/workflows/release-publish.yml` is the version check and the release job of every
`release.yml`, called twice: `stage: check` before the lanes, `stage: publish` in a job that
`needs:` all of them. The publish stage downloads the run's uploads (`artifacts`, a download-artifact
pattern, empty for all), collects them with the options in `collect`, and tags `v<version>` through
`publish-github-release.sh`, from `main` only. With `dry-run` it checks and collects, lists the files
in the run summary and tags nothing. The scripts come from the hub's `develop`, like the workflow.

```yaml
jobs:
  # A minute, so a merge without a new version stops before the lanes; elsewhere only a dry run runs.
  version:
    if: github.ref == 'refs/heads/main' || inputs.dry-run
    # The grant covers the publish job of the same file; the check job itself takes contents: read.
    permissions:
      contents: write
    uses: Kataglyphis/ANTfrastructure/.github/workflows/release-publish.yml@develop
    with:
      stage: check
      name: OxidANT
      version-file: Cargo.toml
      dry-run: ${{ inputs.dry-run == true }}

  # linux-x64, windows-x64, ...: the lane jobs, each with needs: version, as before.

  # needs: every lane, so one red or cancelled lane means no tag and no release.
  release:
    needs: [linux-x64, linux-arm64, linux-riscv64, windows-x64, windows-arm64-cross]
    permissions:
      contents: write
    uses: Kataglyphis/ANTfrastructure/.github/workflows/release-publish.yml@develop
    with:
      stage: publish
      name: OxidANT
      version-file: Cargo.toml
      dry-run: ${{ inputs.dry-run == true }}
      collect: |
        --skip *-tests
        --include *.deb
        --flatpak-arch-from-suffix
```

- **Both calls grant `contents: write`.** GitHub checks every job of a called workflow against the
  calling job's grant before any job runs, and the file's publish job asks for write.
- **`dry-run: ${{ inputs.dry-run == true }}`**, not `${{ inputs.dry-run }}`: a push has no inputs,
  and the comparison hands the boolean input a boolean.
- **Moving a repository onto it:** replace its `version:` and `release:` jobs with the two calls, keep
  `on:`, `permissions: {}`, `concurrency:` and the lane jobs, delete
  `scripts/linux/collect-release-assets.sh` and its suite, and prove it with a dry run on `develop`.

## How a repository implements it

| File | Triggers |
| --- | --- |
| `linux-x64.yml` | `push` to `develop`, `pull_request`, `workflow_dispatch`, `workflow_call` |
| every other lane (`linux-arm64.yml`, `windows-x64.yml`, …) | `workflow_dispatch` and `workflow_call` only |
| `on-request.yml` | `push` to `develop` and `workflow_dispatch` (input `lanes`): one job reads the tokens, one job per lane calls it |
| `release.yml` | `push` to `main` and `workflow_dispatch`: the version check (on `main` only, so a dispatch elsewhere releases nothing), one job per lane, the release job; both calls of [`release-publish.yml`](#the-reusable-release-workflow) |

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
- **Concurrency: `group: <lane>-${{ github.ref }}-${{ github.workflow }}`** with
  `cancel-in-progress: true`. Inside a called workflow `github.workflow` is the caller's
  name, so a standalone run, `on-request.yml`'s call and `release.yml`'s call each get a
  group of their own, and a newer run from the same caller on the same branch replaces an
  older one. A skipped calling job never starts the lane, so an ordinary push cancels no
  round someone asked for.
  - **Not the lane name alone.** `linux-x64-${{ github.ref }}` is the group every push to
    `develop` starts the lane in, and a dry run of `release.yml` on `develop` calls the lane
    in it too, so each cancels the other: OmniAccelerANT's first dry run, dispatched a
    minute after a push, cancelled that push's Linux x64 run (047876d, 2026-10-16).
  - **Not `${{ github.workflow }}` alone.** Every lane `on-request.yml` calls would share
    one group and cancel or queue behind each other; OxidANT's lanes did until they moved
    (2026-10-15).
- **Hub exception.** ANTfrastructure's own `linux-x64.yml` does not use this consumer
  caller pattern. It keeps `group: linux-x64-${{ github.ref }}` and evaluates
  `cancel-in-progress: ${{ github.ref != 'refs/heads/develop' }}`. Consecutive
  `develop` pushes leave the active preflight and mutation shards running, with the
  latest pending run following them; PR and `main` runs still cancel stale active
  runs. A dispatch on `develop` shares the same group. See
  [Hub CI triggers](ci-build-triggers.md#this-repositorys-lanes).
- **A dry run.** OmniAccelerANT's `release.yml` takes a `dry-run` input: dispatched on
  `develop` it publishes nothing ([first release](#before-a-repositorys-first-release)) and is
  the full round before a merge as well.
- **Artifacts.** `release.yml` holds every lane's uploads in one run, so artifact
  names must differ across lanes.
- **Pushes, not tags, start a release.** The tag is the release job's output. Nothing
  listens for `push: tags`.
- OmniAccelerANT's `on-request.yml` is the reference. A `release.yml` not yet on
  `release-publish.yml` fetches only the hub submodule (`git submodule update --init --depth 1
  third_party/ANTfrastructure`), not the others, to run the scripts.

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
