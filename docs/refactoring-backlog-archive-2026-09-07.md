<!-- Closed Linux refactor items, archived 2026-09-07. OPEN work lives in refactoring-backlog.md. -->

# Refactoring backlog archive — 2026-09-07

Closed on 2026-09-07 and moved out of
[`refactoring-backlog.md`](refactoring-backlog.md), which is OPEN-only.
Each entry keeps the evidence that closed it.

**Two waves are in here.** The five entries the 2026-09-05 validating chain was
asked to settle — CC1, CL1, VK1, AB1 and APP1 — carry what that chain measured on
the shipped bytes. The eight after them are the wave that followed it: CS1 (the
owner's decision on the Vulkan host prefix), VK3, CS2, CS3, DISK3, R1, YB and F3,
all landed against a green static battery on an idle tree and **none of them
proven by a build**. VK2 stayed OPEN for exactly that reason and is still in the
live file.

**Read the numbers here as dated, not current.** The 2026-09-05 grooming found
four figures that lanes had carried forward and did not survive re-derivation
(HT4's nine dangling links were twelve, HT5's 18.5 %/19.2 % were 19.5 %/20.3 %,
CL7.2's failure mode did not reproduce, CC1's ownership half was already green).
Re-measure before trusting one.

### CC1. CLOSED — the consumer contract holds on the shipped bytes [done 2026-09-07]

**Answered by the 2026-09-07 `:latest-cross`.** The gate ran against the shipped
images on all three arches: **12/12 rows on amd64, 12/12 on arm64, 8/8 on riscv64**
(riscv64 carries four documented exemptions — no appimagetool, no Flutter, no
Flathub build). Nothing below is a pending question any more; it is kept as the
record of what the rows are for.


**Evidence: a consuming repo's CI lane, not a gate.** The
OmniAccelerANT lane ran against `:latest-cross-amd64` as uid 1001 on
2026-09-04 and reported four defects; all four were reproduced here in the shipped
bytes, and all four are fixed in the tree. Their acceptance script prints
`ALL SIX FIXED` on amd64 and arm64 today. What is still open is the half no probe
of the CURRENT bytes can reach.

| # | what the consumer saw | where it came from |
|---|---|---|
| 1 | `CCACHE_DIR=/workspace/.ccache`, `SCCACHE_DIR=/workspace/.sccache` — the cache lands in their bind-mounted checkout, and on a non-ext4 mount flatpak-builder aborts | `Dockerfile.package` ENV contradicting `01-core/compiler-cache.sh`'s `/var/cache/*` defaults |
| 2 | `rustup: could not create temp file /usr/local/rustup/tmp/…: Permission denied` — Corrosion, cargokit and `flutter_rust_bridge_codegen` cannot run | both `/usr/local` COPYs carried no `--chown`, and the foreign-arch re-install runs as root |
| 3 | `flutter build apk` → `[!] No Android SDK found` | `ANDROID_HOME`/`ANDROID_SDK_ROOT` are declared in `Dockerfile.android`, which `latest-cross` does not inherit |
| 4 | `flutter pub get` → `package_config.json (Permission denied)`; 37 root-owned paths under `/opt/flutter` | the COPY `--chown` is right, but a root-run `flutter`/`git` wrote into the SDK AFTER it |

**What the next 3-arch run must show, and nothing else can:**

* Defects **1 and 3 are ENV-only** and already `OK` on today's bytes. What a build
  must confirm is only that the strings are BAKED: `nerdctl image inspect` the new
  `:latest-cross-*` and read `Config.Env`. This stage is built on a rootfs export
  that drops the parent's `Config.Env`, so a value not declared here ships UNSET.
* Defects **2 and 4 need the rebuild's ownership work.** Probe as uid 1001:
  `find /usr/local/rustup /usr/local/cargo ! -user 1001` and
  `find /opt/flutter -user root` must both come back empty on **all three** arches.
* **The layer cost is the whole argument.** `COPY --chown` and a same-RUN
  `find ! -user … -exec chown -h` are zero-byte, where a later `chown -R` copies up
  ~2.2 GB of rustup+cargo and ~700 MB of Flutter per arch. There is **no prior
  per-arch size baseline in-tree** to diff today's 30.37 / 30.84 / 29.69 GB against,
  so "the `COPY --chown` did not copy up 2.2 GB" is argued, not measured. Record the
  three numbers from the next run so the wave after this one has a baseline.
* **The contract gate itself has never run on two of three arches.** The 2026-09-04
  chain died in the amd64 smoke. `check_consumer_contract` asserts 9 rows on amd64;
  the arm64 and riscv64 verdicts, and the advertised-key gate's 16 `OK`s with zero
  UNSET/UNREAD, are unproven bytes-side.

**Closed on 2026-09-05, so do not re-watch it:** the per-arch exemption table is no
longer reasoned. `riscv64:flutter-owner` was DELETED because the shipped riscv64
image measures `find /opt/flutter ! -uid 1001` = 0 — the row PASSES, and exempting
it would have let defect 4 ship green on that arch. `riscv64:dart-tool` and
`riscv64:appimagetool` were both re-measured and KEPT. And each exemption is now
re-checked by its OWN probe fact: `appimagetool`'s was being re-checked with the
flutter row's fact, so it could never have rotted at all.

**Still open, deliberately, and none of it in this entry's scope:** the shipped
image drops `CCACHE_MAXSIZE`, `SCCACHE_CACHE_SIZE`, `SCCACHE_CONF`,
`SCCACHE_IDLE_TIMEOUT` and `SCCACHE_ERROR_LOG` through the same rootfs export (a
value decision — base says 30G, `compiler-cache.sh` says 10G); `common.sh` still
defaults `CCACHE_DIR` to `${HOME}/.cache/ccache`, outside the new pin; no JDK ships
in any arch, so `ANDROID_HOME` is necessary but not sufficient for
`flutter build apk`; the Android host tools are linux-x86_64 on every arch;
`flutter_tools/.dart_tool/package_config.json` resolves every package to
`file:///root/.pub-cache`, 145 MB shipped under mode-0700 `/root` (latent today,
fixable with `PUB_CACHE=/opt/flutter/.pub-cache` in the same RUN); the foreign
arches still ship the builder-arch rust toolchain twice, because
`ensure_native_rust_toolchain`'s `rm -rf` only writes overlay whiteouts; and
`flutter_rust_bridge_codegen` asks for a floating `nightly` the image does not carry.
`Dockerfile.nvidia`'s ENV-ordering fix is in the same class as `Dockerfile.android`'s
but was proven by reading only — no nvidia image exists on this host.

**CORRECTED 2026-09-05 — the ownership half is ALREADY GREEN on today's shipped
bytes, on all three arches.** Measured as uid 1001 in `latest-cross-{amd64,arm64,riscv64}`:
`find /usr/local/rustup /usr/local/cargo ! -user 1001` = **0** and
`find /opt/flutter -user root` = **0** everywhere (riscv64's `/opt/flutter` is the
documented 1-entry empty dir; arm64 is 21 578 entries). Defects **2 and 4 are therefore
a REGRESSION WATCH, not a discovery** — the run must keep them at 0, not reach it. The
ENV half checks out as written too: `CCACHE_DIR=/var/cache/ccache`,
`SCCACHE_DIR=/var/cache/sccache`, `ANDROID_HOME=ANDROID_SDK_ROOT=/opt/android-sdk` on
all three; and the deliberately-open list is confirmed UNSET (`CCACHE_MAXSIZE`,
`SCCACHE_CACHE_SIZE`, `SCCACHE_CONF`, `SCCACHE_IDLE_TIMEOUT`, `SCCACHE_ERROR_LOG`,
`PUB_CACHE`). The per-arch size baseline this entry keeps asking for is
**30.37 / 30.84 / 29.69 GB**, verified against `nerdctl images` on 2026-09-05 — that is
the number the next run gets diffed against.

**Both "worth acting on" items are now CLOSED, so do not re-raise them.**
`/opt/flutter` was already advertised in
[`consumer-image-contract.md`](consumer-image-contract.md); the `VOLUME` note is
written there now — neither cache directory is one, and the image declares exactly
**one** `VOLUME`, `/workspace` (`Dockerfile.torch:118`, confirmed in `Config.Volumes`
of all three shipped children). The multi-arch index fixing their arm64 lane is the
payoff line for the manifest work; do not forget it when the index shape is next
touched.

### CL1. CLOSED for everything a chain touches — with one honest gap [done 2026-09-07]

**A green chain reported.** `--from-stage sdk` built sdk, media and android on all
three arches, and the runtime lane then built base, package, torch and wrapper per
arch and published a 3-arch manifest with `manifest-freshness PASS`. So the
`01-core`, `02-toolchain`, `03-media`, `04-runtime`, `05-frameworks` and
`06-packaging` edits this file was worried about have now executed.

**The gap, stated rather than glossed:** `base` and `compiler` were NOT rebuilt from
source in that chain — the runtime lane builds its own per-arch base image, which is
what exercised `packaging-deps.sh`, but the SHARED base/compiler stages were
inherited by digest. Nothing in this wave changed them, so that is a correct
shortcut and not a hole; it stops being true the moment someone edits them.


**Nothing the 2026-09-04 or 2026-09-05 waves changed under `01-core`,
`02-toolchain`, `03-media`, `04-runtime`, `05-frameworks` or `06-packaging` has been
through a build.** Every edit carries a suite case and a mutation, and every mutation
bites — but a suite cannot execute a Dockerfile stage. This list grew substantially
on 2026-09-05 and it closes the moment a green 3-arch chain reports.

**First, what the 2026-09-04 run did and did not exercise, because the old version
of this entry over-credited it.** That run's header says `stages=runtime..runtime`:
it pulled `cross-android-<arch>` and built only the package/runtime stage, and then
it FAILED. Of the eight wave-1 rows, **five never executed at all** —
`compiler-resolution.sh`'s `derive_cxx_from_cc`, `cross-env.sh`'s
`_cross_env_resolve_tools`, `patch-gstreamer-sources.sh` patch 006, the five deleted
dead functions in `cpython-dev-packages` / `verify-media-artifacts` / `build-ffmpeg`,
and `versions.env`'s quoted `CUDA_ARCHITECTURES` all need SDK / media / nvidia
stages. `disk-guard.sh` loaded and sampled but never crossed 40 G (275 G → 106 G
free), so it reclaimed nothing. `build-cross-chain.sh`'s `_chain_on_exit` fired on
the FAILURE path, so "a chain that finishes GREEN must exit 0" is still unproven.
Only `smoke-runtime-image.sh`'s tree-arch and advert arms really ran, amd64 only.

**Wave-1 rows, all still open:**

| file | change | what the log should show |
|---|---|---|
| `01-core/compiler-resolution.sh` | `derive_cxx_from_cc` returns 0 with empty output instead of the test's status | the arm64/riscv64 SDK stages are the only paths that hit the g++-not-found fallback; a refusal there must still NAME the missing compiler, not die under `set -e` |
| `01-core/cross-env.sh` | `_cross_env_resolve_tools` tests the VALUE | with the change above, this is the only thing stopping a stage sailing on with `CXX` empty |
| `build-cross-chain.sh` | `_chain_on_exit` is an `if`, not a trailing `&&` list | a chain that finishes GREEN must exit 0 |
| `03-media/.../patch-gstreamer-sources.sh` | patch 006's guard is an `if` | a tree WITH `gst-libav` must still apply the patch — the suite proves only the absent path |
| `01-core/cpython-dev-packages.sh`, `03-media/runtime/verify-media-artifacts.sh`, `03-media/build/ffmpeg/build-ffmpeg.sh` | five dead functions deleted | a caller that BUILDS the name at runtime is invisible to grep; only a real base→media chain proves none exists |
| `01-core/versions.env` | `CUDA_ARCHITECTURES` quoted | only a CUDA-enabled media/nvidia stage proves the quotes do not reach `-DCMAKE_CUDA_ARCHITECTURES=` and defeat the ONNX build's trailing `90` → `90a` rewrite |

**Rows the 2026-09-05 wave added — the sccache half is the loudest:**

| file | change | what the log should show |
|---|---|---|
| `01-core/common.sh` | NEW `compiler_cache_launcher_env`, and 12 call sites in 11 files call it before resolving the launcher | see YB. Every `sccache-launcher` line must print `[server=/tmp/sccache-<uid>.sock]` and never `[server=tcp:4226]` |
| `linux/Dockerfile.toolchain` | both per-file `01-core` mount blocks now mount `sccache-launcher.sh` | the GCC/LLVM stages stop running BARE sccache, where an sccache fault ABORTS the build instead of costing a cache entry |
| `01-core/compiler-cache.sh` | `sccache_export_server_address` hoisted out of the `$( )` resolver in `setup_ccache` and `setup_sccache` | the same `[server=…]` field, from the media lane this time |
| `02-toolchain/materialize-llvm-target.sh` | the multiarch glob became a demand-driven `_llvm_target_fill_needed` walk | the amd64 sdk stage must print `amd64 /opt/llvm-target NEEDED walk clean` and must NOT print `is NOT self-contained` — this is the one place the change can break a build, and it fails at the sdk stage rather than shipping |
| `06-packaging/copy-media-payloads.sh` | **the row's old wording was WRONG.** `copy_media_payloads` is very much alive and `Dockerfile.package:144` runs it; what was deleted is the llvm-target SONAME-REPAIR loop. A reader acting on "the payload copy is gone" would have skipped the loop the absl defect actually lived in. `/usr/local/include/absl` is now IN that copy list | `import tvm` must still work on all three arches (`smoke-torch-venv.sh`'s tvm row) — **and** the log must NOT print `copy-media-payloads: optional payload missing: …/absl` on any arch |
| `01-core/guard-helpers.sh`, `01-core/version-forwarding.sh` | `csv_each` and `append_version_build_args` loop bodies became `if`s | `append_common_build_args` → `append_version_build_args` runs for every stage's build-arg assembly; only a chain proves the forwarded `--build-arg` list is byte-identical |
| `03-media/.../build-gstreamer-stage.sh` | `_dump_gst_build_logs` (the stage's ERR trap) became an `if` | only a FAILING GStreamer build exercises it; a green build proves nothing and a red one is the test |
| `01-core/cross-gcc.sh` | `export_clang_gcc_toolchain_env` DELETED | watch the toolchain and media stages for `command not found: export_clang_gcc_toolchain_env`. Static evidence is strong (no caller, no `CC=*clang` anywhere, the wrappers bake `--gcc-toolchain` themselves) but a Dockerfile `RUN` assembling the call at runtime is invisible to grep |
| `01-core/cpython-dev-packages.sh` + `02-toolchain/python/build_python.sh` | the lib-dynload audit reads `cpython_ext_modules` | the audit now WARNS for five modules it never checked (`_zstd`, `readline`, `_curses`, `_uuid`, `_decimal`). Those are information on `optional` rows, not failure — but any of them appearing on **amd64** is a genuine finding |
| `04-runtime/gstreamer-env.sh` | dead `SYSTEM_LIB` deleted from both TRIPLET branches | only a rebuilt image proves the entrypoint still sources it and that `GST_PLUGIN_PATH`/`PKG_CONFIG_PATH`/`LD_LIBRARY_PATH`/`GI_TYPELIB_PATH` still carry the multiarch entries on arm64 and riscv64 |
| `03-media/.../gstreamer/common/pre-setup.sh` | `gi_bindir`, `gi_libdir` and the now-dead `build_triplet` deleted | only a stage that builds the monorepo proves the g-ir-scanner / ldd / qemu wrappers are still written and `gobject-introspection-1.0.pc` still resolves. **riscv64 is the arch to watch** — its introspection runs under qemu |
| `01-core/stage-defs.sh`, `build-runtime-manifest.sh`, `01-core/python_uv.sh` | dead locals removed | closest to already-proven (preflight's `stage-graph` slug runs the real graph); what a chain adds is `build-cross-chain.sh` getting a 0 verdict under the orchestrator's own env |
| `03-media/build/onnxruntime/build/{30-build-native,30-build-native-amd,30-build-native-nvidia,60-build-genai}.sh` | four copies of the end-of-stage summary replaced by `report_onnx_build_output` | one per lane. Unproven statically: the `find … \| head -20 \|\| true` pipeline under the stage's `pipefail` (head closing the pipe can SIGPIPE `find`), and that the AMD stage's output is unchanged now that it uses `head -20` where it used `sed -n '1,20p'` |
| `linux/scripts/lib/slang-compile.sh` | `_slang_emit_one_wgsl` extracted | validated only against a fake `slangc`; a consumer run with the real one against a real manifest is what proves it end to end |

**Rows the 2026-09-05 INTEGRATION wave added.** All of these are inside the build
closure and none has ever executed:

| file | change | what the log should show |
|---|---|---|
| `02-toolchain/vulkan.sh` | `_vulkan_prune_sdk_sources` drops `<ver>/source` in the SAME RUN that consumed it | `Pruning the Vulkan SDK build tree at /opt/vulkan/<ver>/source`, and immediately BEFORE it `Vulkan cross-targets <arch>: N/N component(s) built`. The order is the whole safety argument |
| `linux/Dockerfile.package` | a NEW `RUN` in the `artifact-source` stage prunes `<ver>/x86_64` ahead of the `/opt/vulkan` COPY | the stage fails fast with the script's own `ERROR` line if the bind mount does not land — cheap, and before any COPY |
| `02-toolchain/materialize-llvm-target.sh` | `_llvm_target_repair_links`, ending in a `find -xtype l` that HARD-FAILS the sdk stage | it has never run on any arch, and the first rebuild attempt already found a self-link bug in it (HEAD `e109f5ad`). A survivor names its exact path |
| `03-media/core/common.sh` | NEW `media_compiler_launcher`, called unqualified by ffmpeg and pyav under `set -e` | **the one failure here that kills a run outright.** `media_compiler_launcher: command not found` in the media stage means the image's copy of `03-media/core/common.sh` is an older layer than the two build scripts |
| `06-packaging/copy-media-payloads.sh` | `/usr/local/include/absl` added to the copy list | 707 of the 1322 shipped LiteRT headers `#include "absl/"` and no arch shipped absl. `smoke-critical-fixes.sh` must go from 1 FAIL to 0 on all three |
| `02-toolchain/packaging-deps.sh` | `ensure_appimagetool_runtime` (wired at integration — it had no caller), and `INSTALL_FLATPAK_RUNTIMES` now ON with all seven refs | `Staged AppImage runtime-<arch>` once per arch; the flatpak install adds ~1.9 GB to amd64/arm64 and is skipped outright on riscv64 |
| `06-packaging/setup-package-image.sh` | `install_web_lane_toolchain` | non-fatal throughout, so read the WARNs: a `WARN: the nightly channel is unavailable` means the web lane still auto-installs it per consumer run |

**Two shapes that would be silent if wrong**, unchanged from wave 1: an operator
whose shell still exports `MYPROJECT_GCC_TOOLCHAIN_PATH` is now ignored rather than
erroring, and eleven of thirteen `: "${NAME:=default}"` conversions sit at file top
level — so any Dockerfile `RUN` that *slices* a script rather than running it whole
would read an unset variable. `IREE_CROSS_BUILD_COMPILER` was caught statically for
exactly that reason; a second would look identical. The 2026-09-05 additions were
checked against this: `cpython_ext_modules` sits inside a sourced module, and
`pre-setup.sh` is executed WHOLE (`build-gstreamer-stage.sh:107`), so neither adds a
slicing hazard.

### VK1. CLOSED — the foreign-arch SDK is built and measured [done 2026-09-07]

**Answered on the shipped images, not the log.** `${VULKAN_SDK}/bin` holds **20
tools on arm64 and 20 on riscv64**, each with **4 validation-layer manifests** —
up from 2 and 0 respectively. `glslc`, `vulkaninfo`, `vkcube` and the whole
`spirv-*` family are among them. Four components still do not cross-build; they
are VK2, with a route each.


Superseded the "known gaps" list on the same day it was written. Two of its three
gaps were not gaps:

- **`glslc` is buildable.** The first look reported `source/shaderc` as carrying no
  `CMakeLists.txt` — true, but the checkout lives one level down in
  `source/shaderc/src`, with a populated `third_party/` (glslang, spirv-tools,
  abseil, re2). The lesson is the general one: a missing file at the path you
  guessed is not evidence the thing cannot be built.
- **`vulkaninfo` was only missing because of a skip.** `Vulkan-Tools` sat in the
  cross skip list, so its source was never fetched. Removing the skip fetches it.

`_vulkan_build_components` now skips nothing, and `_VK_TARGET_COMPONENTS` drives a
cross-build of all fifteen remaining components through one shared installer.
`slang` (host LLVM `tblgen`) and `vulkanCapsViewer` (Qt for the target) are still
expected to fail to configure — they are attempted anyway, non-fatally, so the build
log reports what is true instead of a comment asserting it.

**What is actually unknown**: none of these fifteen cross-builds has ever run. The
next rebuild is the first evidence. Read the per-component `Cross-building <label>`
and `<label> unavailable` lines in the lane logs, and the
`check_vulkan_toolset` verdict on each shipped image, then record here which
components genuinely cross-build and drop the ones that never will.

### AB1. CLOSED — the Android payload is the target's ABI [done 2026-09-07]

**Answered on the shipped bytes.** `check_android_abi` reports **413 Android
objects, all `arm64-v8a`**, in the amd64 image — the exact case the consumer hit,
since they run the amd64 container to build an arm64-v8a app. Their own probes
agree: `libonnxruntime.so` is AArch64, `sdk/native/libs` is `arm64-v8a`, and
`libgstreamer-1.0.a(gst.c.o)` — the object named in their linker error — is
AArch64.


Reported by the OmniAccelerANT android lane 2026-09-05, as a link
error rather than a missing file — every SDK was present and every one was wrong:

```
ld.lld: error: /opt/android/gstreamer/libgstreamer-1.0.a(gst.c.o)
        is incompatible with aarch64linux
```

Root cause was one function. `android_target_arch()` returned `arch_oci` — the
architecture of the machine running the build — and every cross stage builds on
`linux/amd64`. So all five prebuilt SDKs under `/opt/android` (GStreamer, ONNX
Runtime, LiteRT, OpenCV, IREE) were compiled for Android `x86_64` in EVERY image,
arm64 and riscv64 included. `x86_64` is the emulator ABI.

Measured over the whole tree on the shipped image, not just the three the report
sampled: **420 objects, every one ELF machine 62 (X86-64), 0 AArch64.**

FIXED: `ANDROID_TARGET_ABI` (versions.env, default `arm64-v8a`) names the target;
`arch_for_android_abi` maps it back so `TARGET_ARCH` and the ABI cannot disagree —
that pair drives cerbero's `CERBERO_TARGET_ARCH`, the API-level floor and ONNX
Runtime's riscv64 skip. The five cerbero cachemounts now carry the ABI in their id:
they were keyed on `${TARGET_ARCH}`, which is the constant build host, so a
switched ABI would have resumed the previous ABI's tree and spent hours building
the wrong thing. `check_android_abi` asserts the shipped payload against the ABI
the image advertises, reading `.a` MEMBERS as well as `.so` files because the
object that broke the consumer's link was inside an archive.

Two things the same report turned up:

- **The SDK roots were never advertised.** `Dockerfile.android` sets
  `GSTREAMER_ROOT_ANDROID` and its four siblings; `Dockerfile.package` COPYs the
  payload and re-declared none of them, so a consumer found `/opt/android` and no
  name for anything in it. All five are exported now, one `ENV` each. Deliberately
  no bare `OpenCV_DIR` — that name would hijack every Linux OpenCV consumer in the
  image; `OPENCV_ANDROID_JNI_DIR` carries the Android tree instead.
- **The Flutter finding does not reproduce.** `/opt/flutter/bin/cache/dart-sdk/bin/dart`
  exists in the shipped image and `flutter --version` answers instantly with Dart
  3.13.1, no download — at engine revision `5d53178869`, the SAME one the report's
  download line names. Whatever re-fetches it is on the consumer side (a volume over
  `/opt/flutter`, a different uid, or an older pull), not in the image.

**Open: one ABI per image.** Multi-ABI would want the official multi-ABI artifacts
(GStreamer's universal tarball already carries `arm64/armv7/x86/x86_64`; the OpenCV
Android SDK and the ONNX Runtime AAR likewise) rather than N source builds. Until
then `ANDROID_TARGET_ABI=x86_64 ... --only android` rebuilds the layer for the
emulator. docs/linux-cross-builds.md#the-android-abi-is-a-target-not-the-build-host

### VK3. LANDED — the SDK can no longer shrink in silence [done 2026-09-07]

The owner's 2026-09-05 request, all four parts, and the **mechanism is owned by
[`vulkan-foreign-arch-sdk.md`](vulkan-foreign-arch-sdk.md#the-toolset-floor-only-ratchets-up)
— read it there, do not restate it here.** In one line each: the twenty measured
tools are required rather than reported; the tool and layer-manifest counts are
frozen per arch; the validation manifest fails instead of warning; and
`_vulkan_target_verdict` fails the SDK stage on a lost REQUIRED component
instead of counting one survivor as success.

**What is left is one promotion, and it is deliberate.** Two rows of the frozen
table carry `>=` floors rather than exact counts, because VK2 raises them and
inventing the post-VK2 number would be fabricating a measurement. The next chain
prints them (`RATCHET: floor 20 -> N`). Record those as exact numbers then, and
move the four `_VK_REPORTED_TOOLS` names into the required set in the same edit —
once, not twice.

### CS3. LANDED — a verified download where upstream publishes one [done 2026-09-07]

Measured in the 2026-09-05 runtime lane, same two `cargo install`s on each arch:

| arch | wasm-pack | flutter_rust_bridge_codegen |
| --- | --- | --- |
| amd64 | 87 s | 113 s |
| arm64 | 768 s | ~1170 s |
| riscv64 | 1813 s | 3500 s |

Roughly 9x on arm64 and 20x on riscv64 — QEMU user-mode emulation, not a defect.
`install_web_lane_prebuilt` now takes upstream's own `linux-musl` release binary
for x86_64 and aarch64, verified against a per-arch `*_SHA256` pin in
`versions.env` (the same shape sccache and binaryen already use; the four hashes
were fetched and, where upstream publishes a `.sha256` sidecar, cross-checked
against it). Everything else falls back to `cargo install --locked`: riscv64,
which upstream publishes no asset for, a missing pin, a failed or mismatching
download, or a tarball without the binary in it. Nothing unverified is ever
installed, and the four hashes bump WITH the two versions.

**The open half is a question, not work**: whether a riscv64 web lane exists at
all. It is recorded at
[`consumer-image-contract.md`](consumer-image-contract.md#the-web-lane-toolchain)
rather than assumed away — "we assumed nobody uses it" is how the Android layer
ended up built for the wrong ABI (AB1).

### APP1. CLOSED — the rename landed in both repos, and the stale path was a cached layer [done 2026-09-07]

The 2026-09-06 runtime smoke failed on amd64 with three findings that are one
cause: `app wheel smoke FAILED`, `ARCH-PARITY: OrchestrANT missing`, and
`application module (orchestrant) failed to import`.

The GitHub repo was renamed to `OrchestrANT` and ContainerHub followed (it clones
`OrchestrANT.git` into `/opt/OrchestrANT` and runs `python -m orchestrant.smoke`).
The app repo's CONTENTS had not: at tag `v0.0.27` it still declared
`name = "Orchestr-ANT-ion"`, shipped the module as `orchestr_ant_ion/`, and carried
`VERSION.txt = 0.0.22` — a version that had not been bumped in five tags.

FIXED in the app repo (2026-09-06): module `orchestr_ant_ion/` -> `orchestrant/`
via `git mv`, dist name -> `orchestrant`, console script -> `orchestrant-smoke`,
`VERSION.txt` -> `0.0.28`, every GitHub URL -> `Kataglyphis/OrchestrANT`, display
name -> `OrchestrANT` (which keeps the ANT), remote URL updated, `uv.lock`
regenerated. The two CHANGELOGs deliberately keep the old name: they are a record
of what happened, not a description of what is. ContainerHub's `APP_REF` is
`v0.0.28` in all four Linux places, and the repo's own `sync_versions.py --write`
carried the same pin into `windows/Dockerfile.torch` and the dependency table.

**The hypothesis held.** The shipped amd64 image carried
`/opt/Kataglyphis-Orchestr-ANT-ion` (88 MB) and NOT `/opt/OrchestrANT`, while the
build log showed both being cloned in the same `[torch 4/5]` step. The old path was
in neither repo's source and not in the android ancestor — all three checked — so
the remaining explanation was a BuildKit layer cached from before the rename, whose
filesystem is what shipped. The prediction was that the `APP_REF` bump invalidates
it. Measured on the 2026-09-07 `:latest-cross`: `ls -d /opt/*rchestr*` returns
`/opt/OrchestrANT` and nothing else. CLOSED.

Worth keeping as a pattern rather than an anecdote: a cached layer replays its
ORIGINAL output into the log, so the log can describe work that this run did not
do. Two clone lines for one clone is what that looks like from outside.

### CS2. CLOSED — the pin was right; the diagnosis was missing [done 2026-09-07]

Measured in the runtime stage of the 2026-09-05 rebuild: six of seven refs
install, the seventh does not.

```
[INFO] Installing org.freedesktop.Platform.openh264//2.5.1
[WARN] org.freedesktop.Platform.openh264//2.5.1 did not install
[INFO] Flatpak runtime installation complete (6/7 refs)
```

**This entry's premise was wrong.** `2.5.1` IS a published branch, for both
arches flathub builds — `dl.flathub.org/repo/refs/heads/runtime/org.freedesktop.Platform.openh264/<arch>/2.5.1`
answers 200 for `x86_64` and `aarch64` (`2.6.0` answers 404, so the endpoint
discriminates), and flathub's own API lists 2.5.1 as the current release. So
`FLATPAK_OPENH264_VERSION` needed no change.

What was missing is the reason. openh264 is an **extra-data** ref: flatpak
downloads the binary from Cisco at install time, so a published branch and an
unreachable payload produce exactly the same "did not install" line. On a
failure the installer now asks the remote what it publishes for that name and
prints the branches, or says the ref NAME is wrong when the remote lists none —
in the run that hit it, instead of leaving it to log archaeology. The per-ref
non-fatal handling is unchanged: one bad ref costs one ref. The `(N/7)` count is
derived from the ref list now rather than a literal 7.

### DISK3. LANDED — the guard can see the third store now [done 2026-09-07]

The 2026-09-05 run said `NOTHING was reclaimable` at 28G free while
`~/.local/share/containerd` held **295 GB**, three `cross-android-*` images from
a PREVIOUS run among them; it needed four manual rescues. `disk-guard.sh` had no
image listing at all.

`_disk_guard_image_store_fallback` is the third lever, and its
**mechanism, ordering rule and protected set are owned by
[`build-cache-tiers.md`](build-cache-tiers.md#322-the-image-store-lever-disk3) —
read it there, do not restate it here.** The three things this file exists to
record:

1. **The ordering constraint is enforced, not documented.** The lever takes a
   `stage_in_flight` flag and refuses by name when it is set; the in-stage
   sampler passes 1 and can therefore never pull it, which is what killed the
   arm64 lane on 2026-09-06.
2. **The give-up message changed.** `[disk-reclaim]` now names the image store
   and says "stop the lane, then reclaim" instead of implying an environment
   limit.
3. **What is still NOT automated, on purpose.** Nothing compares live images
   against the digests this run pinned, so the protected set is "the stages after
   the completed one, plus the completed one" rather than "the parents in
   `chain-status.json`". That is the conservative reading — it can leave bytes on
   disk, never remove a parent — and tightening it needs a real chain to prove.

### CS1. CLOSED — the owner decided, and the prune stays scharf [done 2026-09-07]

**Owner decision 2026-09-07: keep pruning.** `prune-vulkan-host-sdk.sh` removes
`/opt/vulkan/<ver>/x86_64` from the FOREIGN images and is a no-op on amd64, where
that prefix IS the downloaded SDK. Nothing changed in the code to close this: the
prune has been wired in `Dockerfile.package`'s `artifact-source` stage since
`e6287256` and the 2026-09-07 chain already shipped with it — which is where the
foreign arches' −2.11 GB / −4.65 GB came from. The decision makes that the
intended state rather than an unreviewed one, and the coupling resolves the same
way: the tree-arch gate stays UN-narrowed, asserting the whole `/opt/vulkan` tree,
because the prune it depends on keeps running.

**Declined, with a reason:** a warm `~/.pub-cache`. The reporter marked it optional
themselves, and its contents follow `pubspec.lock` — an image-baked cache is stale
for any consumer whose lock differs, which is every consumer that is not this one.
Staging it would trade a real download for a silent wrong-version risk. `flutter
pub get` stays a per-run cost.

### YB. CLOSED — the cache is being hit, and the counters were there all along [done 2026-09-07]

**Both halves are answered.** The address arrives: the media stage logs
`[CACHE] sccache enabled: SCCACHE_DIR=/var/cache/sccache, CACHE_SIZE=30G
[server=/tmp/sccache-...]` — a Unix socket path, which is exactly what the fix was
for (every client used to fall back to the DEFAULT TCP port 4226 because the
address never reached it).

**And the hits are real.** This entry said `--show-stats` was "not in the chain's
output". It is — `dump_compiler_cache_stats` has been wired as an EXIT trap in
`media_common_init` all along, and the 2026-09-05 arm64 media log carries **88**
dumps. What made it look absent is that **79 of those 88 report zero requests**:
they are the t≈0 snapshot `setup_ccache` prints before the first object, and a
reader scrolling past a wall of zeros concludes there is nothing to read. The
nine that ran after real compiles, paired requests→hits from that log:

| compile requests | cache hits | misses | errors | hit rate |
| ---: | ---: | ---: | ---: | ---: |
| 3104 | 2732 | 10 | 0 | **88.0 %** |
| 1335 | 763 | 202 | 0 | 57.2 % |
| 500 | 499 | 0 | 0 | 99.8 % |
| 402 | 365 | 0 | 0 | 90.8 % |
| 201 | 201 | 0 | 0 | 100 % |

Zero errors anywhere, which is the counter the four-row table in
[`build-cache-tiers.md`](build-cache-tiers.md#the-server-address-must-be-exported-where-the-compiles-run)
calls impossible on a broken cache.

**One honest gap, and it does not need its own entry.** That reading is from
2026-09-05 and the socket-address line is from the 2026-09-07 run, which was
`--only runtime` and compiles almost nothing — so no single lane has yet printed
both. The next compile-heavy chain does, without anyone doing anything: the trap
is wired, and the numbers above are what a healthy reading looks like.

**The correction the old entry asked for, kept:** the 27 / 514 figure was never a
5 % recovery rate; it is four containers each all-or-nothing. All 514
`failed twice` sit in step #24 litert (364), #34 ORT genai (100) and #45 pyav
(50); all 27 `retry succeeded` sit in #29 TVM, which has zero failures of the
other kind. Use the per-step split, not the aggregate.

### R1. CLOSED — all four, three fixed and one re-measured [done 2026-09-07]

1. **The runtime-side `ldd` gate exists now.** `check_llvm_target_startable`
   walks `/usr/local/llvm-target/bin` INSIDE the shipped image and fails on any
   binary with an unresolved `NEEDED`. The sdk stage's self-containment walk
   resolves those sonames against the BUILDER's ldconfig cache, which is how
   `liblldb` shipped three unstartable binaries — `lldb`, `lldb-dap`,
   `lldb-mcp` — past every green run. It reads `0 of N` today and, unlike the
   sdk-side walk, a probe that did not run fails instead of reading clean. Four
   suite cases and three mutations, including the wiring one.
2. **`VK_LAYER_PATH` points at a directory that exists.** Both
   `Dockerfile.package` and `runtime-paths.env` named
   `/opt/vulkan/active/etc/vulkan/explicit_layer.d`, and SDK 1.4.357 has no
   `etc/` under any arch prefix — the layers are in
   `<arch>/share/vulkan/explicit_layer.d`. The measured caveat that made this
   look harmless is written up at
   [`vulkan-foreign-arch-sdk.md`](vulkan-foreign-arch-sdk.md#vk_layer_path-pointed-at-a-directory-that-has-never-existed):
   the entrypoint's `setup-env.sh` unsets the variable anyway, so this is the
   value a consumer that does not source it gets.
3. **LOG14's ~390 s/lane: the NUMBER survives re-measurement, the claim around it
   does not.** Measured from the 2026-09-05 arm64 SDK log's own `~~~Building X~~~`
   timestamps, the five components the skip list named cost the HOST build
   **381 s**: ValidationLayers 195.8 s, shaderc 119.5 s, SPIRV-Cross 61.7 s,
   Vulkan-Tools 34.5 s, volk 1.8 s, VMA 2.5 s. So the saving was real arithmetic —
   but the shipped foreign images carried those source trees and a BUILT
   `libspirv-cross-c-shared.so` regardless, because `./vulkansdk` fetches and
   partly builds what the argv removed. VK1 deleted the skip list; the lane pays
   those 381 s deliberately now, for components it actually ships.
4. **A disarmed row no longer reads as a revived function.** GH6's arm goes STALE
   when any corpus file starts naming BOTH definers' basenames, under a heading
   that says "the function is called again or gone" — and neither half is true.
   `check_keys` grew a `describe_stale` hook (default unchanged for every other
   gate) and the dead-function gate names the file that disarmed it and the two
   basenames, plus "the function is not called again". A stale row with a real
   cause stays plain: the explanation only fires where ONE file could load BOTH
   definitions. The other 93 masked rows remain a watch list, unchanged.

**Two things recorded so a future reader does not "simplify" them.** The foreign
`x86_64/` Vulkan prefix is 4.14 MB LARGER than amd64's over the same 4 399 files,
so `./vulkansdk`'s host build does overwrite part of the tarball on a cross lane —
and those host tools have a real build-time consumer (`build-opencv.sh` reads
`/opt/vulkan/<ver>/x86_64` for headers), which is exactly why HT5 prunes at the
packaging boundary and not in the SDK stage. And CL6's three TFLite helpers still
leak `dep`, `_gcc_arch` and `_gcc_dir` into the caller's scope: pre-existing,
deliberately not changed in a build window, because localising them is a real
state change and the split's whole claim is that the bodies moved verbatim.

### F3. CLOSED — the four named families, two owned and two judged [done 2026-09-07]

The decided/reviewed history (the source-or-fallback KEEP decision, the lint-tool
and `lib/*` pairs, the Dockerfile mount preambles, the `install-deps.sh` family,
and the three extractions of 2026-09-04/05: the `lib/*` logging preamble, the ORT
end-of-stage summary, the ffmpeg↔pyav launcher twin) is in the 2026-09-03 archive
and in [`code-dupes.allow`](scripts/code-dupes.allow). **That file is the
authority for every verdict below — read the row, not this summary.**

**OWNED 2026-09-07 — `media_jobs` takes its cap as an argument.** The name has two
definitions on purpose (`03-media/core/common.sh` assumes `media_common_init`
pre-loaded `parallelism.sh`; `android-build-preamble.sh` sources it on demand),
and BOTH hardcoded 2000 MB — which is why the android gstreamer lane kept a third
copy of the whole block for its own `ANDROID_GSTREAMER_PER_JOB_MB` of 1500. Both
now take `[cap_mb]` defaulting to 2000, and `build-android-from-source.sh` calls
`media_jobs "${PER_JOB_MB}"`. `test-media-jobs.sh` pins that both defaults agree
and that the cap reaches `compute_jobs_with_mem_cap` unchanged; two mutations hold
it. **The one behaviour given up is named**: the inline copy used `nproc --all`
in the no-`parallelism.sh` fallback, a path the android image never takes because
it ships `/opt/scripts/core`. `build-app-wheelhouse.sh` keeps its own copy on
purpose — it prefers `compute_cpp_heavy_jobs` (4 GB, torch's aten TUs), which is a
different ladder, not a different cap.

**OWNED 2026-09-07 — `sync_versions.py`'s two syncers.** `_update_dockerfile_args_inner`
and `_update_script_defaults_inner` were the same algorithm over two syntaxes.
`_rewrite_lines` owns the `newline=''` round trip and the write-only-when-changed
rule; `_unquote` owns the one-quote-pair strip both needed; each syncer is now its
own per-line decision and nothing else. Outside the build closure, so it was safe
to cut, and `test-version-snapshot.sh` gained a `--write` case: the second run
must repair nothing and must not even touch the file's mtime.

**JUDGED, not changed — the host-compiler-preference family.** Per-consumer, the
way the `gstreamer-env`↔`libcamera-env` question was answered: `build-ffmpeg.sh`
reaches the canonical helper only through `media_common_init`'s
`source_module compiler-resolution.sh || true`, which tolerates an absent module,
so `ffmpeg-probe-framework.sh`'s inline ladder is **live** on a host checkout;
`Dockerfile.android:96` COPYs the canonical file into `/opt/scripts/core`, so the
preamble's fallback is **dead in the image** and live only on a host checkout.
KEEP both — a fallback that duplicates the thing it stands in for is not a copy,
it is a fallback, and deleting one is a build-closure edit no gate can prove.

**JUDGED — `prune-safe.sh` ↔ `disk-guard.sh` has no owner available.**
`prune-safe.sh` runs `main` on load and therefore cannot be sourced; extracting
the shared `buildctl prune` command means restructuring a host-config script
operators run by hand. The `x1000` half is no longer a guess: `buildctl prune
--help` documents `--keep-storage` in MB.

**The unsuppression cascade is now recorded three times.** Every extraction that
takes a block from more than six owners to fewer reveals pairs that were never
findings — the log-bootstrap extraction (2026-09-04), the ORT summary
(2026-09-05), and DISK3's `_disk_guard_lever_ready` (2026-09-07, five budgets
re-measured). The honest response is to read and record them, never to widen
`MAX_OWNERS`.

### F1/F2 sub-items. CLOSED — the closure history the OPEN file kept carrying [done 2026-09-07]

Eight blocks, 78 of the OPEN file's 479 lines, all of them records of work that
was already finished. The file's own first rule is *"Every item here is OPEN."*
They are moved here verbatim; each left a one-line pointer behind.

**Closed 2026-09-05, and both allow rows DELETED rather than re-baselined:**
`verify_doc_dupes.py main` 81 → 47 lines, cc 23 → under the limit, decomposed into
`_index_paragraphs` / `_collect_shared` / `_print_report` / `_print_findings` /
`_print_bookkeeping` — mirroring `verify_code_dupes.py`'s helper names rather than
inventing a second vocabulary, and proven BYTE-IDENTICAL over the whole docs tree in
all four output shapes (`--report` at thresholds 8, 12 and 20 plus the plain run,
i.e. the findings, clean and stale-allowlist exit paths). And
`slang_compile_combined_wgsl` 87 → 45, with the `while read` body now
`_slang_emit_one_wgsl` returning 0 copied / 1 emit failed / 2 rejected by the
varying validator / **3 source absent** — a fourth outcome the entry had not counted.
Its `dead-functions.allow` row for `slang_compile_main` went stale in the same change
and is gone, because the new suite drives the real entry point. The suite is a true
characterisation: it passes UNCHANGED against `git show HEAD:…/slang-compile.sh`.

**Closed 2026-09-04:** `cmake_build_parse_args` 116 → 60 lines and cc 31 → 24 (the
Vulkan flag > env > caller-default chain is now `_cmake_build_resolve_vulkan`, with
its precedence written up in
[`shared-script-libraries.md`](shared-script-libraries.md) and three mutations
holding it); `verify_package_names.py` `main` 140 → 30 and `scan_file` 93 → 7, both
from **cc 42** to gone, with `--list` output over the whole tree proven
byte-identical before and after.

**CLOSED 2026-09-05 — `smoke-cross-all-arches.sh main`**, which this entry had
nominated as the best-shaped candidate left. 96 → 22 lines, cc 23 → under the limit,
four `_smoke_probe_*` helpers plus `_smoke_clang_match_arch`, and **both** allow rows
DELETED rather than re-baselined. Two things from how it went are worth keeping. The
output was proven **byte-identical to HEAD, with equal exit codes, over 20 input
shapes** — five arch-list forms and five clang triples × three arch lists — which is
what a characterisation of a shipped probe should look like. And the clang section's
"matches none of" branch, the one this entry asked for, **did not exist at all**: a
target clang built for the wrong arch shipped green. Pinning it meant writing the arm
first. `SMOKE_TARGET_CLANG` exists so a host suite can drive the real probe instead of
a rewritten copy; it self-defaults in the script, so nothing in the image sets it and
the env-knob registry needs no row.

**CLOSED 2026-09-07 — the registry-cache drop is characterised.** Every earlier
version of this paragraph said "Nothing covers it" and offered
`grep -rn DeadlineExceeded linux/scripts/tests/` returning nothing as the proof.
That grep returns **three** hits today and has since `d7fbfd39`, which landed in the
same wave as the grooming that re-asserted the claim — the entry outlived its own
evidence by one commit. `test-cross-stage-build-cmd.sh` now drives the path with a
real `_FLAKE` tail and pins the four decisions that matter: one hiccup does NOT drop
the tier, the SECOND drops it from every later attempt, the LOCAL tier survives the
drop, and a flake-free failure keeps the registry cache throughout. What is left is
only the optional extraction of that block into a named helper — with the suite as
the safety net, which is the order this entry always asked for.

**CLOSED 2026-09-07 — the harness now catches that trap.** `t_assert_ok` and
`t_assert_fails` take a COMMAND and no message, so `t_assert_fails test -f X "msg"`
ran `test -f X msg`, which exits **2** — "not zero", i.e. the failure the case
asked for, for entirely the wrong reason. Four of those were written and caught by
review in one wave. Both assertions now share `_t_assert_run`, which fails the case
BY NAME when the command is `test`/`[` and the rc is 2. The guard is deliberately
narrow: a real command that exits 2 is still judged on its exit code, and a
mutation widening it to every rc 2 is caught. `test-harness-guards.sh` is the suite
(12 assertions), and the whole corpus was re-run against the stricter harness —
no existing case relied on the old behaviour.

**`_chain_stage_disk_guard`'s two eviction loops CLOSED 2026-09-07** with DISK3:
one `_chain_evict_slugs` owner, cc 30 → 21.

The split itself was deliberately NOT made in the same wave: a second lane held the
file that session (a `trailing-conditional` fix inside `invoke_agent`'s retry loop),
and a two-file split would have destroyed their edit on merge. The seam is clean and
the next pass is a straight move — adapters (`load_engine_config`,
`agent_timeout_for_role`, `agent_stream_passthrough`, `claude_stream_render`,
`invoke_opencode`, `invoke_claude`, `usage_limit_wait_seconds`, `invoke_agent`;
roughly lines 89–420) into `lib/agentic-engines.sh`, sourced the way
`lib/log-bootstrap.sh` already is, leaving the loop driver from line 423 on. The new
suite covers both halves across the seam. **DONE 2026-09-05** — the split landed
exactly as described (874 → 512 plus a 355-line `lib/agentic-engines.sh`), the
`file-size.allow` row was DELETED rather than re-baselined, and the 24 pre-existing
assertions passed unchanged across the seam, which is what makes it a true
characterisation. The `&&`-shape defect found in this file while writing that suite
closed with CL7; note its correction, though — the failure mode did NOT reproduce,
because bash exempts every command of an AND-OR list but the last.

**Closed 2026-09-05:** `docs/scripts/sync_versions.py` had NO module docstring at all
— shebang straight into `from __future__` — despite being the authority for the
version-propagation ritual. It now states its six consumers, why `--write` does the
Dockerfiles FIRST (the snapshot reads its numbers back out of them, so the other
order needs two passes), and that a malformed marker fails BOTH modes; it ends at
`cross-build-verification.md#pre-flight`, which is where the `version-snapshot` slug
is actually documented — the honest anchor the row said did not exist. Its
`file-size.allow` row moved 849 → 873. The not-a-split verdict above it is unchanged.

### EX1. CLOSED — the extent gates can see `linux/llm-stack` now [done 2026-09-07]

**`verify_code_size.py:38` reads `SCAN = ("linux/scripts", "linux/host-config",
"docs/scripts")`**, and `verify_code_complexity.py`, `verify_dead_functions.py` and
`verify_trailing_conditional.py` all take their scope from it. `linux/llm-stack` is
not in that tuple and never has been. It holds **43 Python files, 19,874 lines**, it
is under active development, and a 569-line file (`nas_census.py`) landed there on
2026-09-07 without any extent gate seeing it.

What is actually over the limits there, measured 2026-09-07 and frozen nowhere:

| | count | worst |
| --- | --- | --- |
| files > 800 lines | 7 | `bench_coding.py` **2022** — second-largest .py/.sh in the repo |
| functions > 80 lines | 13 | — |
| `cc` > 15 | 25 | — |
| nesting > 5 | 1 | depth **8** |

`bench_coding.py` at 2022 lines is longer than every file in `file-size.allow` except
`smoke-runtime-image.sh`, and unlike that one it has never been reviewed for a
split-or-not verdict. **This is why F1's "no outside-the-closure candidate left" was
wrong in a second way**: the sweep was true of the scan set, and the scan set is not
the repo.

**What closes it is a decision, not a patch.** Adding one directory to `SCAN` makes
~46 rows appear at once, and this repo's convention — set on 2026-09-03, when wave 2
replaced every bare baseline with a verdict — is that an allow row states *what its
number IS*, not merely that it was there when the gate was switched on. Writing 46
honest verdicts over a benchmark harness nobody has reviewed for shape is its own
wave. The options, in the order I would take them:

1. **Widen `SCAN` and do the verdict pass.** Correct, and the only option that makes
   the register mean what it says. Costs one wave.
2. **Widen `SCAN` for files only** (the 7-row table above), leaving functions and cc
   for later. Cheap, and it catches the growth that matters most.
3. **Declare `linux/llm-stack` deliberately out of scope** and say so in
   `verify_code_size.py`'s header and in F2 — defensible if the benchmark harness is
   held to a different standard than the build closure, but it must be *written down*,
   because right now the exclusion is silent and reads as an oversight.

Not option 4: leaving it. A gate whose scope nobody stated is the shape this repo
has been bitten by twice — the `file-size.allow` header that said "Shell files" while
scanning Python, and the doc-links floor that only applied when git was absent.
[`code-quality-tooling.md`](code-quality-tooling.md#code-size--functions-and-files-code-size)

**CLOSED the same day it was opened, with option 1.** `SCAN` in
`verify_code_size.py:38` now carries `linux/llm-stack`, and `verify_code_complexity.py`
inherits it. (`verify_dead_functions.py` and `verify_trailing_conditional.py` also
import from that module but only walk SHELL functions, so they gained nothing;
`verify_comment_size.py` has its own scan and is untouched — that widening is still
the separate job F1 describes.)

**All 47 rows were read and given a verdict in the same wave**, which is the rule this
repo set on 2026-09-03: a row states what its number IS. **34 of them say DEBT and name
their seam** — that is the honest state of a benchmark harness nobody had reviewed for
shape, and it is now written down instead of invisible. The gates moved
28 → **41** functions, 11 → **18** files, 61 → **86** cc and 2 → **4** nesting, every
one frozen, and both gates pass.

The biggest finds, each with a seam a stranger could act on: `bench_coding.py` (2053
lines, ~976 of them executable after blanks, comments, docstrings and 409 lines of
top-level literal come out) splits at `run_candidate` into a grader half and a driver
half that touch at exactly four names; `evaluate` (227 lines, cc 69) is one-attempt +
aggregation + report dict in one body, and the two-space indent on its inner `for`
shows the author had already made the cut mentally; `benchmark_chat` carries the
repo's only nesting-8 path. Those are F1/F2 entries now, not unknowns.

