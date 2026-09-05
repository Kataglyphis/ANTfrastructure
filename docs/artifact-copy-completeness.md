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
* **The runtime user must own the tree — all of it.** `Dockerfile.torch` runs the
  image as `kataglyphis` (uid 1001) and `flutter` writes into `$FLUTTER_ROOT`
  on every call. With a root-owned SDK the runtime user got
  `engine.stamp.tmp: Permission denied`. So `Dockerfile.package` COPYs
  `/opt/flutter` with `--chown=${RUNTIME_UID}:${RUNTIME_UID}` (a global
  `ARG RUNTIME_UID=1001`, free at copy time — a later `chown -R` would copy
  the 716 MB into a new layer) and the bootstrap hands over what root wrote.

  Handing over `bin/cache` alone was not enough, and the 2026-09-04 image proved
  it: `flutter --version` ALSO runs `git fetch` and a `dart pub get` for the
  flutter_tools snapshot, so 37 further paths — the fetched pack, `FETCH_HEAD`,
  `refs/remotes`, `logs/refs`, and `packages/flutter_tools/.dart_tool` — were left
  root-owned. The last three broke `flutter pub get` for every consumer with
  `package_config.json (OS Error: Permission denied)`, and that one is
  unfixable from outside: the directory sits in a read-only overlay layer, so a
  non-owner can neither chown, empty nor rename it. The handover is therefore
  `hand_root_created_paths_to_runtime_user /opt/flutter` — the same
  `find ! -user … -exec chown -h` the rust trees go through, with one owner rather
  than two copies — in the SAME RUN
  that created those paths: it selects only what root owns, which is exactly what
  this layer already carries (`bin/cache` 687 MB + 8.3 MB of git/`.dart_tool`
  measured on the shipped amd64 image), so the metadata rewrite copies nothing up.
  A `chown -R /opt/flutter` would instead copy the COPY `--chown`'d ~700 MB of
  framework checkout into the RUN layer on every arch. `-h` so a symlink is
  retargeted rather than its target.

  Running the bootstrap AS uid 1001 instead — nothing created as root, no handover
  at all — was considered and rejected: `flutter --version` downloads the Dart SDK
  and runs `pub get`, so it needs a `$HOME` and `PUB_CACHE` for that uid inside a
  root `RUN` (`setpriv`/`su` plus env), and `git config --system` is root-only. It
  would trade a measured, zero-byte `find` for a change nothing here can validate
  without a full chain. The `find` also covers whatever a FUTURE root command in
  this stage leaves behind, which running one command as the user would not.

### The runtime uid is a contract

`Dockerfile.package` chowns `/opt/flutter` to `ARG RUNTIME_UID` at COPY time,
but the user that reads it is created much later, in `Dockerfile.torch`'s
`useradd`. Those two numbers are in different files and nothing joined them:
`useradd` without `-u` takes the first free uid, which is 1001 only as long as
the base image happens to have no other non-system user. A base that gains one
would move `kataglyphis` to 1002 and hand Flutter's `bin/cache` to a uid that
does not exist — the same `Permission denied` the chown exists to prevent,
reappearing from an unrelated change.

`Dockerfile.torch` therefore declares its own `ARG RUNTIME_UID=1001`, passes it
to `useradd -u`, and asserts `id -u kataglyphis` afterwards, so a base image
that already owns that uid fails the build instead of shipping a mismatch.
Both defaults must stay equal; `test-setup-package-image.sh` compares them.

### The rust toolchain must be writable by the runtime user

Flutter is not the only tree the runtime user writes into. `rustup` writes
`$RUSTUP_HOME/tmp/` on every invocation and `downloads/`, `update-hashes/`,
`toolchains/` plus `settings.toml` on `rustup toolchain install`; `cargo`
creates `$CARGO_HOME/registry/` and `git/`. The 2026-09-03 images shipped both
trees root-owned, so at uid 1001 rustup died on `could not create temp file
/usr/local/rustup/tmp/...: Permission denied` — which takes Corrosion, cargokit
and `flutter_rust_bridge_codegen` with it, and cannot be worked around by
repointing `RUSTUP_HOME`, because that directory *is* where the toolchains live.
Consumers were passing `-e CARGO_HOME=...` to get half of it back.

Two paths put the toolchain in the runtime image and both had to be fixed where
the ownership is decided:

* **The COPY** (`Dockerfile.package`, amd64's toolchain is already the right
  arch) carries `--chown=${RUNTIME_UID}:${RUNTIME_UID}`, like `/opt/flutter`'s.
* **The native re-install** `ensure_native_rust_toolchain` performs on
  arm64/riscv64 runs as root inside the package `RUN` and re-creates both trees
  root-owned, so `main` calls `hand_root_created_paths_to_runtime_user` on them
  afterwards — after `wire_cargo_symlinks`, whose apt `cargo-cbuild`/
  `cargo-cinstall` fallback links are root-created too.

