# Build watch list — the 2026-09-05 wave, read against a running chain

Follow this while the chain runs. Every row names the **exact** line that means the
change worked and the **exact** line that means it did not. Grouped by stage, in the
order a chain reaches them, so it can be read top-to-bottom live.

The wave that produced this list closed eleven backlog entries on **static** proof
only. A first rebuild attempt already found two build-killing bugs that a full green
battery had passed (HEAD `e109f5ad`), so treat every "expected" below as a
hypothesis the chain is testing, not a fact.

Chain in flight when this page was written: `chain-status.json` run
`20260905-120554-7b7a0d4e`, `sdk..runtime`, `amd64,arm64,riscv64`.

## Read this first: the three that abort a run

If the chain dies early, it is almost certainly one of these. Each fails **fast**, at
its own stage, rather than shipping — which is the design, but it is still a dead run.

| # | grep for | stage | what it means |
|---|---|---|---|
| 1 | `media_compiler_launcher: command not found` | media | the image's `03-media/core/common.sh` is an **older layer** than `build-ffmpeg.sh`/`build-pyav.sh`, which now call the new helper unqualified under `set -e`. A cache-layering problem, not a wiring one — all three files ship in the same commit |
| 2 | any path printed after `still resolves to nothing` | sdk (all 3 arches) | `_llvm_target_repair_links` ends in `find <prefix> -xtype l` and exits 1 on any survivor. It has never run on any arch. The likely cause is a **materialised directory carrying a broken link of its own** — the one path the loop cannot reach |
| 3 | `ERROR` from `prune-vulkan-host-sdk.sh` | package (`artifact-source`) | a NEW `RUN` with two bind mounts. Fails before any COPY, so it costs minutes, not hours |

## SDK stage

### Vulkan: the source tree dies where it is born (HT5)

| verdict | line |
|---|---|
| PASS | `Vulkan cross-targets <arch>: N/N component(s) built` **immediately followed by** `Pruning the Vulkan SDK build tree at /opt/vulkan/<ver>/source` |
| FAIL | the prune line appearing **before** the component verdict — that order deletes the loader/SPIRV-Tools/glslang sources out from under the build |
| FAIL | no prune line at all on arm64/riscv64 — the foreign lanes then carry 4.09 GB of `./vulkansdk` build tree into every downstream image |
| n/a | amd64 prints neither; it never takes the cross path and has no `source/` |

### Vulkan: fifteen components cross-built for the first time (VK1)

**The arm64 lane of this run has already answered this**, and the answer is backlog
**VK2**: eleven of fifteen built, including the three that matter for building an
application — `glslc`, `vulkaninfo` and the validation layers. Use that as the
baseline for the riscv64 lane rather than the pre-run guesses.

| verdict | line |
|---|---|
| PASS (measured on arm64) | `Cross-building <label> for <arch>` with no following `unavailable` line, for eleven of: `vulkan-headers`, `spirv-headers`, `vulkan-utility-libraries`, `volk`, `vma`, `spirv-cross`, `spirv-reflect`, `shaderc`, `vulkan-tools`, `vulkan-extensionlayer`, `vulkan-validationlayers` |
| KNOWN FAIL, two-row fix | `vulkan-profiles unavailable` — `find_package(valijson)` finds nothing. valijson and jsoncpp are header-only and ALREADY in the SDK's `source/` tree; they just have no row before `vulkan-profiles` in `_VK_TARGET_COMPONENTS` |
| KNOWN FAIL, real work | `gfxreconstruct unavailable` — `Could NOT find OpenGL / JsonCpp / X11` in OpenXR-SDK's `presentation.cmake`. The X11/GL dev packages `vulkan.sh` installs are HOST packages; the cross build wants the `:${arch}` set in the sysroot. Fixing it would also let `vkcube` link for the target |
| EXPECTED FAIL | `slang unavailable` (host LLVM `tblgen`, i.e. Canadian-cross) and `vulkancapsviewer unavailable` (Qt for the target). Attempted on purpose so the log reports what is true instead of a comment asserting it |
| FAIL | `shaderc: source missing at …/shaderc/src; skipping` — the checkout IS one level down and `_vulkan_target_src` is supposed to find it. It built on arm64, so this would be a regression |
| FAIL | any `Cross-building` line naming a `-B TMP/<label>` path for a component whose source is absent — the missing-source guard has stopped skipping |

