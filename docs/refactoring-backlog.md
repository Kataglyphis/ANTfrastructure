# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md),
[`…-archive-2026-09-02.md`](refactoring-backlog-archive-2026-09-02.md),
[`…-archive-2026-09-03.md`](refactoring-backlog-archive-2026-09-03.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary (only the prefixes this OPEN file still uses): **YB**=sccache
cache loss · **CL**=build-closure follow-ups no gate can settle · **CC**=consumer-contract
defects a consuming repo reported against shipped bytes · **CS**=consumer staging ·
**VK**=the foreign-arch Vulkan SDK · **AB**=the Android layer · **R#**=residue left by a
closed entry · **F#**=size and duplication tracks.
**HT** and **GH** are retired: HT2–HT5 and GH1–GH7 are all closed, and there is no
host-tree or gate-scope work left OPEN. **DISK** is retired (DISK1 and DISK2 closed).
**QW/TC/SMK** were retired by the 2026-09-04 waves; everything else
(**AP/TG/TS/GPU/DUP/PAR/SCC/BT/LOG/LB/C#/D#/P#/S#/XC#**) is archive-only.

Last groomed: **2026-09-05, at the integration of the six-lane wave**, with a
validating chain already in flight. Every number below was re-derived from the gate
that produces it, on the integrated tree, after the merge — not carried forward from
any lane's own report. Four figures that lanes carried forward did not survive that
re-derivation; see the corrections below.

## THIS FILE IS A BUILD-WATCH LIST, AND THE BUILD IS RUNNING

Read this before anything else. **A validating chain is in flight right now** —
`chain-status.json` run `20260905-120554-7b7a0d4e`, `sdk..runtime`, all three arches.
It is the first chain since the 2026-09-04 `--only runtime` run, and that run FAILED
(`=== Results: 5 failure(s) ===` / `[ERROR] runtime stage failed`, so the arm64 and
riscv64 runtime smokes never ran at all). Everything below that says "unproven by any
build" is asking a question this run answers. The exact log lines to read, grouped by
stage, are in **[`build-watch-list.md`](build-watch-list.md)** — that page, not this
one, is what to have open while the chain runs.

**A first rebuild attempt already found two build-killing bugs** (HEAD `e109f5ad`),
which is the honest measure of what static proof is worth: a `_llvm_target_repair_links`
self-link that relinked a file onto its own path, and a Vulkan defect in the same
class. Both were found by a chain in minutes after surviving a full green battery.
Assume the running chain will find more, and read the watch list rather than trusting
this file.

**The 2026-09-05 integration wave closed eleven entries and folded three lanes'
concurrent work in.** Gone entirely, and living in git history rather than here:
**CL6** (the `_gst_monorepo_tflite_flags` split, three named helpers with the bodies
moved verbatim), **CL7** (all three — the inline-TOML `_uv_conflict_groups` walk, the
`agentic-engines.sh` `&&` shape, and the unreachable `03-media` `cross_build_is_active`
clone), **GH5** (both frozen slugs left the freeze; `gate-proofs.allow`'s bare-slug
namespace is EMPTY for the first time), **GH6** (the deep half closed as a real gate
arm, `unlinked()`, which found `verify-parity.sh check_python`), **GH7** (the header-pointer
allow file ratcheted 45 rows → 8, with nine durable doc sections written to absorb the
re-points), **HT4** (twelve dangling `/opt/llvm-target` dev symlinks on amd64, and the
3-of-142 unstartable binaries `liblldb` was hiding), **HT5** (5.7 GB of builder-arch
Vulkan payload per foreign image, removed at both the SDK and packaging boundaries),
and **F1/F2/F3's named rows** (`smoke-cross-all-arches.sh main`, the
`lib/agentic-loop.sh` split, and the ffmpeg↔pyav launcher twin).

**Four numbers in the closed entries did not survive re-measurement, and the
corrections are the point.** HT4 said nine dangling links; there are **twelve**, and
"in the builder they resolve" was false — nineteen are already broken in
`cross-android-amd64`. HT5's share-of-image was 18.5 %/19.2 %; measured against
nerdctl's decimal GB it is **19.5 %/20.3 %**. CL7.2's stated failure mode does **not
reproduce** — bash exempts every command of an AND-OR list but the last, so the shape
was fixed and the entry corrected rather than closed as a bug. And CC1's ownership
half was **already green on today's bytes** on all three arches, which makes it a
regression watch, not a discovery. Re-measure before you trust a number in here.

**Where the gates stand on the integrated tree** (every reading re-derived from the
gate itself on 2026-09-05 after integration, not carried forward):

| gate | reading |
|---|---|
| `mutations` | **630** entries over **74** distinct test commands, every one proven to bite, none vacuous, none stale |
| `gate-registry` | **34** slugs; **34** proven; **0** unproven, **0** frozen — the bare-slug namespace is empty; 279 ids in 31 declared families |
| `script-tests` | **100** suites, **3322** assertions |
| `preflight` | **45** checks, rc 0. Wall clock **14 m 46 s** — but that was measured with a 3-arch chain compiling on the same box, so it is not comparable to the 10 m 31 s baseline; re-time it on an idle host before reading anything into it |
| `code-size` | 29 functions over 80 lines, 11 files over 800 — all frozen, all with a verdict |
| `code-complexity` | 66 `cc` over 15, 2 `nesting` over 5 — all frozen, all with a verdict |
| `shellcheck-warnings` | **88** findings over a **348**-file scope — all frozen, all with a verdict |
| `code-dupes` | 3706 units in 380 files, **248** allowlisted pairs, 852 shingles suppressed as idiom |
| `dead-functions` / `trailing-conditional` / `comment-size` / `masked-assignments` | 30 / 32 / 169 / 46 frozen |
| `doc-links` | 73 pages, **507** code pointers, **8** bare header pointers frozen (was 45) |

**Eleven entries remain** (`grep -c '^### '` counts thirteen; "Next up" and "What
needs the OWNER" are not entries), and they divide cleanly: **CC1, CL1, VK1, AB1 and
YB are watch lists** that the running chain either closes or re-opens with evidence;
**VK2** is the first entry this wave produced from REAL build evidence rather than
static proof, and two of its four items are a two-row fix; **CS1** has one open owner
decision; **R1** is the named residue of the eleven that closed; **F1/F2/F3** are
tracks, not defects.

**VK2 is the shape to notice.** The chain had been running for well under an hour when
it produced a better-grounded entry than anything eleven lanes of static analysis
managed: eleven of fifteen target components built, four did not, and the log said
exactly why for each. That is the argument for reading
[`build-watch-list.md`](build-watch-list.md) rather than this page.

**What the integration wave itself had to fix, because it is the pattern to expect
next time.** Three lanes landed behaviour changes with no suite case and no mutation
— the Vulkan `_VK_TARGET_COMPONENTS` table and its two helpers, the Android ABI
mapper's doc anchors, and the whole packaging set (AppImage runtime staging, the seven
Flatpak refs, the web-lane toolchain). One of them, `ensure_appimagetool_runtime`, was
written and documented but **never called from anywhere**. The integration added 20
mutations and 40 assertions to cover them, wired the dead function into both of
`ensure_appimagetool`'s success paths, and wrote the five doc sections their pointers
already named. A lane that ships a function without a caller ships nothing; the
`dead-functions` gate is what caught it, and it caught it only because the wave ran
the full battery after the merge rather than trusting each lane's own green.

### Next up — the running chain decides most of this

1. **Read the chain against [`build-watch-list.md`](build-watch-list.md)** [S, ★★★].
   Not a code change, and it is the only thing that can move this file. Five of the
   eight remaining entries (CC1, CL1, VK1, AB1, YB) are watch lists that close or
   re-open on this one run. The watch list is grouped by stage with the exact lines
   that mean PASS and the exact lines that mean FAIL, so it can be followed live.
   YB and VK1 are answered in the **sdk and media** stages, CC1 and AB1 only in the
   **package/runtime** stage and then on the shipped bytes.
2. **Record the three per-arch image sizes from this run** [S, ★★]. CC1 has asked
   for this at two consecutive groomings and there is still no in-tree baseline. The
   expected reading, after HT5, is roughly **24.9 / 23.7 GB** on arm64/riscv64 against
   an unchanged **30.37 GB** on amd64 — but VK1's fifteen new cross-built components
   push the target prefix back up by an unknown amount, so the two changes have to be
   read together or neither number means anything.
3. **CS1's one open owner decision** [S, ★★]. `prune-vulkan-host-sdk.sh` ships wired
   but the owner has twice said not to remove Vulkan payload. Note the coupling before
   deciding: the tree-arch gate was un-narrowed to assert the WHOLE `/opt/vulkan` tree,
   and that only holds while the prune runs. Keeping `x86_64/` means re-narrowing the
   gate and giving back the 1.86 GB.
4. **VK2's two cheap rows** [S, ★★]. `valijson` and `jsoncpp` are header-only, are
   ALREADY in the SDK's own `source/` tree, and simply have no row of their own before
   `vulkan-profiles` in `_VK_TARGET_COMPONENTS`. Two table rows. The other two items
   (`gfxreconstruct` needs the `:${arch}` X11/GL dev set in the sysroot; `slang` and
   `vulkanCapsViewer` are Canadian-cross and Qt-for-target respectively) are real work
   or deliberate declines. **Do not touch `vulkan.sh` while the chain is running** —
   the arm64 lane is already built and riscv64 has not started, and two arches built
   from different sources is the mid-run drift this repo has been bitten by before.
5. **The residue the closed entries left, all small and all named** [S each, ★]:
   the runtime-side `ldd` gate over `/usr/local/llvm-target/bin/*` (HT4's structural
   half — the builder's ldconfig cache is what let `liblldb` through, and only an
   in-image check catches the next one); `VK_LAYER_PATH` dangling on all three shipped
   images and always having done so; LOG14's cross-lane skip list claiming a ~390 s/lane
   saving the shipped bytes contradict; and GH6's 93 remaining masked rows, which are a
   watch list and not a fix.
6. **F1 / F2 / F3 — the size and duplication tracks** [M–L each]. None is a defect.
   With `smoke-cross-all-arches.sh main`, the `agentic-loop.sh` split and the
   ffmpeg↔pyav twin all closed, what is left inside the build closure is the
   `_cross_stage_build_impl` registry-cache drop (still uncovered — `grep -rn
   DeadlineExceeded linux/scripts/tests/` returns nothing), five cc rows, and three
   clone families.

**Honesty about the rest:** after this wave there is no OPEN entry naming a defect
with a known failure mode. Everything here is a watch, an owner decision, or a track.
That is a good state to be in only if the chain is actually read.

### What needs the OWNER, not the agent

Nothing in the entries below is blocked on you. These are:

1. **`git push`** — re-derive the count with
   `git rev-list --count origin/main..HEAD` rather than retyping a number; it was
   wrong at three consecutive groomings before that command was written down. The
   pre-push hook is NEW this wave and has never been invoked by a real `git push`;
   it runs a whole-manifest `--stale-check` (0.06 s) and then the mutation gate over
   `--changed`. `--no-verify` is the documented bypass if it surprises you.
2. **Downstream consumers of `linux/scripts/lib/`.** The nine libraries source a
   sibling, `lib/log-bootstrap.sh`. Any full ContainerHub checkout satisfies that —
   which is how [`adopting-in-a-new-project.md`](adopting-in-a-new-project.md) says
   to consume them — but a consumer that copied ONE `lib/*.sh` file out on its own
   breaks on its next CI run, not here.
3. **`06-packaging/package_archive.sh` — does it have a consumer?** Nothing in this
   repo invokes it and no Dockerfile copies it, so no build will ever answer
   anything about it. `ResolvedBinary` is provably dead, but `--appdata-file`,
   `--app-id` and `--appimage-extract-and-run` are a CLI CONTRACT whose only possible
   callers live outside this repo: dropping the flags turns a silent no-op into
   `Unknown argument` plus a mis-shifted operand. If no external consumer exists,
   delete the script. Its `shellcheck-warnings.allow` row stays at 4 until someone
   answers.
4. **The Windows lane.** Six confirmed doc defects from the 2026-09-03 currency
   audit are parked in
   [`windows-refactor-backlog.md`](windows-refactor-backlog.md), verified against
   the tree only. Three of the six are wrong paths a reader would follow into a
   "file not found" (`verify-host-setup.ps1`, `healthcheck.ps1`,
   `Dockerfile.toolchain`); the fourth is the QNN version contradiction at
   `README.md:204`. Also unresolved:
   `windows/scripts/tests/Pins.CanonicalValues.Tests.ps1` reads `CUDA_ARCHITECTURES`
   from `versions.env` via `Get-Pin` and asserts `80;86;89;90`, and that value is now
   QUOTED (it had to be — an unquoted `;` ran its own tail as commands on every plain
   `source`). `load_versions_env`, `sync_versions.py` and `bump_versions.py` all strip
   one surrounding pair and were proven byte-identical; whether `Get-Pin` does was not
   testable from this host. One PowerShell run answers it.
5. **A newer QNN SDK, if you want one.** v2.49.0.260730 is pinned, hashed and
   validated end to end. Only a *newer* SDK needs a re-pin, and only you can fetch
   it (login-gated).

### CC1. The consumer-contract fixes are static until the next runtime build [S to watch, ★★★]

**Evidence: a consuming repo's CI lane, not a gate.** The
Kataglyphis-Inference-Engine lane ran against `:latest-cross-amd64` as uid 1001 on
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

### CL1. Closure files that changed SHAPE with static proof only [S to watch, ★★★]

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
| `01-core/common.sh` | NEW `compiler_cache_launcher_env`, and 13 call sites in 11 files call it before resolving the launcher | see YB. Every `sccache-launcher` line must print `[server=/tmp/sccache-<uid>.sock]` and never `[server=tcp:4226]` |
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

### VK1. Every SDK component is now cross-built, and none of it is proven [M, ★★★]

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

### AB1. The Android layer was built for the build host, not for a phone [M, ★★★]

Reported by the Kataglyphis-Inference-Engine android lane 2026-09-05, as a link
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

### VK2. Close the last four — none of them is actually a wall [M, ★★★]

Measured on the arm64 lane of the 2026-09-05 rebuild: **20 native tools in
`aarch64/bin`, up from 2**, including `glslc`, `vulkaninfo`, `vkcube`, the whole
`spirv-*` family and four validation-layer manifests. Four components did not
cross-build. Each has a route, and two of them are trivial. **This entry is closed
only when `<arch>/bin` carries everything `x86_64/bin` does that is not
structurally host-only.**

**1. `vulkan-profiles` — two table rows. [S]**
`find_package(valijson)` found nothing. `valijson` and `jsoncpp` are ALREADY in
the SDK's own `source/` tree; they simply have no row of their own in
`_VK_TARGET_COMPONENTS` ahead of the components that need them. valijson is
header-only. Add both rows before `vulkan-profiles` and `gfxreconstruct`.

**2. `gfxreconstruct` — the dev packages are the host's, not the target's. [S/M]**
`Could NOT find OpenGL / JsonCpp / X11`, aborting in OpenXR-SDK's
`presentation.cmake`. `vulkan.sh` installs `libx11-dev`, `libxcb*-dev`,
`libwayland-dev` and friends for the BUILD HOST only. The cross build needs the
same set as `:${arch}` in the sysroot. The same packages would also let `vkcube`'s
WSI backends link everywhere, so this one fix pays twice.

**3. `slang` and the `dx*` family — this repo already solves this exact problem. [M]**
Both are LLVM-shaped: their build runs generators (tablegen and slang's own
`slang-generate`/`slang-cpp-extractor`) that must EXECUTE on the build host while
the rest cross-compiles. That is a Canadian cross, and
`linux/scripts/02-toolchain/llvm-cross.sh` has been doing it for the target-clang
build all along:

```
-DCLANG_TABLEGEN="${native_tool_dir}/clang-tblgen"   # llvm-cross.sh:202
-DLLVM_TABLEGEN="${native_tool_dir}/llvm-tblgen"     # llvm-cross.sh:264
```

with `llvm_host_native_tool_dir()` (llvm.sh:370) resolving the host tools. The
host `./vulkansdk` build ALREADY produces host `slang`, `slangc` and the `dx*`
binaries in `x86_64/bin` — so the generators exist on disk before the cross build
starts. Point slang's cross configure at them the way llvm-cross.sh points at
tblgen, and add `dxc` as its own row using the same `native_tool_dir`. "Host-only
component" was a description of the failure, not a property of the software.

**4. `vulkanCapsViewer` — Qt, or its CLI. [M]**
Needs Qt for the target. Two routes: install `qt6-base-dev:${arch}` into the
sysroot alongside (2), or build the command-line variant, which is the useful half
in a container anyway — a GUI caps viewer has no display to open there.

Order by value per hour: (1), then (2) because it also fixes `vkcube`'s WSI, then
(3) because it is a known pattern rather than new work, then (4).

Not fixed during the run that found them, on purpose: arm64 was built and riscv64
had not started, and editing `vulkan.sh` there would have shipped two arches from
different sources. docs/vulkan-foreign-arch-sdk.md

### VK3. Ratchet the target Vulkan SDK so it can never shrink again [S, ★★★]

Owner's request, 2026-09-05: the foreign-arch SDK must keep being built for every
arch the way it is now. It shipped 2 tools for months precisely because nothing
asserted a NUMBER — `check_vulkan_toolset` requires six
(`glslangValidator` + five `spirv-*`) and merely WARNs about the rest, which was
the right conservatism while the fifteen cross-builds were unproven. They are
proven now, on the shipped bytes of both foreign lanes:

```
aarch64/bin  20 tools, 4 layer manifests   (glslc, vulkaninfo, vkcube b7)
riscv64/bin  20 tools, 4 layer manifests   (glslc f3)
x86_64/bin   52 tools                       (downloaded LunarG SDK)
```

The ratchet, in the shape this repo already uses for the shellcheck and app-wheel
counts:

1. Promote the measured 20 from `_VK_REPORTED_TOOLS` to `_VK_REQUIRED_TOOLS`. A
   WARN is invisible in a green run; that is how two-of-fifty-two survived.
2. Freeze the count PER ARCH, since amd64 legitimately carries 52 and the foreign
   pair 20 — one frozen table, the way `_RT_TREE_ARCH_FROZEN` holds its counts,
   so a lane that gains tools has to record the new floor rather than drift.
3. Require the four validation-layer manifests. Developing a Vulkan application
   without them is the thing the whole exercise was for.
4. Make `_vulkan_target_verdict` demand a minimum of the component table rather
   than only failing when EVERY component failed. Today one surviving component
   reads as success; that is an env-shaped check, not a completeness one.

Do it as its own change, after a rebuild has landed — editing the runtime smoke
while a chain is running is the mid-run drift this file keeps warning about.
Closing VK2 raises the floor again, so land VK2 first and record the new numbers
once. docs/vulkan-foreign-arch-sdk.md

### CS3. The web-lane tools cost riscv64 an hour of QEMU per rebuild [S, ★]

Measured in the 2026-09-05 runtime lane, same two `cargo install`s on each arch:

| arch | wasm-pack | flutter_rust_bridge_codegen |
| --- | --- | --- |
| amd64 | 87 s | 113 s |
| arm64 | 768 s | ~1170 s |
| riscv64 | 1813 s | 3500 s |

Roughly 9x on arm64 and 20x on riscv64 — the shape of QEMU user-mode emulation,
not a defect. They all succeed, and the point stands: a consumer that would
otherwise pay 432 crates PER RUN now pays nothing.

Worth deciding, not worth guessing: is there a riscv64 web lane? The tools are
installed uniformly because an arch-conditional image is harder to reason about
than a slower one, and because "we assumed nobody uses it" is how the Android
layer ended up x86_64-only (AB1). If a riscv64 web build is genuinely impossible
rather than merely unused, gate it on that fact and say so. Otherwise leave it.

A cheaper route for both foreign arches: install from the projects' prebuilt
release binaries where they publish aarch64/riscv64 ones, and keep `cargo install`
as the fallback. That trades an hour of emulation for a download.

### CS2. One Flatpak ref of seven has the wrong branch [S, ★]

Measured in the runtime stage of the 2026-09-05 rebuild: six of the seven refs
install, the seventh does not.

```
[INFO] Installing org.freedesktop.Platform.openh264//2.5.1
[WARN] org.freedesktop.Platform.openh264//2.5.1 did not install
[INFO] Flatpak runtime installation complete (6/7 refs)
```

`2.5.1` is the version the consumer's report printed, but that is what flatpak
DISPLAYS, not necessarily the branch it resolves. Ask flathub what exists —
`flatpak remote-ls flathub --arch=<arch> | grep openh264` — and pin
`FLATPAK_OPENH264_VERSION` to the branch it names. It is 0.9 MB of the 1.9 GB, so
the value is closing the gap rather than the bytes.

The per-ref non-fatal handling did exactly its job: one bad ref cost one ref, not
the other six and not the build. Do not change that.

### DISK3. The chain's disk guard cannot see where the disk actually went [M, ★★★]

Observed live during the 2026-09-05 rebuild, in the chain's own words:

```
[INFO] [disk-trim]     removed 0 slug(s), freed 0.0 GiB; 28G free now
[INFO] [disk-buildkit] already pruned once here -- the store is at keep-storage
[WARN] [disk-reclaim]  in-stage: NOTHING was reclaimable (28G -> 28G free)
                       -- the chain cannot free
```

It was right that it could not, and wrong that nothing was reclaimable. At that
moment `~/.local/share/containerd` held **295 GB**, including three
`cross-android-*` stage images from a PREVIOUS run at 41.5 / 41.8 / 38.0 GB. The
run had no use for them: every stage builds FROM a digest it pins and pulls, and
on rootless nerdctl a stage build does not even create a local tag (the RTCACHE3
finding). Deleting those three took 51G free to 120G in about a minute.

`disk-guard.sh` contains no `nerdctl rmi`, no `image prune`, and no image listing
at all. It knows its own log slugs and BuildKit, and BuildKit was already at
`keep-storage` — so its two levers were spent while its third, larger one was
invisible to it. The 2026-09-05 run needed FOUR manual rescues; the 2026-08-27
ENOSPC in [[rebuild-disk-management]] is the same gap, hit harder.

What to add, in this order because it is also the risk order:

1. **Dangling images.** `nerdctl image prune` (no `-a`). Zero risk, and it
   returned 20 GB on its own in this run.
   **Size is not the metric — unique layers are.** Deleting the three
   `cross-sdk-*` images (80 GB by `nerdctl images`) freed *zero* bytes, because
   every layer they hold is also held by the `cross-android-*` images built on top
   of them. The previous release's `latest-cross*` freed 113 GB from a similar
   nominal size, because its layers are nobody else's. A guard that picks the
   biggest tags will do nothing; it has to pick tags whose layers nothing else
   references.
2. **Stage images this run did not produce.** `cross-<stage>-<arch>` whose digest
   is not among the parents this run pinned. They are all on ghcr and every one is
   re-pullable; the chain already records the digests it pinned, so the comparison
   is available rather than guessed.
3. **NEVER the current run's parents**, and never `nerdctl system prune` — see
   [[rebuild-disk-management]] for why the cachemounts must survive.

There is a second, milder instance of the same blindness: the runtime lane's own
pre-flight (`runtime lane refused: 74G free, ~120G needed`) correctly refuses to
start rather than dying on ENOSPC mid-build — good — but the reclaim it runs first
reports `NOTHING was reclaimable` for the same reason. The refusal is right; the
reclaim under it is looking in one store while the space is in another.

The guard should also stop reporting `NOTHING was reclaimable` when it has not
looked at the largest store. A guard that gives up loudly reads like an
environment limit; this one was a coverage gap.

### CS1. Consumer staging: done, with one item declined and one decision open [S, ★]

The 2026-09-05 report's remaining items, all landed except two.

**Declined, with a reason:** a warm `~/.pub-cache`. The reporter marked it optional
themselves, and its contents follow `pubspec.lock` — an image-baked cache is stale
for any consumer whose lock differs, which is every consumer that is not this one.
Staging it would trade a real download for a silent wrong-version risk. `flutter
pub get` stays a per-run cost.

**Open, and it is the owner's call:** `prune-vulkan-host-sdk.sh` drops `x86_64/`
from the FOREIGN images only (on amd64 it is a no-op — there `x86_64` IS the
downloaded SDK). The evidence is one-sided: those 52 binaries are x86-64 ELF in the
arm64 image and exit 127. But the owner has twice said not to remove Vulkan payload,
so it ships wired and unshipped until they say otherwise. Note the coupling: the
tree-arch gate was un-narrowed to assert the WHOLE `/opt/vulkan` tree, which only
holds while the prune runs. Keeping `x86_64/` means re-narrowing that gate.

### YB. sccache: root cause FOUND and fixed, unproven by any build [S to watch, ★★★]

**This entry is no longer an investigation.** The 2026-09-05 wave found the mechanism
exactly, and every hypothesis the old entry carried (argv shape, cwd, spawn
internals, per-request server state) is refuted by the evidence. The full write-up,
the four-row table of impossible `--show-stats` counters and the regression window
are owned by
[`build-cache-tiers.md`](build-cache-tiers.md#the-server-address-must-be-exported-where-the-compiles-run).
In one paragraph:

the server ADDRESS never reached the compiles, so every client fell back to the
default TCP port 4226 and was served by another container's sccache server. It is a
REGRESSION, not a new bug — the same class was fixed by `4aa92fb6` on 2026-08-27 and
undone by the F2 one-resolver refactor `8c97cdd8` on 2026-08-30, which is what the
2026-09-01 measurement (2952 + 110 faults) actually recorded.

**Correct the old entry's arithmetic while you are here.** The 27 / 514 figure is not
a 5 % recovery rate; it is four containers each all-or-nothing. All 514
`failed twice` sit in step #24 litert (364), #34 ORT genai (100) and #45 pyav (50);
all 27 `retry succeeded` sit in #29 TVM, which has zero failures of the other kind.
Use the per-step split from `sccache-retry-20260903-150440`, not the aggregate.

**The fix, and what only a chain can confirm.** `sccache_export_server_address` is the
one owner of the address and `setup_ccache`/`setup_sccache` call it in the PARENT
shell; `compiler_cache_launcher_env` is the one owner of the same rule for the 13
`$(compiler_cache_launcher)` sites in 11 other files; `Dockerfile.toolchain` now
mounts `sccache-launcher.sh` in both per-file blocks, so the GCC/LLVM stages stop
running BARE sccache. Watch for, in a **compile-heavy** chain (media or toolchain —
`--only runtime` emits no launcher lines at all):

1. Every `sccache-launcher` line prints `[server=/tmp/sccache-<uid>.sock]` and never
   `[server=tcp:4226]`. **That single field is the whole verdict.**
   **CORRECTED 2026-09-05, and this mattered:** the launcher prints its `[server=]`
   field **only on the two sccache-FAILED paths**, so on the very run where the fix
   works the evidence and the verdict cancelled out — there would have been nothing to
   grep. Both address setters now print it on the healthy path too, identically
   spelled, so ONE grep covers the whole chain:
   `grep -o '\[server=[^]]*\]' <log> | sort | uniq -c`. The two lines are
   `[INFO] Using sccache with SCCACHE_DIR=… (cap …) [server=…]` (`01-core/common.sh`)
   and `[INFO] sccache enabled: SCCACHE_DIR=…, CACHE_SIZE=… [server=…]`
   (`01-core/compiler-cache.sh`). A single `[server=tcp:4226]` anywhere is the
   regression, unfixed.
2. The ENOENT bypass class collapses in the steps that produced it (#24, #34, #45 on
   2026-09-03) rather than merely moving.
3. `sccache --show-stats` at the START of each step reports 0 compile requests
   instead of another container's hundreds. Cheap, decisive, and worth putting in the
   log deliberately.
4. The hit rate per step is non-zero with the RIGHT cache-mount id — entries stop
   landing in a foreign arch's `/var/cache/sccache`.
5. The container-local UDS server actually starts under the tmpfs `/tmp` these RUN
   steps mount, and `sccache --version` on the riscv64/apt 0.13 fallback path still
   takes the hashed-port arm. Neither is provable statically.

**One duplication is left, it is blocked on a `Dockerfile.base` mount rather than on
judgement, and the page above owns the reasoning.** The work item is: decide whether
`compiler-cache.sh` should join `Dockerfile.base`'s six per-file `01-core` blocks. If
it should, `ensure_sccache_env`'s copy of the address block collapses onto
`sccache_export_server_address` and the pair drops out of `code-dupes.allow`. If it
should not, the second owner is permanent and the row's reason should say so.

**One thing to grep the next chain for:** `SCCACHE_DIRECT=false` is exported by
`setup_ccache` in the parent but only inside `ensure_sccache_env` on the `common.sh`
path. A server auto-started from a stage that never ran `setup_ccache` would inherit
`/etc/sccache/config.toml`'s `use_preprocessor_cache_mode = true` and bring back the
`while hashing the input file` TryCompile class. Not observed in any log read so far.

### R1. The residue the eleven closed entries left [S each, ★]

Small, named, and each one is the honest leftover of something that closed. None is a
defect with a live failure mode; all four were measured, not guessed.

1. **A runtime-side `ldd` gate over `/usr/local/llvm-target/bin/*`** — HT4's
   structural half. The sdk stage's self-containment walk checks non-LLVM `NEEDED`
   sonames against the **BUILDER's** ldconfig cache, so any soname present in the
   builder and absent in the runtime ships a binary that cannot start. `liblldb` was
   the instance (3 of amd64's 142 binaries: `lldb`, `lldb-dap`, `lldb-mcp`), and
   nothing but a runtime-side check catches the next one. The gate is ~10 lines in
   `smoke-runtime-image.sh` plus one suite case, and would read 0/142, 0/127, 0/127
   today. It was not added this wave because that file was being rewritten by two
   lanes at once.
2. **`VK_LAYER_PATH` is dangling on all three shipped images, and always was.**
   `Dockerfile.package:240` and `04-runtime/runtime-paths.env` point it at
   `/opt/vulkan/active/etc/vulkan/explicit_layer.d`, but SDK 1.4.357 puts explicit
   layers in `<arch>/share/vulkan/explicit_layer.d` and no arch prefix has an `etc/`
   at all. The entrypoint then sources LunarG's `setup-env.sh`, which UNSETS
   `VK_LAYER_PATH` and exports `VK_ADD_LAYER_PATH` instead — measured: the variable is
   **empty in every running image**. Not a size defect and not touched here: it is a
   behaviour change to a shared env file with its own gates. Note the foreign arches
   have no layers to point at either, so on arm64/riscv64 the only honest value is
   "no explicit layers".
3. **LOG14's cross-lane skip list does not do what its comment claims.**
   `vulkan.sh` skipped `vulkan-validationlayers`, `shaderc`, `spirv-cross`, `volk`,
   `vma` and friends "for foreign-arch cross builds (host-only component)" to save
   ~390 s/lane — yet the shipped foreign images carried `source/Vulkan-ValidationLayers`
   (2.0 GB), `source/shaderc` (557 MB), `source/valijson` (492 MB) and a BUILT
   `libspirv-cross-c-shared.so.0.68.0`. `./vulkansdk` fetches, and at least partly
   builds, components the skip list removed from its argv. **VK1 has since removed the
   skip list entirely**, so this is now only a question about the claimed saving —
   re-measure it against a real lane log rather than carrying the number forward.
4. **GH6's 93 undecided masked rows are a watch list, not a fix.** The `unlinked()`
   arm decides only the corner where two same-named definitions can never share a
   shell; the other 93 are almost all `tests/` stubs for a sourced unit under test,
   which is correct code no static rule should fail. One live hazard is named at the
   point of failure: any corpus file that starts naming BOTH definers' basenames
   disarms the arm and turns its frozen row STALE with a message that reads like the
   function came back to life. `tests/test-dead-functions.sh` is itself that instance
   and assembles the name and both basenames from `printf` arguments.

**Two things recorded so a future reader does not "simplify" them.** The foreign
`x86_64/` Vulkan prefix is 4.14 MB LARGER than amd64's over the same 4 399 files, so
`./vulkansdk`'s host build does overwrite part of the tarball on a cross lane — and
those host tools have a real build-time consumer (`build-opencv.sh` reads
`/opt/vulkan/<ver>/x86_64` for headers), which is exactly why HT5 prunes at the
packaging boundary and not in the SDK stage. And CL6's three TFLite helpers still leak
`dep`, `_gcc_arch` and `_gcc_dir` into the caller's scope: pre-existing, deliberately
not changed in a build window, because localising them is a real state change and the
split's whole claim is that the bodies moved verbatim.

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are fully reviewed: **29** function rows over 80 lines
and **66** `cc` rows over 15 on the 2026-09-05 integrated tree, every one carrying a
verdict that says what its number IS. Read the reasons, not the numbers.

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
holding it); `verify_package_names.py` `main` 140 → 34 and `scan_file` 93 → 7, both
from **cc 42** to 7-and-gone, with `--list` output over the whole tree proven
byte-identical before and after.

**Four measurement facts that decided most of the remaining verdicts**, and that a
future reader should not re-discover:

* **Heredoc payloads are not shell.** `assert_pinned_versions` is 44 lines of shell
  around a **312**-line embedded Python program — top of the size queue and the
  WORST candidate on it, because splitting the shell moves 44 lines and its `cc` is
  **7**. Same shape: `assert_app_venv_parity` (20 around 72),
  `_gst_xpy_write_config` (14 around 70), `ensure_meson_cross_file` (56 around a
  37-line Meson-ini template).
* **Much of the `cc` here is a TABLE, not tangle**: flag and subcommand parsers
  (`parse_tvm_args` 13 options, `append_tvm_cmake_args` 15, `setup-dependencies.sh`
  `main` 5 flags × 10 commands), feature tables (`_ffmpeg_probe_core_codecs` is
  sixteen `if probe; then --enable-<codec>` lines and nothing else), and two rows
  where the metric is simply literal — `dump_debug_info` (cc 23) contains no
  decision at all, just ~20 which-then-`--version` pairs each swallowed, and
  `_torch_run_setup_py` counts the size of torch's build environment.
* **Refusal matrices cost safety when flattened**: `_chain_prune_archived_logs`
  (every branch is a refusal to delete the wrong thing), `_manifest_wrapper_gate`
  (the cell that decides whether a manifest would MIX releases),
  `install_target_packages`, `override_soundtouch_codeberg_checksum`.
* **Precedence ladders where the ORDER is the contract**: `host_python_bin`,
  `install_abseil_headers`' five download/extract rungs, `_detect_gcc_cxxabi_header`,
  `configure_opencv_build_env`'s gstreamer-libdir search (the RV1-GST-PC ladder).

**The rows that ARE debt, named in their own reason column.** All but two are build
closure, which is why they are recorded rather than cut: `_opencv_target_adjustments`
(cc 33 — three unrelated riscv64 workarounds, seams `_ota_riscv64_freetype` /
`_ota_riscv64_png`), `_chain_stage_disk_guard` (28 — two near-identical eviction
loops wanting one `_evict_until <predicate>`), `media_common_init` (35 — a module
loader whose load ORDER is load-bearing, so a table+loop is NOT a free win),
`_cgroup_mem_remaining_mb` (20 — the same four tests twice over cgroup v1 and v2),
`_gst_rs_build_plugins` (25 — five copies of one exclusion preamble),
`build-runtime-manifest.sh` `main` (22 — five phases on one repeated
`BUILD_IMAGES -eq 1` test).

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

**With that closed there is no outside-the-closure candidate left on the size queue.**
Every remaining named row is inside the build closure.

**Two rows carry a "do not do the obvious thing" verdict.** `verify_comment_size.blocks`
(nesting 6): the honest fix is importing `verify_code_size.scan` like every other
extent gate, but that WIDENS the scan to `docs/scripts` and NARROWS it by
`SKIP_DIRS 'patches'` — it changes the gate's scope and needs a fresh
`comment-size.allow` baseline, which is different work from a nesting trim. And
`verify_package_names.load_arch` (17): every branch is a way the gate must not
produce a FALSE verdict, the all-or-nothing partial-fetch refusal above all.

**The one uncovered path left inside `_cross_stage_build_impl` is the
registry-cache drop** — lines 295–317, **23** lines. It needs a non-empty
`log_file` whose tail matches `DeadlineExceeded|httpReadSeeker`, and it mutates
both `build_cmd` and `_regcache_fails` across retry iterations. Nothing covers it:
`grep -rn DeadlineExceeded linux/scripts/tests/` returns nothing, and
`test-cross-stage-build-cmd.sh` only counts `cache-from`/`cache-to` on the
non-failing path. Write the characterisation first — fake `log_file`, assert the
counter reaches 2 and that the registry cache pairs vanish from `build_cmd` while
local cache args survive — then extract. Re-checked 2026-09-05: still uncovered.

**A harness trap worth a note before the next suite is written.** `t_assert_ok` and
`t_assert_fails` take a COMMAND and no message, so `t_assert_fails test -f X "msg"`
runs `test -f X msg` — it fails for the wrong reason and passes vacuously. Four of
those were written and caught this wave. Nothing in the harness catches it today.

### F2. Files over ~800 lines [L each, low priority]

**`file-size.allow` is the authority — do not transcribe it here.** The eleven-row
table that used to sit in this entry was wrong within a day of being written, twice.
This entry's prose then broke its own rule again on 2026-09-04 by quoting
`smoke-runtime-image.sh` at 1739 when the allow file had carried the correct number
and the reason all along. The gate prints `files: 11 over 800 lines; 11 frozen`;
read it there.

**All rows were reviewed 2026-09-04 and all but one are NOT split targets**, each with
a reason a stranger can act on. The file's own HEADER was the thing that had stopped
measuring what it claimed — it said "Shell files currently over the size limit"
while three of ten rows are `docs/scripts/*.py` and `linux/Dockerfile.media`, two of
those carrying the copy-pasted reason "newly in scope (python/Dockerfile)". Header
corrected to state `verify_code_size.py`'s actual scope.

**One row IS a real split, and it is NO LONGER BLOCKED.** `lib/agentic-loop.sh` is
two subjects wearing one name — engine adapters and the loop driver — and it is
outside the build closure, so it can be cut at any time. The blocker this entry named
("nothing covers it") is gone: `test-agentic-loop.sh` landed 2026-09-05 with **24
assertions** and six mutations, covering exactly the three cases the row asked for —
engine-config precedence, `invoke_agent`'s retry ladder with both engine adapters
faked, and one drain of the executor queue — plus the blocked-task case that pins why
blocked work is deliberately not queue depth.

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

**Two verdicts worth not re-litigating.** `build-app-wheelhouse.sh` is the
near-miss: the stage suites extract blocks from it **by line range**, so a file
split silently re-aims them. And `smoke-runtime-image.sh` — which every earlier
version of this entry nominated as THE one to split — is an explicit **NO**: 63
functions, all `check_*` / `_probe_*` over one image through one `_rt_run` under one
`main()`. Its length is the number of assertions it makes about the shipped bytes,
and that number growing is the gate succeeding.

**Closed 2026-09-05:** `docs/scripts/sync_versions.py` had NO module docstring at all
— shebang straight into `from __future__` — despite being the authority for the
version-propagation ritual. It now states its six consumers, why `--write` does the
Dockerfiles FIRST (the snapshot reads its numbers back out of them, so the other
order needs two passes), and that a malformed marker fails BOTH modes; it ends at
`cross-build-verification.md#pre-flight`, which is where the `version-snapshot` slug
is actually documented — the honest anchor the row said did not exist. Its
`file-size.allow` row moved 849 → 873. The not-a-split verdict above it is unchanged.

**Three rows grew by one or two lines on 2026-09-05 and are recorded as such:**
`build-gcc.sh` 880 → 881, `build-opencv.sh` 935 → 936 and
`build-app-wheelhouse.sh` 1246 → 1248, all from YB's `compiler_cache_launcher_env`
call at the launcher-resolution site. `smoke-runtime-image.sh` also moved; its own row
carries both lanes' reasons.

### F3. Clone families worth one owner [S-M each]

The gate reads `3544 units in 373 files, no block over 10 shared 12-token shingles
(248 allowlisted pair(s); 845 shingle(s) suppressed as idiom at >6 owners)` on the
2026-09-05 integrated tree. The decided/reviewed items (the source-or-fallback KEEP decision,
the lint-tool and `lib/*` pairs reviewed-and-kept by measurement, the not-actionable
Dockerfile mount preambles, and the `install-deps.sh` family) are in the 2026-09-03
archive and in `docs/scripts/code-dupes.allow`.

**CLOSED 2026-09-04 — the `lib/*.sh` 14-line logging preamble.** One owner now,
`lib/log-bootstrap.sh`, sourced by all nine libraries; net −132 lines, three
mutations (`lib.log-bootstrap-*`) holding it. **The mechanism, the two libraries
that keep a `_*_CORE_DIR` anyway, the two historical drifts and the answer to this
entry's own "bootstrap paradox" objection are owned by
[`shared-script-libraries.md`](shared-script-libraries.md#the-logging-bootstrap) —
read it there, do not restate it here.** The one thing worth repeating in a
duplication entry: no duplication gate could ever have found this, because at nine
owners every shingle of the block landed in the `suppressed as idiom at >6 owners`
bucket. That is what made a backlog row necessary instead of a gate finding.

**The gate bookkeeping that extraction owed, and what it exposed.** Dropping the
preamble below `MAX_OWNERS = 6` unsuppressed 5 pairs that had been invisible (891 →
801 suppressed shingles) — exactly what this entry predicted. All five were read and
recorded in `code-dupes.allow` rather than re-suppressed. They are a genuinely
different family, the **defensive logger**: `command -v` not `declare -F`, bare
`[INFO]`/`[WARN]` with no ANSI, no `err()`, no attempt to load `logging.sh`, longest
run 2–3 lines. It **cannot** adopt `lib/log-bootstrap.sh`: `lib/` is deliberately in
no Dockerfile while all three of those files are inside the build closure.

**CLOSED 2026-09-05 — the ORT end-of-stage summary.** One block of 23 shingles in
four files (`30-build-native.sh`, `-amd`, `-nvidia`, `60-build-genai.sh`) is now
`report_onnx_build_output` in
`03-media/build/onnxruntime/build/lib/common.sh`, beside its sibling
`finalize_onnx_native_output`. **The family had already drifted** — `-amd` listed
libraries with `sed -n '1,20p'` where the other three used `head -20` — which is
exactly what one owner prevents. The bookkeeping that extraction owed is the part
worth reading: three budgets lowered (31→20, 34→13, 34→18), two rows deleted as
stale, and **two budgets RAISED with both files unchanged**
(`compiler-cache.sh`↔`build-gcc.sh` 36→38, `build-armnn.sh`↔`build-opencv.sh` 13→14)
because dropping three copies pushed shingles below the >6-owner idiom cutoff and
UNSUPPRESSED those pairs — the same effect the log-bootstrap extraction recorded on
2026-09-04. Both were re-read and recorded, not re-suppressed.

**A second unsuppression to expect the next time a copy is dropped.** This is now
twice in two waves. Any extraction that takes a block from >6 owners to ≤6 will
reveal pairs that were never findings, and the honest response is to read and record
them, never to re-suppress by widening `MAX_OWNERS`.

**CLOSED 2026-09-05 — the `build-ffmpeg.sh`↔`build-pyav.sh` launcher twin.** One
owner, `media_compiler_launcher` in `03-media/core/common.sh`, beside `media_jobs`.
The pair fell 21 → 4 shared shingles and its `code-dupes.allow` row was DELETED as
below-threshold. Two things worth keeping from how it went: the owner takes an
**out-variable name and prints nothing**, because a `$(…)` caller runs
`compiler_cache_launcher_env` in a subshell and throws away the server address it just
exported — the exact YB defect, re-created and caught before shipping. And the two
copies had **already drifted**: ffmpeg tested `USE_CCACHE` with an inline deny-list,
pyav with the canonical `is_truthy`. The owner uses `is_truthy`; the sole behavioural
delta is `USE_CCACHE=y` in the ccache-fallback arm, which is unreachable from these
two scripts and which no Dockerfile or `.env` sets.

**The host-compiler-preference family is still recorded-not-owned:**
`compiler-resolution.sh` / `android-build-preamble.sh` / `ffmpeg-probe-framework.sh`,
29 shingles across 4 sites, and its own allow row already says it "wants one owner".

**Two families read and recorded, neither changed:**

- **`strip_elf_tree`** (`build-helpers.sh:160` / `bootstrap.sh:41` /
  `build-gcc.sh:825`, 27 shingles). The owner already exists and its own comment says
  it centralises this pattern; `bootstrap.sh`'s copy is the legitimate
  source-or-fallback half. **`build-gcc.sh:833` is the one caller that never
  converted AND is not equivalent** — it filters `-type f -executable` plus an ELF
  executable-or-shared-object awk, while the owner takes `-type f` plus `/ELF/`. So
  converting it means either giving `strip_elf_tree` a filter argument or accepting
  that a WIDER set of files gets stripped in the shipped toolchain. Build closure;
  only a real toolchain stage shows what changes in the bytes.
- **`media_jobs`** (`android-build-preamble.sh:77` /
  `build-android-from-source.sh:236` / `build-app-wheelhouse.sh:76`, 26 shingles).
  Not the shared idiom the pair row called it: the NAME HAS TWO DEFINITIONS —
  `03-media/core/common.sh:221` (assumes `media_common_init` pre-loaded
  `parallelism.sh`) and `android-build-preamble.sh:77` (a strict superset that
  sources it on demand) — and `build-android-from-source.sh` sources the preamble at
  line 6 and then re-implements the function inline anyway, its own comment admitting
  it "Mirrors media_jobs() but keeps the configurable per-job cap".
  `build-app-wheelhouse.sh` is a fourth copy at 4096 MB. The fix is one
  `media_jobs [cap_mb]` defaulting to 2000, arithmetically identical for all 14
  callers — but two same-named definitions mean **last source wins** wherever both
  are in scope, nothing covers `media_jobs` today, and only a stage shows which one
  the android lanes actually get.

**One open question answered 2026-09-03-style, per-RUN, and recorded in its row.**
The `gstreamer-env` ↔ `libcamera-env` pair asked "is the fallback still reachable at
all". `libcamera-env.sh` has exactly ONE consumer, `04-runtime/entrypoint.sh`, whose
base carries `Dockerfile.package:285 COPY linux/scripts/01-core/ /opt/scripts/core/`
— `path-helpers.sh` IS there, so that fallback is **dead**. `gstreamer-env.sh` has
four: the same entrypoint (dead), `Dockerfile.media:913` and `:965` which bind-mount
`01-core` entire (dead), and `setup-gstreamer.sh:420` / `build-libcamera.sh:86`
which source it by repo-relative path on a host checkout where `/opt/scripts` does
not exist — **live**. Verdict: KEEP both. They are one 27-line block, deleting half
is a build-closure edit no gate can prove, and the branch costs one `[ -f ]` per
container start.

**Two overlaps observed while reviewing that no gate currently flags.**
`docs/scripts/sync_versions.py`'s `_update_dockerfile_args_inner` and
`_update_script_defaults_inner` are the same algorithm over two syntaxes (outside
the closure). And `prepare_host_cargo_toolchain_env` overlaps the host half of
`_gst_rs_cargo_config`, which calls it when defined (inside the closure). Both are
dupes-gate questions, not complexity ones.

**One duplication with no code owner and no way to get one.**
`linux/host-config/prune-safe.sh` and `01-core/disk-guard.sh` both know the filtered
`buildctl prune` command and the GB→MB convention, because `prune-safe.sh` runs
`main` on load and therefore cannot be sourced. The `x1000` half of it is no longer a
guess: `buildctl prune --help` documents `--keep-storage` in MB, so `keep_gb * 1000`
really is ~120 GB. Extracting the rest means restructuring a `host-config` script.