`hand_root_created_paths_to_runtime_user` is `find <paths> ! -user
${RUNTIME_UID} -exec chown -h ...`, not `chown -R`, and that distinction is the
whole cost argument. A `chown -R` in a **new** `RUN` rewrites metadata on all
5261 files of `/usr/local/rustup` (2.0 GB) and `/usr/local/cargo` (173 MB),
forcing overlayfs to copy every one of them up into that layer: ~2.2 GB added to
each of the three shipped images. Run inside the RUN that *created* the files
the chown is free — they are already in that layer — and `! -user` makes it a
no-op stat walk on the arch where the COPY already did the job. Modes are never
touched, so the trees stay owner-writable, not world-writable.

## The shipped trees must carry the image's own arch

`artifact-source` is the **builder's** image. A tree that was cross-built for the
target carries target-arch ELF; a tree that was merely *installed on the host*
carries x86-64, and the unconditional COPY ships it into the arm64/riscv64 runtime
image unchanged. Two members of that class shipped for months — the 2 GB `rustup`
whose `rustc` exited 127 on every foreign image, and Flutter's cached Dart SDK,
which executes *natively on the build host* and so passes any run-only check.
Both are fixed, and each has its own gate. What was missing is the general audit:
nothing read the ELF machine of what a foreign image actually carries, so a third
member would ship the same way.

`smoke-runtime-image.sh` `check_manifest_tree_arch` closes that. It is
manifest-driven — every path in `runtime-artifacts.manifest`, resolved the way the
image sees it — and it reads bytes, not behaviour:

* `${VAR}` in a manifest path is resolved from the environment, else from
  `Dockerfile.package`'s own `ARG VAR=default`. A token that resolves from
  neither **fails**; it would otherwise scan nothing and say nothing.
* The manifest carries the COPY **source** path, so `_rt_tree_probe_path` maps it
  to where the gate looks in the image. Two arms: the one documented relocation
  (`/opt/llvm-target` → `/usr/local/llvm-target`, listed in
  `verify-artifact-copy-parity.sh`'s `ALLOWED_RELOCATIONS` — the suite fails if the
  two owners of that fact stop agreeing), and `/opt/vulkan` → `/opt/vulkan/active`.
  The Vulkan tree deliberately ships the SDK's **x86-64 host tools** (glslang,
  SPIRV-Tools; `vulkan.sh` skips the rest for cross lanes precisely because no
  cross consumer loads them) beside the cross-built target libs, and `active` is
  what `VULKAN_SDK`, `PATH` and `LD_LIBRARY_PATH` resolve to. Asserting the whole
  tree would red every foreign image on tooling that is host-arch on purpose.
* One in-image scanner reads the ELF header of every object under those trees and
  aggregates `(tree, machine) → count`. Header reads in a single process, never a
  `readelf` exec per file, which under QEMU would cost minutes; the walk is sorted
  so a capped scan picks the same files on every run, and it says so when the cap
  is reached.
* Any object whose machine is not this image's is **fatal**, and the message names
  the tree and an example path. Exit status is not evidence: without the
  `TREESCAN_DONE` sentinel the gate fails rather than passing on empty output, and
  a scan that saw no tree at all is reported as the vacuous pass it is.

### What is exempt, and why the arm names the tree

`_RT_TREE_ARCH_EXEMPT` holds `/opt/android-sdk` alone: one linux-x86_64 SDK copied
unchanged into all three images, so its arch says nothing about this image either
way. The arm names the **tree**, never an arch — so a newly host-installed tree
fails by default instead of inheriting somebody's exemption. A tree that is present
but holds no ELF at all (a per-arch empty dir) is a note, not a pass: presence is
the ARCH-PARITY table's assertion, and absence of the directory itself is fatal
here.

### What the exemptions are worth

Every exemption above was *reasoned* from the build graph when it was written. On
2026-09-05 each was re-read from the three shipped `:latest-cross-<arch>` images
with the gate's own scanner, and the reasons did not all survive.

