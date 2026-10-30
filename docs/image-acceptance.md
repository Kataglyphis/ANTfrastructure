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

The default plan tests `linux/amd64`. The existing multi-architecture image gates still
own the other architectures; this receipt does not claim new consumer coverage there.
The scripts run consumer code, without executing GitHub's workflow/action runners, so
the receipt identifies the pinned scripts actually used. It is a local release
artifact, not a signed attestation or proof of physical camera/GPU behavior.

`tests/test-image-acceptance.sh` exercises incomplete, failed and mismatched receipts,
timeouts, exact index promotion and replay lock validation. Its registry calls are
doubles; the suite performs no publication. `tests/test-manifest-acceptance.sh` checks
the actual manifest path refuses promotion after a failed consumer gate.
`tests/test-image-consumer-bootstrap.sh` executes the plan's Flutter commands against
the existing prologue/check drivers, checking Git registration and every package's
dependency preparation without downloading an SDK or starting browser/native builds.
