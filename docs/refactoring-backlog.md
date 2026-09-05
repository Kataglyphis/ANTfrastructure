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
cache loss · **HT**=host trees in foreign images · **GH**=gate holes and gate
scope · **CL**=build-closure follow-ups no gate can settle · **F#**=size and
duplication tracks · **CC**=consumer-contract defects a consuming repo reported
against shipped bytes. **DISK** is retired (DISK1 and DISK2 are both closed).
**QW/TC/SMK** were retired by the 2026-09-04 waves; everything else
(**AP/TG/TS/GPU/DUP/PAR/SCC/BT/LOG/LB/C#/D#/P#/S#/XC#**) is archive-only.

Last groomed: **2026-09-05, after the eight-lane integration wave.** Every number
below was re-derived from the gates on the integrated tree, not carried forward.

## THIS FILE IS NOW ALMOST ENTIRELY A BUILD-WATCH LIST

Read this before anything else, because it is the honest state of the wave and it
changes what the rest of the file is for.

**Nothing in this repository has been through a build since the 2026-09-04
`--only runtime` run, and that run FAILED.** Its own log
(`~/build-logs/six-fixes-20260904-211138.log`) ends `=== Results: 5 failure(s) ===`
/ `[ERROR] runtime stage failed` at 03:10 — the amd64 tree-arch gate's cross-payload
false positives, which HEAD `2157ec6c` then fixed. The chain aborted there, so **the
arm64 and riscv64 runtime smokes never ran at all**. The live `:latest-cross`
manifest (`sha256:752596d8…`) is dated roughly an hour later, so it was assembled
outside that chain. Any earlier claim in this file, or anywhere else, that "three
children each passed the full runtime smoke" is not supported by a log on this host,
and the wave's own re-reads of the shipped images are the stronger evidence for
everything that was measured rather than run.

**The 2026-09-05 wave closed nine entries outright and gutted five more, and every
one of them was closed with STATIC proof.** Gone entirely: DISK2, HT2, HT3, CL2,
CL3, GH1, GH2, GH3, GH4. Reduced to a named residue: CL4 (now GH7), CL6, GH5, GH6
and YB. What a suite proves is that a function behaves; it cannot execute a
Dockerfile stage, cannot see a `source_module` mount gap, and cannot tell you
whether a stage slices a script or runs it whole. **Thirteen entries remain**
(`grep -c '^### '` counts fifteen; "Next up" and "What needs the OWNER" are not
entries), and of those, CC1, CL1 and YB are pure watch lists while CL6, CL7, HT4 and
HT5 are work that needs the same window. **CL1 is the watch list and it roughly
doubled.**

**Where the gates stand on the integrated tree** (all rc 0; the full preflight is
**10 m 31 s** wall clock now, up from ~8 m 30 s — the nineteen net-new suites and the 153
appended mutation entries are where it went):

| gate | reading |
|---|---|
| `mutations` | **530** entries over **68** distinct test commands, every one biting, none vacuous or stale |
| `gate-registry` | **34** slugs; **32** proven; **2** unproven and frozen with named reasons; 200 ids in 31 declared families |
| `script-tests` | **96** suites, **2942** assertions |
| `code-size` | 31 functions over 80 lines, 11 files over 800 — all frozen, all with a verdict |
| `code-complexity` | 67 `cc` over 15, 2 `nesting` over 5 — all frozen, all with a verdict |
| `shellcheck-warnings` | **88** findings over a **341**-file scope — all frozen, all with a verdict |
| `code-dupes` | 3544 units in 373 files, **248** allowlisted pairs, 845 shingles suppressed as idiom |
| `dead-functions` / `trailing-conditional` / `comment-size` / `masked-assignments` | 30 / 32 / 171 / 46 frozen |
| `doc-links` | 72 pages, 493 code pointers, **45** bare header pointers frozen |

**Closed by the 2026-09-05 wave and living in git history rather than here:**
DISK2 (the buildkit fallback is wired into both `build-cross-chain.sh` gates, with
`_disk_guard_reclaim_begin` as the one owner of the per-episode latch), HT2 (the
tree-arch exemption table is now measured — `/opt/android` asserted, `/opt/android-sdk`
kept with its numbers, `riscv64:flutter-owner` asserted, and the `Intel 80386` label
that ate a column fixed), HT3 (five builder-arch LLVM libraries removed at the source
plus the invisible amd64 twin), CL2 (`cpython_ext_modules` is the one owner),
CL3 (`export_clang_gcc_toolchain_env` deleted, the clang wrappers proven instead),
CL4 (the `doc-links` header-pointer rule ships, 45 rows frozen and grouped),
GH1 (`--stale-check` plus a pre-push hook), GH2 (`quality_allow.iter_rows` is the
single allow reader; `verify_doc_dupes.load_allow` was the last copy and is gone),
GH3 (`trailing-conditional` judges the RETURNED statement — four false negatives
closed and five real defects fixed), GH4 (the env-knobs owner scan reads the `.env`
files a stage sources), and the nine `gate-proofs.allow` slugs GH5 shed.

**What the allow files are now, and what they are not.** Every row in
`function-size.allow`, `code-complexity.allow`, `file-size.allow` and
`shellcheck-warnings.allow` carries a verdict naming what its number IS. That
makes them a reference, **not a queue**. Most rows are tables (flag parsers,
per-arch dispatch, codec probes), refusal matrices where fewer paths would cost
safety, or heredoc payloads the shell walker never reads. Do not open one of these
files looking for the biggest number; open it looking for the reasons that say
SPLIT WANTED, and read the reason before acting — several say explicitly what a
future reader must not "clean up".

### Next up — in order; the first four share one build window

1. **Run a chain, then read CL1, CC1, YB and HT/CL6 against its log** [S to
   watch, ★★★]. Not a code change, and it is now the only thing that can move
   this file. Fourteen entries were closed or gutted on static proof this week and
   three watch lists hang on one run. A compile-heavy chain (media or toolchain, **not**
   `--only runtime`) answers YB as well, because the launcher now prints the
   server address it used.
2. **CL6 — the `_gst_monorepo_tflite_flags` split** [S, ★★]. The last item of the
   original eight, and the only one that changes what a build does. It rides in the
   same window.
3. **CL7 — the three closure defects this wave FOUND and did not fix** [S each,
   ★★]. Each is a real defect with a named failure mode, each was pinned as a
   KNOWN-GAP case rather than papered over, and each needs the same window.
4. **HT4 / HT5 — two measured size defects nobody had a number for** [M each, ★★].
   HT5 is 5.7 GB of builder-arch payload in each foreign image, ~19 % of both;
   HT4 is a set of dangling dev symlinks the old glob never fixed either. Both were
   measured on the shipped bytes this week.
5. **The gate work: GH7's 38 header-pointer rows, then GH6's deep half** [S then L,
   ★–★★]. GH7 is 38 small edits of two different kinds (29 anchors to choose, 9
   backlog pointers to RE-POINT at a durable page); GH6's same-name masking is the
   one structural hole left, and the cost of closing it properly is now written down.
   GH5's two frozen slugs are third: both need a real change, not a suite.
6. **F1 / F2 / F3 — the size and duplication tracks** [M–L each]. None of them is
   a defect. The remaining named items are `smoke-cross-all-arches.sh main`, the
   `_cross_stage_build_impl` registry-cache-drop coverage, the `agentic-loop.sh`
   split (now unblocked — it has 24 assertions), and three clone families.

**Honesty about the rest:** the real defects with a known failure mode are CL7's
three, `_gst_monorepo_tflite_flags`, and HT5's 5.7 GB. Everything else on this list
is either a watch or a track.

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

**Two things the consumer flagged as NOT defects, both still worth acting on:**
advertise `/opt/flutter` in the consumer-facing image docs (consumers still passing
`--flutter-dir /workspace/flutter` re-download the SDK every run), and note that
`/var/cache/ccache` is not a `VOLUME`. The multi-arch index fixing their arm64 lane
is the payoff line for the manifest work; do not forget it when the index shape is
next touched.

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
| `06-packaging/copy-media-payloads.sh` | the package-stage copy loop deleted; only `publish_llvm_target_ld_path` remains | `import tvm` must still work on all three arches (`smoke-torch-venv.sh`'s tvm row) |
| `01-core/guard-helpers.sh`, `01-core/version-forwarding.sh` | `csv_each` and `append_version_build_args` loop bodies became `if`s | `append_common_build_args` → `append_version_build_args` runs for every stage's build-arg assembly; only a chain proves the forwarded `--build-arg` list is byte-identical |
| `03-media/.../build-gstreamer-stage.sh` | `_dump_gst_build_logs` (the stage's ERR trap) became an `if` | only a FAILING GStreamer build exercises it; a green build proves nothing and a red one is the test |
| `01-core/cross-gcc.sh` | `export_clang_gcc_toolchain_env` DELETED | watch the toolchain and media stages for `command not found: export_clang_gcc_toolchain_env`. Static evidence is strong (no caller, no `CC=*clang` anywhere, the wrappers bake `--gcc-toolchain` themselves) but a Dockerfile `RUN` assembling the call at runtime is invisible to grep |
| `01-core/cpython-dev-packages.sh` + `02-toolchain/python/build_python.sh` | the lib-dynload audit reads `cpython_ext_modules` | the audit now WARNS for five modules it never checked (`_zstd`, `readline`, `_curses`, `_uuid`, `_decimal`). Those are information on `optional` rows, not failure — but any of them appearing on **amd64** is a genuine finding |
| `04-runtime/gstreamer-env.sh` | dead `SYSTEM_LIB` deleted from both TRIPLET branches | only a rebuilt image proves the entrypoint still sources it and that `GST_PLUGIN_PATH`/`PKG_CONFIG_PATH`/`LD_LIBRARY_PATH`/`GI_TYPELIB_PATH` still carry the multiarch entries on arm64 and riscv64 |
| `03-media/.../gstreamer/common/pre-setup.sh` | `gi_bindir`, `gi_libdir` and the now-dead `build_triplet` deleted | only a stage that builds the monorepo proves the g-ir-scanner / ldd / qemu wrappers are still written and `gobject-introspection-1.0.pc` still resolves. **riscv64 is the arch to watch** — its introspection runs under qemu |
| `01-core/stage-defs.sh`, `build-runtime-manifest.sh`, `01-core/python_uv.sh` | dead locals removed | closest to already-proven (preflight's `stage-graph` slug runs the real graph); what a chain adds is `build-cross-chain.sh` getting a 0 verdict under the orchestrator's own env |
| `03-media/build/onnxruntime/build/{30-build-native,30-build-native-amd,30-build-native-nvidia,60-build-genai}.sh` | four copies of the end-of-stage summary replaced by `report_onnx_build_output` | one per lane. Unproven statically: the `find … \| head -20 \|\| true` pipeline under the stage's `pipefail` (head closing the pipe can SIGPIPE `find`), and that the AMD stage's output is unchanged now that it uses `head -20` where it used `sed -n '1,20p'` |
| `linux/scripts/lib/slang-compile.sh` | `_slang_emit_one_wgsl` extracted | validated only against a fake `slangc`; a consumer run with the real one against a real manifest is what proves it end to end |

**Two shapes that would be silent if wrong**, unchanged from wave 1: an operator
whose shell still exports `MYPROJECT_GCC_TOOLCHAIN_PATH` is now ignored rather than
erroring, and eleven of thirteen `: "${NAME:=default}"` conversions sit at file top
level — so any Dockerfile `RUN` that *slices* a script rather than running it whole
would read an unset variable. `IREE_CROSS_BUILD_COMPILER` was caught statically for
exactly that reason; a second would look identical. The 2026-09-05 additions were
checked against this: `cpython_ext_modules` sits inside a sourced module, and
`pre-setup.sh` is executed WHOLE (`build-gstreamer-stage.sh:107`), so neither adds a
slicing hazard.

### CL6. One closure clean-up left of the original eight [S, ★★]

Six of the eight were made on 2026-09-05, each with a suite and a mutation and each
re-baselining its own allow row in the same change (`shellcheck-warnings.allow` lost
four rows and re-baselined one 3 → 2; `comment-size.allow` lost the
`cpython-dev-packages.sh` row when its header shrank 18 lines → 9). Two were
DECIDED rather than done and their reasons now live in the allow files. What is left
is the one item that changes what a build does.

**The split — `03-media/.../build-gstreamer-monorepo.sh | _gst_monorepo_tflite_flags`**
(cc 18) is three unrelated TFLite workarounds under one name: the cross pkg-config
probe that emits `-idirafter`/`-L`/`-rpath-link`, the idempotent sanitizer for the
stray `}` an old `generate_pkgconfig_file` left in `tensorflow-lite.pc`, and the
symlink farm that exists only because Meson probes via `-print-file-name` and ignores
`-L`. Seams are clean; only an arm64 **and** riscv64 monorepo stage that still
resolves TFLite proves the split.

**Decided NOT to do, and why — do not re-litigate these.**

* **`06-packaging/package_archive.sh`** is not a build-window item at all; it is an
  owner question, and it has moved to "What needs the OWNER" above.
* **The two SC2206 cmake-argv quotings, and the two halves differ.**
  `build-clang.sh:280` and `:283`: `ENABLE_LTO` and `BOOTSTRAP` are assigned only
  from literals in that file (`OFF`/`ON`/`Thin`, no env path), so quoting is
  PROVABLY a no-op — it buys a silenced advisory row and costs a closure edit whose
  suite could assert nothing but the presence of the quotes. `cross-env.sh:680` is
  different: `CMAKE_POLICY_VERSION_MINIMUM` IS operator-reachable (`build-litert.sh`
  exports it), so quoting is a real argv change for a multi-word value, six other
  sites already pass that variable quoted, and whether the disagreement can bite is
  a cmake-argv question only a build answers. Neither is subtraction; both reasons
  are in `shellcheck-warnings.allow`.

**Still flagged, not changed:** `vulkan.sh:268` is the one `SC2155` in the tree whose
masked callee is not trivially total —
`export PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir …):${host_pkgconfig}"`.
`cross_pkg_config_libdir` only probes directories today so it cannot fail; if that
ever changes, the failure is silent and `PKG_CONFIG_LIBDIR` keeps only the host path.

**A cascade worth remembering before the next reader trusts a shellcheck row.**
Deleting `gi_libdir` in `pre-setup.sh` made `build_triplet` dead — its only reader
was that block — so the file's SC2034 count moved 2 → 1 with a DIFFERENT variable
behind it, not 2 → 0. Any similar dead-local deletion should re-run shellcheck on the
file rather than assume the count drops by exactly what was removed.

### CL7. Three closure defects this wave FOUND and did not fix [S each, ★★]

Each was found while characterising something else, each is a real defect with a
named failure mode, and each is pinned as a KNOWN-GAP suite case rather than papered
over. They share CL6's window.

1. **`01-core/python_uv.sh` — `_uv_conflict_groups` cannot read inline TOML.** It
   closes a group on the `]` it meets during the same character walk that gathers
   extras after it, so an inline
   `conflicts = [ [ { extra = "a" }, { extra = "b" } ] ]` — legal TOML that uv
   accepts — yields NO group and excludes nothing, and `uv sync --all-extras` then
   fails with the original conflict error. Today's Orchestr-ANT-ion `pyproject` uses
   the multi-line layout, so it is **latent**. Note the proof shape: no cross stage
   exercises this at all (`uv_sync_project` is called only from
   `02-toolchain/python/ci_*.sh`), so what settles it is a consuming repo's CI lane
   running `uv sync --all-extras`, not a ContainerHub build.
2. **`lib/agentic-loop.sh` — a mid-function `&&` list in the opencode arm.**
   `[[ "$role" == "fixer" ]] && oc_agent="executor"` fails for every non-fixer role,
   which kills the function under a consumer's `set -e`. It is not a trailing
   conditional, so `trailing-conditional` cannot see it; it was found only because a
   probe had to use `role=fixer` to route around it.
3. **`03-media/core/common.sh:152-167` — a provably UNREACHABLE
   `cross_build_is_active` fallback.** `media_common_init` asserts with `declare -F`
   at line 113 that the function exists and returns 1 when it does not, so the
   `if ! command -v cross_build_is_active` sixteen lines later can never be true. It
   was recorded rather than cut on purpose: 03-media has no unit suite for
   `media_common_init`, and deleting a fallback because an assertion three lines
   earlier makes it unreachable couples two things that are independent today. The
   `build-gstreamer-monorepo.sh` copy is LIVE and a strict superset.

**Related residue from GH3, still out of any gate's reach:** the sibling fallback at
`01-core/cross-env.sh:433` is `[ -x "${_cxx_fb}" ] && _ert_out[cxx]="${_cxx_fb}" || return 1`.
Correct today — its last arm is `return 1`, so the sharpened `||` rule passes it —
and exactly the shape SC2015 warns about. It is out of reach for a stated reason now
rather than by omission: the gate's `DEF` pattern is column-anchored, so the indented
`cross_build_is_active` fallbacks are invisible to it and
`test-cross-fallback-parity.sh` watches them instead.

### GH5. Two preflight slugs stay frozen, with better reasons [M, ★★]

`gate-registry` reports **34 slugs; 32 proven; 2 unproven, 2 frozen in
`gate-proofs.allow`** — it was 34/23/11 at the start of 2026-09-05. Nine left the
freeze in one wave (android-parity, patch-integrity, copy-coverage,
mirror-consistency, runtime-paths, arg-consistency, workflow-lint, secret-scan,
sbom), each with a characterisation suite driving the REAL gate in a throwaway tree
and mutations on its own script. The two that remain are frozen for a **named
reason**, not for want of a suite, and both reasons say what the route out is.

**Both reasons, and the route out of each, are owned by
[`code-quality-tooling.md`](code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons)
— read them there, do not restate them here.** What belongs in a backlog is only
what someone would DO:

* **`critical-fixes` needs a SPLIT before it needs a suite** — a host gate and an
  in-image smoke — which is a real change to a script the chain runs, not a
  test-only wave. **If a rebuild happens, run `verify-critical-fixes.sh` from INSIDE
  a shipped runtime image** (`nerdctl run --rm`, read-only). That is the missing
  evidence for its `/opt`-probing half, and it would say whether the split is the
  right shape before anyone writes the suite.
* **`version-snapshot` needs one fixture per sub-check**, seven of them, because its
  verdict is an OR and a suite that reddens one would un-freeze the slug while six
  stayed unproven. One sub-check's targets are Windows-lane files, out of scope here.

**The hollow-mention hazard is unchanged and lives among the 32 proven slugs**, not
these two — the registry's test half is still a mention match. This wave nearly
shipped one and the story is in the page above; the operational residue is that
`test-arg-consistency.sh`'s assertion now stops short of a gate basename on purpose.

**Two fixture traps that will catch the next author,** both now commented in place:
a test file under `linux/` that spells out an inline `${GCC_VERSION:-…}` fallback is
scanned as a REAL site by `arg-consistency`'s GCC-literal gate, and a test file under
`linux/scripts` that spells out any `${UPPERCASE:-default}` registers as a real knob
with `lint-env-knobs`. Both fixtures assemble the expansion from `printf` arguments.

### GH6. `dead-functions` same-name masking [L, ★★]

The narrow half closed on 2026-09-05: a definition's mentions of ITSELF are now
subtracted, so a function that names itself in a `printf` (CL3's
`export_clang_gcc_toolchain_env` was the live instance) and pure recursion no longer
read as uses. The verdict was byte-identical on that day's tree, which is the point —
it removes a false-negative shape without moving a single row. Cost: 0.5 s → 0.9 s.
The census's headline figures are also derived now rather than re-typed, in
`test-doc-numbers.sh` against the gate's own `--census` CLI (they were stale by 5 and
1 when someone finally checked).

**The deep half is open, and what closing it costs is now written down** in
[`code-quality-tooling.md`](code-quality-tooling.md) under "What closing the masking
hole actually costs" rather than restated here. In one line: one name table for the
whole corpus means a dead `log()` is kept alive by a live `log()` anywhere, and
fixing it needs `source_module`-aware scoping — the sourcing graph resolved through
`SCRIPTS_ROOT` and the container-vs-repo dual layout, the Dockerfile stage graph, a
rule for the ~40 deliberately shared helper names, and a second tool the size of the
gate that would still guess at `bash -c` strings. The interim shipped on 2026-09-04:
`--census`'s second tier reports **94** definitions whose name a second file also
defines, which is exactly the surface where the gate's verdict comes from a name it
does not own. That is a watch list, not a fix.

**One measured alternative that is ruled out, so nobody re-tries it:** stripping
string literals corpus-wide turns 9 live functions dead, the trap handlers among them.

**Read this together with GH3's delegate hop.** `trailing-conditional`'s hop
deliberately refuses to cross files, because one `log()` anywhere would otherwise
decide every `log()`. If GH6 ever gets `source_module`-aware scoping, the hop should
be widened in the same commit, and `test-doc-links.sh`'s "the hop stays inside one
file" case is the assertion that will have to change.

### GH7. `doc-links` header pointers: the gate ships, 38 rows of debt do not [S, ★]

CL4 closed by building the rule: a bare `docs/*.md` pointer in the first 10 lines of
a `.sh`/`.py` file is now a `doc-links` finding unless frozen in
`docs/scripts/doc-header-pointers.allow`, keyed `<file>` TAB `<page>` so a heading
moving inside its block does not re-flag it, and two-way so a pointer that GAINS an
anchor makes its row STALE. Re-derived counts, not the ones the old entry quoted:
**493 code pointers, 153 anchored, 340 bare; 51 file-header pointers of which 6 already carry
the `page.md § Heading` form, leaving 45 frozen.**

The allow file is grouped by what the rows ARE, and the groups are different jobs:

* **7 rows where the page IS the subject** (`build-resource-monitoring.md`,
  `riscv64-rva23-baseline.md` and five more). An anchor would be a second name for
  the same thing. **Not debt** — leave them.
* **9 rows pointing into `refactoring-backlog.md`.** These must **NOT** be anchored:
  an OPEN entry is archived when it closes, so the anchor is built to rot. The fix is
  to RE-POINT each at a durable page. `test-gi-cross-detect.sh`,
  `test-gstreamer-env.sh`, `test-manifest-wrapper-gate.sh` and
  `test-uv-conflict-extras.sh` all point at "CL6" specifically, which this very
  grooming has already shrunk.
* **29 rows of real debt** into large multi-subject pages:
  `cross-build-verification.md` 13, `failure-modes.md` 7,
  `code-quality-tooling.md` 3, `build-cache-tiers.md` 3, `code-quality-gates.md` 2,
  `linux-cross-builds.md` 1. One anchor each, and each needs the right section chosen
  for the right file.

**The allow file must be RE-DERIVED, never merged as text** — it is a snapshot of
every file header in the tree and it went stale twice inside one hour while it was
being written:
`python3 -c 'import sys;sys.path.insert(0,"docs/scripts");import verify_doc_links as V;print("\n".join(sorted(V.header_pointers())))'`.
Keep the three group comments; they are the difference between a reviewed list and a
queue.

**What the rule still cannot see,** stated so nobody assumes otherwise: a bare
pointer below line 10, a pointer in a Dockerfile or `.env`, and an anchor that is
valid but names the wrong section. The 296-wide bare-pointer-in-prose case was
deliberately declined.

### HT4. `/opt/llvm-target/lib` on amd64 ships dev symlinks that dangle [S, ★★]

Found while walking the amd64 prefix for HT3, measured, and deliberately not fixed in
that change. `/usr/local/llvm-target/lib` on amd64 contains dev symlinks that point OUT of the
prefix. In the builder they resolve, because the multiarch dir is right there; after
`Dockerfile.package` COPYs the tree they would resolve to `/usr/local/x86_64-linux-gnu`,
which does not exist, so they **dangle in the shipped amd64 image**.

MEASURED in `latest-cross-amd64` on 2026-09-05, not transcribed — an earlier draft of
this entry named five files and got three of them wrong. There are **nine**:

```
libclang-23.so  libclang.so  libclang-23.1.0.so
libc++.so  libc++.a  libc++abi.so  libc++abi.a  libc++experimental.a  libc++.modules.json
```

`liblldb-23.so.1`, `libc++.so.1.0` and `libc++abi.so.1.0` are NOT among them; the
`liblldb` argument the draft leaned on does not hold in the builder either, so it is
gone. What remains is the plain defect: nine dev entries that point at nothing in the
shipped image. Six are static archives and a JSON manifest, which nothing loads at
runtime — the three `libclang*` links are the ones a consumer compiling against the
prefix would hit. The fix belongs with someone who can watch an sdk stage.

**A gate shape that would have caught both halves of HT3 and would catch this:** the
tree-arch gate can only ever see wrong-ARCH weight, which is why HT3's amd64 twin
(358 MiB of Ubuntu llvm-20/21 inside a clang-23 prefix) was invisible to it by
construction. Something like "the `llvm-target` prefix ships no soname whose major
differs from `LLVM_RELEASE`, and no `lib/` entry that does not resolve inside the
prefix" is cheap, arch-independent, and would have caught the dead weight AND the
dangling links. Recorded, not proposed as work.

### HT5. `/opt/vulkan` ships 5.7 GB of builder-arch payload into each foreign image [M, ★★★]

Measured on the shipped bytes, 2026-09-05, while HT2's exemption table was being
re-derived. `/opt/vulkan` in the arm64 and riscv64 images is **5.8 GB** — 1.8 GB
`x86_64/` plus 3.9 GB `source/` plus 58 MB / 84 MB of actual target libs — holding
**1 317 X86-64 and 2 Intel-80386 ELF objects across 33 926 files**. amd64's
`/opt/vulkan` is 1.8 GB and IS `active/`, so the waste is **foreign-only**: roughly
**18.5 % of the 30.84 GB arm64 image and 19.2 % of the 29.69 GB riscv64 one**.

**The tree-arch gate cannot see any of it, and that is deliberate.** The probe was
narrowed to `active/` (122 files, 3 objects, all target) because `active/` is what
the image RUNS and all the gate can honestly assert. The narrowing was KEPT and the
number written into
[`artifact-copy-completeness.md`](artifact-copy-completeness.md).

**The framing above was wrong, and the 2026-09-05 investigation replaced it.** The
question is not "how much builder-arch payload can be pruned" — it is **why the
target prefix was worth so little that pruning looked like the win**. Measured on the
shipped arm64 image: `x86_64/bin` holds **52 tools**, `aarch64/bin` holds **two**
(`glslang`, `glslangValidator`), while `aarch64/lib` holds the *complete* set of
`libSPIRV-Tools*`. The cross build had succeeded and been told not to keep its
binaries:

- `_vulkan_target_build_spirv_tools` passed `-DSPIRV_SKIP_EXECUTABLES=ON`. Its own
  header says why — *"TVM's Vulkan build links it"*. The target prefix was built to
  be **linked against**, never to be **used**.
- `_build_vulkan_targets` attempted only four things: headers, loader, SPIRV-Tools,
  glslang. Every other SDK component was cross-built for no arch at all.

FIXED 2026-09-05: the flag is `OFF`, and `_vulkan_target_build_sdk_rest` adds
Vulkan-Headers, SPIRV-Headers, Vulkan-Utility-Libraries, SPIRV-Cross, SPIRV-Reflect
and **Vulkan-ValidationLayers** through one shared `_vulkan_target_install_component`
(non-fatal per component, aggregate verdict unchanged). `check_vulkan_toolset` in the
runtime smoke now FAILS on the shape that shipped, with seven cases in
`test-runtime-image-gates.sh` proving it bites. Nine `_vulkan_skip` rows that the
consuming loop never read — and that mislabelled ValidationLayers/shaderc/SPIRV-Cross
as *"host-only component"* — are deleted: activating them would have skipped the
CHECKOUTS the target build reads. Design and remaining gaps:
[`vulkan-foreign-arch-sdk.md`](vulkan-foreign-arch-sdk.md).

**UNPROVEN until a rebuild ships it.** The six new components are cross-builds that
have never run; they are wrapped non-fatally, so they either land or they are absent,
but they cannot fail a lane.

Two other facts nobody had ever checked on a real image, recorded in the same place:
all 15 manifest trees exist on all three arches, and no tree comes near
`RT_TREE_CAP` — the largest is `/opt/flutter` at 17 523 of 20 000.

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

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are fully reviewed: **31** function rows over 80 lines
and **67** `cc` rows over 15, every one carrying a verdict that says what its number
IS. Read the reasons, not the numbers.

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

**The next thing to actually do**, now that the two outside-the-closure items are
done: `smoke-cross-all-arches.sh main` (96) is the best-shaped candidate left, and it
is inside the closure. Five numbered probe sections sharing only the harness's
pass/fail globals, so the `_smoke_probe_*` helpers need no parameters. It needs a
build window plus the case pinning the clang section's "matches none of" branch —
the one that used to break after the first arch.

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

**`file-size.allow` is the authority — do not transcribe it here.** The ten-row
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
suite covers both halves across the seam. **See CL7 for a real defect found in this
file while writing that suite**, which is not a trailing conditional and which no
gate sees.

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

**Grown on 2026-09-05, and it wants one owner:** the
`build-ffmpeg.sh`↔`build-pyav.sh` pair went 12 → 13 because YB gave both the same
`compiler_cache_launcher_env` line inside the same
`if command -v compiler_cache_launcher` guard. That guard and its `elif ccache` arm
are the real twin — both scripts re-implement "resolve a launcher, ccache fallback",
which `compiler_cache_launcher` already does internally; the `elif` arms exist only
for when `common.sh` is not sourced. Two media build scripts, inside the closure, so
it needs the same window as CL6.

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