| exemption | measured, per image | verdict |
|---|---|---|
| `/opt/android-sdk` | the same 40 644-file tree in all three: 582 X86-64, 417 Intel-80386, 414 ARM, 414 AArch64, 33 RISC-V | **KEEP.** Without it arm64 and riscv64 red on 1 446 foreign objects that are the SDK's host toolchain and device libs |
| `/opt/android` | amd64 37 X86-64, arm64 37 AArch64, riscv64 34 RISC-V — and nothing else | **DELETED.** The reason ("device `.so`, arch says nothing") is false: `arch_android_abi_for` maps each build arch to the ABI with the SAME ELF machine (`amd64→x86_64`, `arm64→arm64-v8a`, `riscv64→riscv64`), and each image carries exactly one ABI directory. The gate now asserts it for free |
| `/opt/vulkan` probed at `/opt/vulkan/active` | `active/` is 122 files, 3 objects, all target. The rest of `/opt/vulkan` on arm64/riscv64 is **1 317 X86-64 + 2 Intel-80386 objects across 33 926 files — 1.8 GB of `x86_64/` plus 3.9 GB of `source/`** | **KEEP, but the number is a defect.** `active/` is what the image runs and is all the gate can honestly assert; 5.7 GB of builder-arch SDK in a 30.8 GB foreign image is the HT1 class, and belongs to a size entry, not to a looser gate |
| the cross-payload filter (`/lib/rustlib/`, `/lib/clang/`, `/lib/gcc/`, `gcc-*/​<triple>/`) | on amd64 it hides exactly the target payload: rustup's AArch64+RISC-V `libstd`, gcc's per-triple crt objects, clang's i386 multilib runtimes. On the foreign images it hides only own-arch objects | **KEEP.** It also does **not** hide the five X86-64 `libLLVM`/`libclang` in `/usr/local/llvm-target` on either foreign arch, which is how the frozen count of 5 was confirmed exact |

Two further facts the same scan settled, both of which had never been checked on a
real image: all **15** manifest trees exist as directories on all three arches (so
no `MISSING` verdict is latent), and no tree comes near the 20 000-file `RT_TREE_CAP`
— the largest asserted one is `/opt/flutter` at 17 523 candidate files on
amd64/arm64, 88 % of the cap. A Flutter bump could cross it; that is a `CAPPED`
failure, not a silent pass.

### The llvm-target prefix fills what it needs, and nothing else

`/opt/llvm-target` is the one tree that is *repaired* rather than merely copied,
and until 2026-09-05 both repairs were written as a **glob over the builder's
multiarch directory** — every `libLLVM*.so.2*` / `libclang*.so.2*` in
`/usr/lib/x86_64-linux-gnu`, copied in whenever `lib/<soname>` was absent.

The repair exists for a real defect: on amd64 the prefix is an apt LLVM tree whose
`lib/` holds dev **symlinks** into the multiarch dir, so the runtime sonames never
entered the prefix and the shipped clang bound to whatever ambient `libLLVM` the
consuming image carried (the 2026-08-11 franken-toolchain incident). What was wrong
was the *selection rule*. A glob copies whatever Ubuntu happens to have installed,
and the builder carries `llvm-20` and `llvm-21` alongside the pinned release.

Measured in the 2026-09-05 images, that shipped **five x86-64 libraries into both
foreign runtime images** — `libLLVM.so.20.1`, `libLLVM.so.21.1`,
`libclang-21.so.21`, `libclang-23.so.23`, `libclang-cpp.so.21.1`, 392 MiB — because
the guard tests the *filename*, and an arm64/riscv64 source build never produces a
soname named after Ubuntu's llvm-20/21. They were a closed island: the only objects
in either image that `DT_NEEDED` any of them were the copied libs themselves, and
the four real consumers (`libgallium`, `libOSMesa`, `doxygen`, the `llvm-21` tools)
resolve through `/usr/lib/<triplet>` — `ld.so` rejects the wrong `e_machine` and
falls through, so the copies were never loaded, only carried. The same glob put
358 MiB of the same Ubuntu libs into the amd64 prefix, where the tree-arch gate
structurally cannot see them because they are the image's own arch.

The rule is now **demand-driven**: `_llvm_target_fill_needed` in
`02-toolchain/materialize-llvm-target.sh` reads the `DT_NEEDED` of the prefix's own
`bin/` and `lib/*.so*`, copies only the LLVM-family sonames that do not resolve
inside `lib/`, and repeats until a round adds nothing (a filled lib brings its own
`NEEDED`). `-e` is false for a dangling symlink, which is exactly the apt dev-link
case, so the entry is removed before the copy. Its correctness is not a matter of
reading: the NEEDED walk immediately below is a **hard gate** — every LLVM-family
`NEEDED` of every shipped object must resolve inside the prefix, and every other
`NEEDED` (libc, libstdc++, zlib) against the base image's `ldconfig` cache, or the
sdk stage fails. The cache is captured once into a variable and matched with
`case`, because `ldconfig -p | grep -q` dies of SIGPIPE under `pipefail`.

The package stage no longer keeps a second copy of that logic. `repair_llvm_target_sonames`
was written as belt-and-braces for pre-2026-08-12 sdk artifacts, and its own note
said it should be removed once a rebuild showed it copying nothing; the rebuild
showed it copying nothing on amd64 and **only the five wrong-arch libs** on the
foreign arches, so the copy half is gone. What remains —
`publish_llvm_target_ld_path` in `06-packaging/copy-media-payloads.sh` — is
load-bearing and stays: `libtvm_compiler.so` carries a `DT_NEEDED` on
`libLLVM.so.<ver>` that resolves through `/etc/ld.so.conf.d/000-llvm-target.conf`
and nothing else, so dropping it makes `import tvm` die.