**Do not "fix" the two cheap rows while the chain is running.** arm64 is already built
and riscv64 has not started; editing `vulkan.sh` now ships two arches from different
sources, which is the mid-run drift this repo has been bitten by before.

### LLVM target prefix (HT4)

| verdict | line |
|---|---|
| PASS | the stage completes with no output at all from `_llvm_target_repair_links` on arm64/riscv64 (both measured 0 dangling today, so **any** output there is news) |
| PASS | amd64 prints `amd64 /opt/llvm-target NEEDED walk clean` and **not** `is NOT self-contained` |
| FAIL | `still resolves to nothing` plus a path list — see #2 above |
| FAIL | the walk aborting on an unresolved `liblldb` soname. `liblldb*` joined the LLVM family this wave, so an apt set that ships the lldb binaries without the lib now stops the stage where it used to fall through |

### sccache — the YB verdict, and it is finally greppable (YB)

The launcher used to print its `[server=]` field **only when sccache failed**, so a
run where the fix worked carried no evidence. Both address setters now print it on the
healthy path, identically spelled. One grep covers the whole chain:

```
grep -o '\[server=[^]]*\]' <log> | sort | uniq -c
```

| verdict | line |
|---|---|
| PASS | every occurrence reads `[server=/tmp/sccache-<uid>.sock]` |
| FAIL | a **single** `[server=tcp:4226]` anywhere — the regression, unfixed |
| context | the two lines are `[INFO] Using sccache with SCCACHE_DIR=… (cap …) [server=…]` (`01-core/common.sh`) and `[INFO] sccache enabled: SCCACHE_DIR=…, CACHE_SIZE=… [server=…]` (`01-core/compiler-cache.sh`) |

Needs a **compile-heavy** chain. `--only runtime` emits none of these lines. Also
worth reading deliberately: `sccache --show-stats` at the START of each step should
report **0** compile requests, not another container's hundreds.

## Media stage

| what | PASS | FAIL |
|---|---|---|
| the ffmpeg/pyav launcher owner (F3) | `Using sccache` / a `--cc=<launcher>` in the ffmpeg configure line, and a **non-zero sccache hit count on the second arch** | `media_compiler_launcher: command not found` — see #1 above |
| TFLite for the GStreamer monorepo (CL6) | the monorepo configures with TFLite found on **arm64 AND riscv64**. riscv64 is the one to watch, as always | TFLite missing on either. First thing to check is whether the parent still calls all three helpers in order — `_gst_tflite_probe_flags`, `_gst_tflite_fix_pc`, `_gst_tflite_symlink_for_meson` |
| the media stage's cross assertion (CL7.3) | nothing new printed | `media_common_init: critical module(s) did not load` — the `03-media` fallback clone was deleted, so a caller without cross-env now stops here instead of limping |

## Package / runtime stage

### The Vulkan host prefix (HT5)

| verdict | line |
|---|---|
| PASS | the `artifact-source` prune runs and exits 0 before the `/opt/vulkan` COPY |
| PASS, deliberately | on amd64 the prune is a **no-op** — there `x86_64` IS the prefix the image runs |
| PASS, deliberately | on a lane whose cross Vulkan loader failed to build, the prefix is **KEPT** and the script says so loudly. The tree-arch gate will then fail that image on 61 X86-64 objects. That is the honest verdict for an image with no Vulkan of its own, and it is a **new way for a chain to go red** |
| FAIL | the script deleting anything on amd64 — that takes `VULKAN_SDK`, the loader and every host tool with it |

### absl, the defect the corrected probe found (CL1)

| verdict | line |
|---|---|
| FAIL | `copy-media-payloads: optional payload missing: /artifact-src/usr/local/include/absl` on **any** arch — the artifact image did not carry absl and the fix is inert there |
| PASS | no such line, on all three |

### Packaging (new this wave, none of it ever run)

