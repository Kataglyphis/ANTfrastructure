<!-- Why a built artifact can vanish between the build stage and the shipped image, and the gate that prevents it. -->

# Artifact-copy completeness

## The failure class

The cross chain builds heavy components (ONNX Runtime, OpenCV, FFmpeg, GStreamer,
Flutter, the toolchains, …) in `Dockerfile.sdk` / `.media` / `.android`, each
hard-checked in place — e.g. `test -x /opt/flutter/bin/flutter`. The final
runtime image is a **fresh** stage: `Dockerfile.package`'s `package-image` is
`FROM ${BASE_IMAGE}`, not `FROM` the build stages. Every artifact must therefore
be carried across that `FROM` boundary by an explicit
`COPY --link --from=artifact-source <path> <path>`.

Nothing used to assert that carry happened. So an artifact could be built,
verified, and then silently **dropped at the boundary** because no one added its
COPY line. This has happened at least three times:

* **Flutter** (2026-09-03) — built and `test -x`'d in `Dockerfile.sdk`, absent
  from `:latest-cross`. The user reported it missing.
* **ArmNN / ACL** (F7, 2026-09-01) — cross-compiled and verified on every arm64
  chain, reaching no image, until the COPY was added.

The `test -x` in the build stage does not catch it: that stage genuinely has the
file. The runtime image is a different stage that simply never received it.

## The gate

`verify-artifact-copy-parity.sh` (preflight slug `artifact-parity`) has two
halves:

1. **Consistency** — every `COPY --from=artifact-source` has `src == dst`, unless
   the pair is a documented relocation (`ALLOWED_RELOCATIONS`). This half only
   sees paths that ARE copied.
2. **Completeness** — the set of copied paths must equal
   `linux/scripts/runtime-artifacts.manifest`. A manifest path that is not copied
   fails (the drop bug); a copied path with no manifest line fails (a stray or
   renamed artifact). This is the half that would have caught Flutter.

The manifest lists each artifact-source path that must reach the runtime image,
in the **symbolic** form used in the COPY line (a `${VAR}` is compared as text),
with a one-line reason.

## Adding a component that ships in the runtime image

1. Build and hard-check it in the sdk/media/android stage.
2. Add `COPY --link --from=artifact-source <path> <path>` to the `package-image`
   stage of `Dockerfile.package`.
3. Add `<path> | <reason>` to `runtime-artifacts.manifest`.

Miss step 2 or 3 and `artifact-parity` fails before the build ever runs. If the
component is deliberately build-only (never shipped), simply do not add it to the
manifest and do not COPY it — the gate stays quiet.

## Per-arch empty artifacts

Some components exist on only some arches (Flutter and ArmNN/ACL are not built on
riscv64). The build stage creates an **empty** dir on the other arches
(`mkdir -p /opt/flutter`), so the single unconditional COPY is safe everywhere —
it copies an empty dir where the component is absent. The runtime smoke then
asserts the honest per-arch truth (see below).

## The end-to-end backstop

`smoke-runtime-image.sh` `check_flutter` runs against the shipped image: on
amd64/arm64 `flutter --version` must report a version; on riscv64 flutter must be
honestly absent. The static gate proves the COPY is wired; the smoke proves the
result actually runs in the image. Both are needed — the gate cannot execute the
binary, and the smoke needs a built image.

## Guards

* `tests/test-artifact-copy-completeness.sh` — fixtures for both failure
  directions plus regression guards that the real manifest and Dockerfile agree.
* Mutation `artifact-copy.completeness-check` — disabling the completeness call
  turns the suite red.