### What only a real build could tell you — and did

The table used to be reasoned from the build graph alone. The 2026-09-04 run and
the 2026-09-05 re-read of the shipped images answered it: `/opt/gcc-*` is
target-native (`swap-native-gcc.sh` `rm -rf`s the cross tree and copies the
Canadian-cross native one over it in the android stage); `/opt/llvm-target`,
`/opt/armnn` and `/opt/acl` are cross-built for the target; and the two members
that could not be ruled out statically — `/opt/flutter` (`bin/cache` engine
artifacts) and `/usr/local/rustup` (`downloads/` leftovers) — measure clean:
flutter is 19 objects of the image's own machine on amd64/arm64 and empty on
riscv64, rustup is 16/16/48 own-machine objects with every foreign one inside
`lib/rustlib/<triple>`. What the run *did* catch was the gate's own false
positives (cross payload, now filtered) and the five builder-arch LLVM libraries
that are backlog HT3. If a tree turns out to carry a legitimate builder-arch
helper the gate names the tree and an example path, and the fix is one arm with a
written reason — never a loosened comparison.

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

Running is not the claim, though — the 2026-09-04 image passed this gate green
while `flutter pub get` was broken for every consumer. So the same probe also
asks whether the SDK is USABLE by that user: `bin/cache` and
`packages/flutter_tools/.dart_tool` must be writable, and `find /opt/flutter
! -user "$(id -u)"` must come back empty. Both are `test`/`stat` questions, not
a `pub get`, because the smoke runs with `--network none`; each has its own
verdict line, so the message names the consumer symptom rather than a path.

## Guards

* `tests/test-artifact-copy-completeness.sh` — fixtures for both failure
  directions plus regression guards that the real manifest and Dockerfile agree.
* `tests/test-setup-package-image.sh` — `bootstrap_flutter_sdk` off-target: the
  no-op, the hard failure with flutter's output, the arch check, the handover of
  every root-created path (`bin/cache`, `.git/FETCH_HEAD`, the flutter_tools
  `.dart_tool`) and — on a tree the runtime user already owns — no `chown` at all,
  which is the size rule as an assertion.
* `tests/test-setup-package-image.sh` — `hand_root_created_paths_to_runtime_user`
  over a real tree with `chown` stubbed on PATH: the rustup/cargo pair root
  re-installed is handed over (`tmp/`, `toolchains/`, the apt `cargo-cbuild`
  link), a tree the COPY already owns draws no `chown` at all, `main` calls it
  after both root writers, and both `/usr/local` COPYs carry `--chown`.
  Mutations `rust.copy-chown`, `rust.toolchain-handover`,
  `rust.handover-only-root-owned`.
* `tests/test-runtime-image-gates.sh` — `check_flutter` against recorded image
  output: offline, the permission-denied shape, a pin mismatch, a builder-arch
  Dart SDK, an unwritable `.dart_tool`, a root-owned leftover, and the correct
  shape.
* `tests/test-runtime-image-gates.sh` — `check_manifest_tree_arch`: the real
  scanner against a fixture tree of hand-written ELF headers, the verdict function
  on a builder-arch tree in both directions, the missing-sentinel path, and the
  two host-side cross-checks (every manifest path resolves; the relocation and the
  exemption list still agree with their other owners).
* `tests/test-llvm-target-prefix.sh` — `_llvm_target_fill_needed` over a fixture
  prefix: the Ubuntu llvm-20/21 libs nobody needs are NOT copied, a dangling dev
  symlink IS replaced by the real soname, a lib pulled in by a lib is reached, the
  loop terminates, the package stage no longer copies anything into the prefix, and
  the loader-path half is still written. Plus `_RT_TREE_ARCH_FROZEN` empty and both
  of its gate arms.
* Mutations `artifact-copy.completeness-check`, `flutter.bootstrap-hard-fail`,
  `flutter.bootstrap-cache-handover`, `flutter.bootstrap-whole-tree-chown`,
  `flutter.smoke-offline`, `flutter.smoke-dart-arch`,
  `flutter.smoke-sdk-writable`, `flutter.smoke-root-owned`,
  `probe.tree-arch-mismatch`,
  `probe.tree-arch-machine-word`, `probe.tree-arch-scan-sentinel`,
  `probe.tree-arch-arg-default`, `probe.tree-arch-relocation`,
  `llvm-target.fill-is-needed-driven`, `llvm-target.fill-replaces-dangling`,
  `llvm-target.fill-reaches-fixpoint`, `llvm-target.no-package-stage-copy`,
  `llvm-target.ld-path-published`, `tree-arch.frozen-count-must-match`.
