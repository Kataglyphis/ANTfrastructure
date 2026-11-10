<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Consumer acceptance before an image tag moves

`build-runtime-manifest.sh --push` publishes `candidate-<run-id>` after the existing
environment, ancestry, completeness and wrapper-generation gates. It resolves that index
to a SHA-256 reference, runs the declared consumer checks, and promotes those exact index
bytes to the requested tag only when every consumer passes. `:latest` and workflow
`@develop` remain the family's public entry points.

`--gates-only` runs the existing wrapper and runtime gates, then exits without building,
creating a candidate, running consumer acceptance or promoting a tag. It takes precedence
over publication flags in either order; publishing later still requires full acceptance.

The plan is [`shared/config/image-consumers.json`](../shared/config/image-consumers.json).
It declares the Linux test platform, timeout, repository branch and argument array for
each check: C++/GStreamer inference, Rust tests, ANThology, both Flutter apps and WebDAV.
Consumers run serially, in disposable containers, against the same immutable digest.
The C++ check uses the existing GCC lane; Clang fuzzing and TSan stay in its normal CI,
whose TSan runtime needs privileged container settings. Rust's test step fetches its
model and starts Xvfb for the required GPU/GTK checks. Flutter checks prepare the existing
lane environment first, register the mounted Git checkout, and resolve package dependencies.
The app checks use their own helpers to include ANThology or the native plugin package.
These Flutter checks use the VM; browser, native build and packaging lanes stay in CI.
Their own recorded submodules supply their tools; ANThology uses the receipt's hub
checkout because that library has no hub submodule. Linux containers run as UID 0 so
the SDK and mounted checkout are writable; rootful runs restore the host's checkout
ownership during cleanup. Rootless runs follow the documented uid/tar policy in
[linux-build-basics.md](linux-build-basics.md#a-lane-under-a-rootless-engine-on-a-linux-host-runs-as-root).
Ownership restoration still runs if removing the consumer container times out.
A container-removal or ownership-restoration error keeps the receipt failed.
After each removal attempt, a checked engine query must show the exact name absent. A nonzero
removal result is harmless only when that successful query proves automatic removal already
completed. Partial name matches do not count as the removed container. The same check covers
the temporary ownership container. Both raw statuses and stdout/stderr are appended to the
consumer log before its receipt hash is computed. This proves the engine's reported state;
it does not independently prove host-process reaping.

The receipt lands at `logs/image-acceptance/<run-id>/receipt.json`, beside consumer logs.
It records the image digest, platform, clean hub SHA, exact plan hash, consumer SHAs,
recursive submodule status, model/asset lock hashes, resolved Cargo/pub/uv locks and
their contents, exit statuses, log hashes, pull time and check durations. Timeouts keep
a failed receipt with exit status 124 and remove the named test container. A failure
stops the gate before promotion; a failed candidate remains available for diagnosis.

## Check an existing immutable image

Commit the hub tooling first. Each new workspace clones the consumer refs once; an
existing workspace must still have clean sources and their recorded submodules.
Commands must leave tracked files and submodules unchanged; generated build output
and new dependency locks may live in ignored paths. A command that exits successfully
but changes tracked sources still produces a failed receipt with those changes recorded.

```bash
image=ghcr.io/kataglyphis/kataglyphis_beschleuniger@sha256:<index-digest>
python3 linux/scripts/image-acceptance.py check --image "$image" \
  --workspace out/acceptance/manual/consumers --receipt out/acceptance/manual/receipt.json
```

The engine defaults to `NERDCTL_BIN` or `nerdctl`; `--engine` accepts another compatible
executable. Logs contain the actual consumer output. A passed check removes the consumer
checkouts under `--workspace` (28 GB a run on 2026-10-29) and keeps the logs beside the receipt;
a failed check leaves them for inspection, and a replay re-clones them. A passed receipt is
required for:

```bash
python3 linux/scripts/image-acceptance.py promote \
  --receipt out/acceptance/manual/receipt.json \
  --target ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

Promotion uses `GHCR_TOKEN` and `GITHUB_ACTOR`, or the existing Docker GHCR login and
credential helper. Credentials never become command arguments. The target must be in
the source repository. The registry PUT sends the tested raw multi-platform index;
the resulting tag is read back and must match its digest. Before the PUT, promotion
checks that the index contains the tested platform, has no duplicate runtime platforms
and preserves every platform currently published at the target tag. Explicit BuildKit
attestations bound to an included runtime manifest are excluded from platform counts.
Only a registry HTTP 404 permits creating an absent tag; authentication and network
failures stop promotion.

## Native CI proofs

[`linux-arm64-image-acceptance.yml`](../.github/workflows/linux-arm64-image-acceptance.yml)
runs the complete contract on `ubuntu-26.04-arm`. Apply `native-image-proof` to a
same-repository pull request that changes this lane, its driver or its proof configuration.
After the workflow is on the default branch, `workflow_dispatch` runs that branch's
versioned configuration too. The workflow has read-only repository permissions and
publishes evidence; tag promotion remains the separate receipt-gated command above.

[`shared/config/native-image-proof.json`](../shared/config/native-image-proof.json) pins
the immutable image index, a full hub commit, the test platform and every consumer's
revision, recursive submodule state and data-lock hashes. The driver rejects a different
host architecture before preparation, checks out the exact clean tooling separately and
uses that tooling's full plan with only `platform` changed. It verifies the source bindings
and checks that the generated commands and timeout are unchanged before consumer work.
The normal host prologue retains its disk admission and cleanup policy.

The native runner must still execute all six consumers successfully. Unit fixtures and
mutation controls exercise input, receipt and cleanup refusal; they do not prove real ARM
execution, model inference or a working container image. The failed qemu-user attempt
below remains failed until a compatible execution environment supplies a new passed receipt.

Each attempt's `native-image-proof-candidate-<run>-<attempt>` artifact preserves the
original receipt, platform plan, actual consumer logs and `native-job.json` with host/source bindings, log hashes and a checked final engine query.
The metadata includes artifact-relative log paths without rewriting paths in the original
receipt. Review both the receipt and job verdict, verify downloaded log hashes and inspect
real tests before promotion. Neither an outer green step nor metadata replaces the receipt.
A failed engine query or a reported remaining container keeps the native job failed.

## Preserve a platform-specific plan

The default consumer plan selects `linux/amd64`. Generate a retained plan for another supported
Linux platform without rewriting the consumer list, arguments, branches or timeouts:

```bash
python3 linux/scripts/image-acceptance.py plan --platform linux/arm64 \
  --output logs/image-acceptance/plans/linux-arm64.json
python3 linux/scripts/image-acceptance.py check --image "$image" \
  --plan logs/image-acceptance/plans/linux-arm64.json \
  --workspace out/acceptance/arm64/consumers --receipt logs/image-acceptance/arm64/receipt.json
```

`plan` accepts an optional `--plan` source and validates it before changing only `platform`.
It refuses unsupported targets and existing output files. Preserve the generated plan with its
receipt and supply it again for replay. Generating a plan executes no consumer and proves no
platform support; only an actual successful check produces that platform's acceptance evidence.

## Repeat an older acceptance run

Check out the receipt's `hub_revision`, keep that revision's plan, and use a fresh
workspace. Supply the original digest and receipt:

```bash
python3 linux/scripts/image-acceptance.py check --image "$image" \
  --replay /path/to/original-receipt.json \
  --workspace out/acceptance/replay/consumers --receipt out/acceptance/replay/receipt.json
```

Replay fetches the recorded consumer SHAs, verifies their recursive pins and data
locks, restores the recorded dependency locks and rejects changed resolution. The
lock payload and its hash preserve the original UTF-8 bytes, including CRLF line endings.
The source commits, registry layers and dependency archives must still be available.
Commit and publish dependency branches before consumers pin new shared code; a local
commit alone cannot be fetched by a fresh acceptance run.

## Evidence and limits

The plugin-only ROCm proof run `20261109-081137-973f29cc` completed on 2026-11-09 from hub
`7f97f31c122241a6eea8ba62229bbbc56c00444c`. Its amd64 wrapper is
`sha256:e9fc824e6129670a06a4e81980676e4d7a1effb3013726f844cd12d5d097c55f`; the accepted index is
`sha256:4e76aa2a75e104570794be965034bcc3276bb5ba78c98ab863659ed6630ca8de`, now at `:latest-rocm`.
All six default consumers passed on `linux/amd64`, recorded in
`logs/image-acceptance/20261109-081137-973f29cc/receipt.json`; the recorded log hashes were
independently matched and a post-run engine query found no container under this run's exact
name prefix. This run used the earlier helper, before the checked-removal fix described above.
No fresh hardware inference, NVIDIA wrapper or ARM64 consumer receipt is inferred from it.

NVIDIA run `20261110-013045-b0a6f8cb` from hub
`9f4e6bd2c0d416057224c585d5a34b7abbdb813d` published candidate index
`sha256:d2df9e170fadc7f2abbc22e004b615a7f8a4f41ee9c810c4f06ad7229ecace70`.
Its independently matched remote wrapper children are:

| Platform | Wrapper manifest |
|---|---|
| `linux/amd64` | `sha256:3b9cf1c6a211d5b6b9e317da4081e3510b963fd1fb94cd33326716b307b73268` |
| `linux/arm64` | `sha256:33b92fa2e4e1f926fbdbd09e446ed4449f51b41376daf9ad2cf815c036565af7` |

All six amd64 consumers passed, with the receipt at
`logs/image-acceptance/20261110-013045-b0a6f8cb/receipt.json`.
An independent audit matched its log and lock hashes, checked cleanup records and remote
index children, then found every exact test container name absent. The unchanged ARM attempt
on this same immutable index compiled its first consumer, then failed GoogleTest discovery
with LeakSanitizer's QEMU fatal error at 2026-11-10T05:58Z. The failed receipt is
`logs/image-acceptance/20261110-013045-b0a6f8cb-arm64/receipt.json`; no consumer tests ran.
A compatible ARM execution host and a passed ARM receipt are still required before public
`:latest-nvidia` promotion; [diagnosis](failure-modes.md#arm64-ctest-discovery-ends-with-leaksanitizer-has-encountered-a-fatal-error).
These image and consumer checks establish no
physical NVIDIA inference. Raw proof, full stdout and actual test summaries are retained in
`logs/test-results/plugin-proof-nvidia-runtime-9f4e6bd2/`.

The default plan tests `linux/amd64`. The existing multi-architecture image gates still
own the other architectures; this receipt does not claim new consumer coverage there.
The scripts run consumer code, without executing GitHub's workflow/action runners, so
the receipt identifies the pinned scripts actually used. It is a local release
artifact, not a signed attestation or proof of physical camera/GPU behavior.

`tests/test-image-acceptance.sh` exercises incomplete, failed and mismatched receipts,
timeouts, exact index promotion and replay lock validation. Its registry calls are
doubles; the suite performs no publication.
The cleanup cases also cover ordinary nonzero removal, zero exit with a remaining container,
failed queries, exact names and both ownership/removal failures; eleven mutations prove them.
`tests/test-manifest-acceptance.sh` checks
the actual manifest path refuses promotion after a failed consumer gate.
`tests/test-image-consumer-bootstrap.sh` executes the plan's Flutter commands against
the existing prologue/check drivers, checking Git registration and every package's
dependency preparation without downloading an SDK or starting browser/native builds.
