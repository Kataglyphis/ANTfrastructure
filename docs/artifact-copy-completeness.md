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

## Scope: the COPY boundary only

The gate audits the `COPY --from=artifact-source` mechanism, because that is
where Flutter and ArmNN were dropped. Some components reach the runtime image by
**other** paths and are deliberately NOT in the manifest:

* `cmake` — inherited from `${BASE_IMAGE}` (installed in `Dockerfile.base`).
* `/opt/python` and the `/opt/venv` runtime venv — built in the `package` stage
  by `setup-package-image.sh` (`install_staged_target_python`,
  `create_runtime_venv`), not copied from artifact-source.

A pre-rebuild audit on 2026-09-03 listed every `/opt/*` in the media image and
cross-checked it against the manifest: the only artifact-source component missing
was Flutter (now fixed). The build-only trees (`*-cross`, `*-native-*`,
`llvm-cross`, `wheels`, `cross-bin`) are correctly absent. So for components that
ship via a NON-COPY mechanism, the runtime smoke is the backstop — the static
gate cannot see them, by design.

## Bootstrapping Flutter in the package stage

Being COPY'd is not enough for Flutter. The upstream tarball is the framework
checkout only: `bin/cache` is empty, and the first `flutter` invocation
downloads the Dart SDK for `uname -m` and compiles the `flutter_tools`
snapshot into it — both arch-specific. Three facts shape where that has to
happen:

* **The sdk stage runs on the amd64 host for every arch.** Anything `flutter`
  cached there would be the x86-64 Dart SDK, stamped as current
  (`engine-dart-sdk.stamp`) and therefore never replaced on arm64. Both images
  shipped on 2026-09-03 carried a 716 MB SDK with an EMPTY cache precisely
  because the sdk stage's best-effort `flutter --version` had been failing
  (git "dubious ownership": the tar's files are uid 1000, the build runs as
  root) behind a WARNING — the one time a masked failure was the lucky
  outcome. `setup-flutter.sh` now ships the checkout bare on purpose, and the
  `Dockerfile.sdk` cache-restore path strips `bin/cache` as well.
* **Only the target-arch `package` stage can bootstrap.** `setup-package-image.sh`
  `bootstrap_flutter_sdk` registers `/opt/flutter` as a git `safe.directory`,
  runs `flutter --suppress-analytics --version`, fails the stage with
  flutter's own output if that fails, prints the version line, and
  `assert_elf_arch`s `bin/cache/dart-sdk/bin/dart` against
  `dpkg --print-architecture`. Under QEMU on arm64 this costs about 3 minutes
  (measured 2026-09-03: Dart SDK download + snapshot compile); amd64 ~30 s;
  riscv64 has no `flutter` and the function is a no-op.
* **The runtime user must own the tree.** `Dockerfile.torch` runs the image as
  `kataglyphis` (uid 1001) and `flutter` writes into `$FLUTTER_ROOT/bin/cache`
  on every call (lockfile, stamps). With a root-owned SDK the runtime user got
  `engine.stamp.tmp: Permission denied`. So `Dockerfile.package` COPYs
  `/opt/flutter` with `--chown=${RUNTIME_UID}:${RUNTIME_UID}` (a global
  `ARG RUNTIME_UID=1001`, free at copy time — a later `chown -R` would copy
  the 716 MB into a new layer) and the bootstrap hands the cache it wrote as
  root to the same uid.

## The end-to-end backstop

`smoke-runtime-image.sh` `check_flutter` runs against the shipped image **as
the image user, with `--network none`**: on amd64/arm64 `flutter --version`
must report `FLUTTER_VERSION` from `versions.env`, and the cached
`dart-sdk/bin/dart` must have the target arch's ELF machine (an x86-64 dart in
the arm64 image would execute natively on this host and pass a run-only
check); on riscv64 flutter must be honestly absent. The static gate proves the
COPY is wired; the smoke proves the result actually runs in the image,
offline. Both are needed — the gate cannot execute the binary, and the smoke
needs a built image.

## Guards

* `tests/test-artifact-copy-completeness.sh` — fixtures for both failure
  directions plus regression guards that the real manifest and Dockerfile agree.
* `tests/test-setup-package-image.sh` — `bootstrap_flutter_sdk` off-target: the
  no-op, the hard failure with flutter's output, the arch check and the cache
  handover.
* `tests/test-runtime-image-gates.sh` — `check_flutter` against recorded image
  output: offline, the permission-denied shape, a pin mismatch, a builder-arch
  Dart SDK, and the correct shape.
* Mutations `artifact-copy.completeness-check`, `flutter.bootstrap-hard-fail`,
  `flutter.bootstrap-cache-handover`, `flutter.smoke-offline`,
  `flutter.smoke-dart-arch`.