| what | PASS | FAIL |
|---|---|---|
| AppImage runtime | `Staged AppImage runtime-<arch> (<n> bytes) from …`, once per arch | `appimagetool did not report --appimage-offset` — a WARN, non-fatal, but the runtime is not staged and consumers go back to fetching it from GitHub |
| Flatpak runtimes | seven refs installed on amd64/arm64; **skipped outright** on riscv64 (Flathub builds x86_64 and aarch64 only) | a 404 retry loop on riscv64 means the arch guard stopped working |
| web-lane toolchain | `OK: nightly channel installed with rust-src + wasm32-unknown-unknown` and two `OK: <crate> <version> installed` | `WARN: the nightly channel is unavailable` — non-fatal, but the web lane then auto-installs it per consumer run, which is the cost this exists to remove |

## On the shipped bytes — after the run, not from the log

This is the half the 2026-09-04 chain never reached, and the half where "verify the
shipped BYTES, never the push" applies.

### Sizes (CC1 has asked for this baseline twice)

Today's reading is **30.37 / 30.84 / 29.69 GB** (amd64/arm64/riscv64), verified
against `nerdctl images`. HT5 removes ~5.95 GB from each foreign image; VK1 adds an
unknown amount back by cross-building fifteen more components. **Read the two
together or neither number means anything.** Record all three.

| expected | `/opt/vulkan` ~60 MB on arm64 and ~88 MB on riscv64 instead of 6.0 GB; amd64 byte-identical; the `cross-android-*` artifact images ~3.9 GB lighter on the two foreign lanes |

### Probes to run, read-only

```
# HT4 — was 12 / 0 / 0
find /usr/local/llvm-target -xtype l                      # must be 0 on all three
/usr/local/llvm-target/bin/lldb --version                 # works (fails today)
python -c 'import lldb'                                   # imports (fails today)
readlink /usr/local/llvm-target/lib/libclang.so           # = libclang-23.so.23
test -f /usr/local/llvm-target/include/llvm/IR/IRBuilder.h
ls /usr/local/llvm-target/lib/libc++*                     # must be EMPTY
# the unstartable-binary count: 3-of-142 -> 0-of-142

# HT5 — the gate was SHARPENED, not loosened
#   check_manifest_tree_arch now walks the WHOLE /opt/vulkan tree
#   expect: "OK /opt/vulkan: N ELF object(s), all AArch64"  (all X86-64 on amd64)
#   a FAIL naming 1 317 X86-64 objects means the prune did not run
#   check_vulkan_loader now asserts WHERE the loader loaded from:
#     "loads from /opt/vulkan/<ver>/<arch>/lib/..."     = PASS
#     a FAIL naming /usr/lib/<triple>                   = the prune took the prefix
#                                                         the image actually runs
#     a WARN naming no path                             = /proc/self/maps unreadable,
#                                                         not a defect

# CC1 — a REGRESSION watch, not a discovery: all three read 0 today
find /usr/local/rustup /usr/local/cargo ! -user 1001      # must stay 0
find /opt/flutter -user root                              # must stay 0
nerdctl image inspect … | jq .Config.Env                  # the ENV strings must be BAKED

# CL1 / absl — 1 FAIL today, must be 0
nerdctl run --rm --platform linux/<arch> -v <repo>:/repo:ro --entrypoint bash \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-<arch> \
  /repo/linux/scripts/06-packaging/smoke-critical-fixes.sh
#   expect: PASS absl/types/span.h found in /usr/local/include

# AB1 — 420 objects, every one X86-64, on today's bytes
#   check_android_abi must report the payload matching the advertised ABI,
#   reading .a MEMBERS as well as .so files
```

### What only the runtime smoke can say

`check_consumer_contract` asserts 9 rows and has **only ever run on amd64** — the
2026-09-04 chain died before arm64 and riscv64. Same for the advertised-key gate's 16
`OK`s with zero UNSET/UNREAD. Two green foreign verdicts here are new information.

## Known-good noise — do not chase these

* `VK_LAYER_PATH` is empty in every running image and always has been. The entrypoint
  sources LunarG's `setup-env.sh`, which UNSETS it and exports `VK_ADD_LAYER_PATH`
  instead. Not touched this wave; see backlog **R1**.
* The lib-dynload audit WARNs for five optional modules (`_zstd`, `readline`,
  `_curses`, `_uuid`, `_decimal`). Information on `optional` rows — but any of them on
  **amd64** is a genuine finding.
* `slang` and `vulkancapsviewer` failing to cross-configure is expected, and is logged
  rather than asserted on purpose.
