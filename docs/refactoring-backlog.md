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
cache loss · **DISK**=chain disk reclaim · **HT**=host trees in foreign images ·
**GH**=gate holes and gate scope · **CL**=build-closure follow-ups no gate can
settle · **F#**=size/duplication tracks. **QW/TC/SMK** are retired: the 2026-09-04
integration waves closed them. Everything else
(**AP/TG/TS/GPU/DUP/PAR/SCC/BT/LOG/LB/C#/D#/P#/S#/XC#**) is archive-only.
**CC**=consumer-contract defects a consuming repo reported against shipped bytes.

Last groomed: **2026-09-04, after the second (judgement) wave integrated.** Every
number below was re-derived from the gates on the integrated tree, not carried
forward.

**Nothing in this repository has been through a build since the 2026-09-04
`--only runtime` run.** That statement covers both waves. Wave 1 changed SHAPE in
eight closure files with static proof only — that is CL1, unchanged and still the
first thing to do. Wave 2 was a review wave: it edited exactly ONE file inside the
build closure, `05-frameworks/flutter/flutter_checks.sh`, and only its `# Docs:`
comment on line 5, so it added nothing to CL1's watch list. What wave 2 produced
instead is CL6 — eight closure clean-ups it identified, judged behaviour-neutral,
and deliberately did **not** make, because no suite in this repo can prove a
`source_module` mount gap or a stage that slices a script rather than running it.

**Where the gates stand on the integrated tree** (all rc 0):

| gate | reading |
|---|---|
| `mutations` | **365** entries, every one biting, none vacuous or stale |
| `gate-registry` | **34** slugs; **23** proven; **11** unproven and frozen; 126 ids in 27 declared families |
| `script-tests` | **76** suites, **2434** assertions |
| `code-size` | 33 functions over 80 lines, 10 files over 800 — all frozen, all with a verdict |
| `code-complexity` | 68 `cc` over 15, 2 `nesting` over 5 — all frozen, all with a verdict |
| `shellcheck-warnings` | 92 rows / **174** findings in 72 files, over a **319**-file scope — all with a verdict |
| `code-dupes` | 249 allowlisted pairs — three budgets re-measured DOWN and three rows added on 2026-09-04 |
| `dead-functions` / `trailing-conditional` / `comment-size` / `masked-assignments` | 31 / 18 / 173 / 46 frozen |

**Closed by wave 2 and living in git history rather than here:** F4 (all 95
`shellcheck-warnings` rows reviewed — 92 rows now, three closed by fixing code:
two unguarded `cd`s in `lib/` and a dead `local arch` in `lint-dockerfiles.sh`),
F5 (all 72 `code-complexity` rows reviewed — 70 now, `verify_package_names.py`'s
`scan_file` and `main` both cut from **cc 42**), the `lib/*.sh` logging-preamble
clone family (one owner, `lib/log-bootstrap.sh`, nine consumers), CL5 (both
first-ever-measured functions read and given verdicts), CL4's pointer half, YB's
sub-item (a), GH5's `pkg-names` row (a real 20-assertion suite, not a waiver),
GH6's `_fixture` note, and `cmake_build_parse_args` (116 → 60 lines, cc 31 → 24).

**Eighteen entries remain** (CC1 joined on 2026-09-04) (`grep -c '^### '` counts nineteen; "Next up" and
"What needs the OWNER" are not entries; CL5 is gone, its subject reviewed and its
residue folded into CL6, so the CL numbers run 1–4 and 6). CL1, CL2, CL3 and CL6
are closure work only a real build can confirm; CL4 is a `doc-links` scope
decision; GH1–GH6 are gate holes; DISK2 and HT2 are the halves of DISK1 and HT1
that stayed open; YB is a defect under investigation; F1–F3 are tracks.

**What the allow files are now, and what they are not.** Every row in
`function-size.allow`, `code-complexity.allow`, `file-size.allow` and
`shellcheck-warnings.allow` carries a verdict naming what its number IS. That
makes them a reference, **not a queue**. Most rows are tables (flag parsers,
per-arch dispatch, codec probes), refusal matrices where fewer paths would cost
safety, or heredoc payloads the shell walker never reads. Do not open one of these
files looking for the biggest number; open it looking for the reasons that say
SPLIT WANTED, and read the reason before acting — several say explicitly what a
future reader must not "clean up".

### Next up — the six highest value-per-effort items, in order

1. **CC1 + CL1 — watch the next 3-arch build** [S, ★★★]. Not a code change. CC1
   is the sharper half: four defects a consuming repo hit on shipped bytes are
   fixed here and confirmed only for their ENV halves; the rustup and `/opt/flutter`
   ownership rows can be answered by nothing but the rebuilt image. CL1 is the
   older watch list — eight closure files that changed SHAPE with static proof
   only. Everything else on this list is cheaper *after* that run.
2. **DISK2 — wire the buildkit fallback into the two `build-cross-chain.sh` call
   sites** [S, ★★★]. The in-stage watchdog (where 2026-09-03 actually bit) is
   done; a run that dies at *lane entry* still refuses instead of reclaiming.
3. **CL6 — the eight closure clean-ups wave 2 found and did not make** [S, ★★].
   All behaviour-neutral on inspection, all in files a stage copies and executes.
   They cost one build window, and CL1 already needs that window. CL3's
   delete-vs-wire decision rides along in it.
4. **GH1 — the pre-push hook** [M, ★★]. Sharding keeps this affordable at 332
   entries. Blocked only on `verify_gate_registry.HOOK` being a single path.
5. **GH2 — finish the shared allow reader** [S, ★★]. Half landed;
   `verify_code_dupes.load_allow` still carries its own parse because it needs raw
   line numbers `load_rows` does not surface.
6. **GH5 — the twelve frozen unproven slugs** [M, ★★]. `stdout-returns` and now
   `pkg-names` are the worked examples; the nine remaining tree-consistency
   checkers are the cheapest next batch.

**Honesty about the rest:** F1–F3 remain the biggest *time* items here and none of
them is a defect. The real defects with a known failure mode are DISK2, GH2, GH3
and the `_gst_monorepo_tflite_flags` split inside CL6's window.

### What needs the OWNER, not the agent

Nothing in the seventeen entries above is blocked on you. These are:

1. **`git push`** — `git rev-list --count origin/main..HEAD` says **3** commits
   ahead of `origin/main` as this file was groomed, before this wave's own commit.
   Re-derive it with that command rather than retyping a ref; it was wrong at
   three consecutive groomings before the command was written down.
2. **Downstream consumers of `linux/scripts/lib/`.** The nine libraries now source
   a sibling, `lib/log-bootstrap.sh`. Any full ContainerHub checkout satisfies
   that — which is how [`adopting-in-a-new-project.md`](adopting-in-a-new-project.md)
   says to consume them — but a consumer that had copied ONE `lib/*.sh` file out on
   its own will break on its next CI run, not here. No such consumer exists in this
   repo.
3. **The Windows lane.** Six confirmed doc defects from the 2026-09-03 currency
   audit are parked in
   [`windows-refactor-backlog.md`](windows-refactor-backlog.md), verified against
   the tree only — no Windows host was involved. **Three** of the six are wrong
   paths a reader would follow into a "file not found"
   (`verify-host-setup.ps1`, `healthcheck.ps1`, `Dockerfile.toolchain`); the
   fourth is the QNN version contradiction at `README.md:204`. **New on
   2026-09-04:** `windows/scripts/tests/Pins.CanonicalValues.Tests.ps1` reads
   `CUDA_ARCHITECTURES` from `versions.env` via `Get-Pin` and asserts it equals
   `80;86;89;90`. That value is now QUOTED in `versions.env` (it had to be — an
   unquoted `;` ran its own tail as commands on every plain `source`).
   `load_versions_env`, `sync_versions.py` and `bump_versions.py` all strip one
   surrounding pair and were proven byte-identical; whether `Get-Pin` does was
   not testable from this host. One PowerShell run answers it.
4. **A newer QNN SDK, if you want one.** v2.49.0.260730 is pinned, hashed and
   validated end to end. Only a *newer* SDK needs a re-pin, and only you can fetch
   it (login-gated).

### CC1. The consumer-contract fixes are static until the next runtime build [S to watch, ★★★]

**Evidence: a consuming repo's CI lane, not a gate.** The
Kataglyphis-Inference-Engine lane ran against `:latest-cross-amd64` as uid 1001 on
2026-09-04 and reported four defects; all four were reproduced here in the shipped
bytes before anything was written:

| # | what the consumer saw | where it came from |
|---|---|---|
| 1 | `CCACHE_DIR=/workspace/.ccache`, `SCCACHE_DIR=/workspace/.sccache` — the cache lands in their bind-mounted checkout, and on a non-ext4 mount flatpak-builder aborts with `Can't initialize ccache use: Failed to set permissions of /workspace/.ccache/disabled/ccache.conf: Operation not permitted` | `Dockerfile.package` ENV contradicting `01-core/compiler-cache.sh`'s own `/var/cache/*` defaults |
| 2 | `rustup: could not create temp file /usr/local/rustup/tmp/...: Permission denied (os error 13)` — Corrosion, cargokit and `flutter_rust_bridge_codegen` cannot run; not fixable by repointing the var, the toolchains live there | both `/usr/local` COPYs carried no `--chown`, and the foreign-arch re-install runs as root |
| 3 | `flutter build apk` → `[!] No Android SDK found`, surfacing three steps later under CodeQL as `bundle source directory not found: build/app/outputs/flutter-apk` | `ANDROID_HOME`/`ANDROID_SDK_ROOT` are declared in `Dockerfile.android`, which `latest-cross` does not inherit |
| 4 | `flutter pub get` → `Cannot open file .../flutter_tools/.dart_tool/package_config.json (Permission denied, errno = 13)`; 37 root-owned paths under `/opt/flutter` | the COPY `--chown` is right, but a root-run `flutter`/`git` wrote into the SDK AFTER it |

The fixes are in (`Dockerfile.package` ENV + two `COPY --chown`,
`hand_root_created_paths_to_runtime_user` in `setup-package-image.sh`, the
`check_consumer_contract` gate in `smoke-runtime-image.sh`, and the new
`dockerfile-lint` ENV-ordering pass), each with a suite case and a mutation that
bites. **None of it has been through a build**, and the split is measurable rather
than guessed. Running the real probe in the shipped image with only the new ENV
injected returns `ASSERTED 3`:

* defects **1 and 3 are ENV-only** — `/var/cache/{ccache,sccache}` is already 1777
  and writable at uid 1001, and the appended `PATH` survives `bash -lc`, so those
  two rows already go `OK` on today's bytes. What the build must confirm is only
  that the strings are baked: `nerdctl image inspect` the new `:latest-cross-*` and
  read `Config.Env` (this stage is built on a rootfs export that drops the parent's
  `Config.Env`, so a value that is not declared here ships UNSET).
* defects **2 and 4 need the rebuild's ownership work** and cannot be confirmed
  from outside. Probe the rebuilt image as uid 1001 with the consumer's own script;
  the two lines that only a build can answer are
  `find /usr/local/rustup /usr/local/cargo ! -user 1001` and
  `find /opt/flutter -user root`, both of which must come back empty on **all three**
  arches (riscv64's `/opt/flutter` ships empty; `check_consumer_contract` exempts
  its two flutter rows and fails the day upstream publishes a riscv64 SDK).

Also watch the **layer cost**, because the whole shape of the fix is a size
argument: `COPY --chown` and a same-RUN `find ! -user … -exec chown -h` are both
zero-byte, where a later `chown -R` would copy up ~2.2 GB of rustup+cargo and
~700 MB of Flutter per arch. A per-arch image that grew by gigabytes means BuildKit
did not do what the argument assumes. `rust.handover-only-root-owned`,
`flutter.bootstrap-whole-tree-chown` and `flutter.bootstrap-inline-chown-copy` are
the size rule recorded as tests.

**Two things the consumer flagged as NOT defects, both worth acting on:**

1. **Advertise `/opt/flutter`.** The image ships the Flutter SDK there, and
   consumers still passing `--flutter-dir /workspace/flutter` re-download it on
   every run for nothing. It belongs in the consumer-facing image docs beside the
   contract table — as does the note that `/var/cache/ccache` is not a `VOLUME`, so
   a consumer who wants the cache to survive teardown now mounts one there.
2. **The multi-arch index fixed their arm64 lane.** `:latest-cross` is a proper
   OCI index now; before it, their arm64 job pulled x86-64 binaries and died with
   `rustc: 1: ELF: not found`. Nothing to do, but it is the payoff line for the
   manifest work and should not be forgotten when the index shape is next touched.

Still open, deliberately, and none of it in this entry's scope: the shipped image
also drops `CCACHE_MAXSIZE`, `SCCACHE_CACHE_SIZE`, `SCCACHE_CONF`,
`SCCACHE_IDLE_TIMEOUT` and `SCCACHE_ERROR_LOG` through the same rootfs-export
(a value decision — base says 30G, `compiler-cache.sh` says 10G); `common.sh:352`
still defaults `CCACHE_DIR` to `${HOME}/.cache/ccache`, outside the new pin; no JDK
ships in any arch, so `ANDROID_HOME` is necessary but not sufficient for
`flutter build apk`; the Android host tools are linux-x86_64 on every arch;
`flutter_tools/.dart_tool/package_config.json` resolves every package to
`file:///root/.pub-cache`, 145 MB shipped under mode-0700 `/root` (latent today,
fixable with `PUB_CACHE=/opt/flutter/.pub-cache` in the same RUN); the foreign
arches still ship the builder-arch rust toolchain twice, because the
`ensure_native_rust_toolchain` `rm -rf` only writes overlay whiteouts; and
`flutter_rust_bridge_codegen` asks for a floating `nightly` the image does not
carry (it pins `nightly-2026-06-28`), so with a writable `RUSTUP_HOME` it now
succeeds but downloads one per CI run. `Dockerfile.nvidia`'s ENV-ordering fix is
in the same class as `Dockerfile.android`'s but was proven by reading only — no
nvidia image exists on this host.

### CL1. Eight closure files changed SHAPE with static proof only [S to watch, ★★★]

**Nothing the 2026-09-04 waves changed under `01-core`, `02-toolchain`, `03-media`,
`05-frameworks` or `06-packaging` has been through a build.** Every edit carries a
suite case and a mutation, and every mutation bites — but a suite cannot execute a
Dockerfile stage. This list is wave 1's; the second wave added exactly one closure
edit, a `# Docs:` comment in `flutter_checks.sh`, and nothing to watch for it.
Seventeen files under those five directories changed in wave 1's commit;
`git show --name-only --format= 4dcbd4eb | grep -E '01-core|02-toolchain|03-media|05-frameworks|06-packaging'`
is the authority, not this list (it was `git status` while the wave was uncommitted,
which stopped being true the moment it landed). Nine of them changed only by gaining a
`: "${NAME:=default}"` line (see the two shapes at the end of this entry); the
eight below changed SHAPE, and are the watch list for the next 3-arch run. It
costs nothing to keep and closes the moment a green chain reports.

| file | change | what the log should show |
|---|---|---|
| `01-core/compiler-resolution.sh` | `derive_cxx_from_cc` now returns 0 with empty output instead of the test's status | the arm64/riscv64 SDK stages are the only paths that hit the g++-not-found fallback; a refusal there must still name the missing compiler, not die under `set -e` |
| `01-core/cross-env.sh` | `_cross_env_resolve_tools` tests the VALUE (`[ -x "${_ert_out[cxx]}" ] \|\| return 1`) | with the change above, this is the only thing stopping a stage sailing on with `CXX` empty |
| `build-cross-chain.sh` | `_chain_on_exit` is an `if`, not a trailing `&&` list | a chain that finishes GREEN must exit 0; the trap only fires at real teardown |
| `03-media/.../patch-gstreamer-sources.sh` | patch 006's guard is an `if` | a tree WITH `gst-libav` must still apply the patch — the suite proves only the absent path, and stubs `_apply_patch` |
| `01-core/cpython-dev-packages.sh`, `03-media/runtime/verify-media-artifacts.sh`, `03-media/build/ffmpeg/build-ffmpeg.sh` | five dead functions deleted | a caller that BUILDS the name at runtime (an `eval`, a `"${prefix}_optional"` nameref, a Dockerfile `RUN` assembling it) is invisible to grep; only a real base→media chain proves none exists |
| `01-core/versions.env` | `CUDA_ARCHITECTURES` quoted | the quotes are stripped by `load_versions_env` and never reach the `--build-arg` (proven, 220 args byte-identical). Only a CUDA-enabled media/nvidia stage proves they do not reach `-DCMAKE_CUDA_ARCHITECTURES=` and defeat the ONNX build's trailing `90` → `90a` rewrite. Check the cmake argv of the first nvidia build |
| `01-core/disk-guard.sh` | the buildkit-store fallback (DISK1) | see DISK2 — five separate things only a live run can answer |
| `06-packaging/smoke-runtime-image.sh` | `check_manifest_tree_arch` + fatal advert arms | see HT2 |

Two shapes that would be silent if wrong: an operator whose shell still exports
`MYPROJECT_GCC_TOOLCHAIN_PATH` is now ignored rather than erroring (the docs row
says so), and eleven of the thirteen `: "${NAME:=default}"` conversions sit at
file top level, so any Dockerfile `RUN` that *slices* a script rather than running
it whole would read an unset variable. One such case was caught statically —
`IREE_CROSS_BUILD_COMPILER` had to move INSIDE `build_iree_wheels()` because
`test-iree-wheelhouse-stages.sh` awk-extracts that block alone — and a second
would look identical.

### CL2. `build_python.sh:365` keeps a second extension-module list [S, ★★]

`local -a _optional_exts=(zlib _bz2 _lzma _ssl _hashlib _ctypes _sqlite3)` is
exactly the third truth `cpython-dev-packages.sh`'s header used to claim the
`_CPYTHON_EXT_DEV_PKG_TABLE` had absorbed. It never had: the wave deleted the
table's only two ext-module accessors as dead, so the `<ext-module>` column now
has **zero** readers, and the false "All of those sites now derive from this
table" was corrected in the header rather than by wiring line 365 up.

Wiring it is **not** mechanical: the table calls `_sqlite3` **required** while the
array treats it as **optional**, so the change flips an assert from warn to fatal
on all three arches. That needs a build, not a suite. Either wire it and take the
stricter verdict deliberately, or delete the unread column.

### CL3. `export_clang_gcc_toolchain_env` is redundant with the clang wrappers [S, ★★]

**The question this entry carried for two groomings is ANSWERED (2026-09-04); what
is left is one decision, and it wants a build window.**

Clang *is* the compiler on one path: `install_cross_clang_wrappers`
(`02-toolchain/llvm.sh:98`) writes `clang-<arch>` / `clang++-<arch>` wrappers. But
each wrapper already bakes `--gcc-toolchain=${gcc_prefix}` into its own `exec`
line (`llvm.sh:91`), from the same `gcc_toolchain_prefix()` in `cross-gcc.sh` the
env function uses. And nothing in the tree sets a bare `CC=clang`
(`grep -rn 'CC=clang' linux/ --exclude-dir=tests` is empty). So
`export_clang_gcc_toolchain_env` (`01-core/cross-gcc.sh:44`) is **redundant with
the wrappers, not load-bearing for them**: the `--gcc-toolchain` flags it exports
never reach a compile.

Two facts the earlier framing did not have, and both matter to the decision:

* its guard `case $(basename "${CC:-}") in clang*)` also matches `clang-arm64`, so
  a wrapper used as `CC` would get a **second** `--gcc-toolchain` appended on top
  of the baked one;
* the two disagree on the missing-prefix case — the wrapper falls back to `/usr`,
  the function warns and exports nothing. Two policies for one question.

**The decision left is delete-vs-wire**, and it is a closure edit that removes a
documented operator switch plus its knob row, its suite
(`tests/test-cross-gcc-toolchain-knob.sh`) and its row in
[`linux-cross-builds.md`](linux-cross-builds.md) — where the verdict above now
lives, so a reader hits it before this file. Take it in CL6's window and watch for
any stage that ASSEMBLES the assignment at runtime: a Dockerfile `RUN` building
`CC=clang…` from parts is invisible to the grep above, exactly the way CL1's
deleted functions are.

### CL4. A bare `docs/*.md` pointer is invisible to `doc-links` [S, ★]

**The instance is fixed.** `05-frameworks/flutter/flutter_checks.sh:5` read
`# Docs: docs/linux-reference.md.` — the quarantined general-Linux cheat-sheet,
which says nothing about that script. It now points at
`docs/code-quality-tooling.md#dart-file-enumeration`, the section that owns
`code_quality_find_dart_files` and the "never `dart format .` in a CI lane" rule,
and mutation `doc-links.flutter-checks-anchor` renames that heading to prove the
gate can now see the pointer at all.

**The general half is open, and is now decidable rather than a guess.** Re-derived
from `verify_doc_links.CODE_POINTER` on the integrated tree: **377** code pointers,
**89** anchored, **288 bare**. A "bare pointer is worth a note" gate therefore
starts at 288 raw findings — many of them legitimate, because a sentence naming a
whole page is not a broken pointer. That is not a gate; it is a second frozen
ratchet.

**The version that IS actionable:** narrow the rule to FILE-HEADER pointers only —
the house comment rule already says a header ends in a `docs/*.md#anchor` — which is
**45** on 2026-09-04 — bare pointers in the first ten lines of a `.sh`/`.py`
file, e.g. `build-cross-chain.sh:5`, `lint-shell.sh:5`, `compiler-cache.sh:4`,
`lib/slang-compile.sh:7`. The count depends entirely on where you draw the set,
so re-derive it, never quote it: 53 over all code files, 45 over `.sh`/`.py`,
46 over comment lines only. The earlier "42" reproduced under none of those
readings, which is why the definition now travels with the number:

```
python3 -c 'import sys,io; sys.path.insert(0,"docs/scripts"); import verify_doc_links as V
print(sum(1 for p in V.code_files() if str(p).endswith((".sh",".py"))
          for ln in io.open(p,encoding="utf-8",errors="replace").read().splitlines()[:10]
          for m in V.CODE_POINTER.finditer(ln) if "#" not in m.group(0)))'
```

Act when someone is willing to write that many anchors; leave it otherwise.

**Gate-scope note, worth keeping whatever is decided:** `doc-links` scans
`docs/scripts/`, which includes `mutations.json`. Any mutation whose `find` or
`replace` text contains a `docs/*.md` pointer therefore turns the REAL tree red —
which is why the mutation above had to break the target *heading* instead of the
pointer. `dead-functions` already skips the manifest for the same class of reason
(`dead-functions.mutations-manifest-skipped`); `doc-links` does not. Arguably
correct as it stands (a pointer inside a mutation's `find` string should stay
valid), so this is a decision to record, not a defect to fix.

### CL6. Eight closure clean-ups wave 2 found, judged, and did not make [S, ★★]

Every one of these was read in full, judged behaviour-neutral, and left alone for
the same reason: the file is inside the build closure, a stage copies and executes
it, and nothing static can prove a chain still runs. They are cheap and they share
one window — **the same window CL1 needs**. Each already carries its verdict in its
own allow row; that row is the authority, this is the checklist.

**Four rows that are real dead code** (`shellcheck-warnings.allow`, SC2034 — seven
findings across four files). All locals or leaf assignments, so all four are
behaviour-neutral deletions — and each deletion must re-baseline its row in the same
change, or the four-way contract fails on the unrecorded shrink:

* `01-core/stage-defs.sh` — in `cross_stage_validate_graph`, `dockerfile` and
  `tag_fn` are declared and never used, and `chain=(${stage})` is written and never
  read (the cycle check counts depth instead).
* `01-core/python_uv.sh` — `g` in `local conflicted=0 g x y`; the inner read uses
  `x` and `y` only.
* `03-media/.../gstreamer/common/pre-setup.sh` — `gi_bindir` / `gi_libdir` are
  superseded by `target_gi_bindir` / `target_gi_libdir`. **The header comment at
  `:195-197` still lists them, so comment and code move together.**
* `04-runtime/gstreamer-env.sh` — `SYSTEM_LIB` is computed in both `TRIPLET`
  branches and read nowhere (`MULTIARCH_DIR` beside it is used four times).

**One MIXED row that must not be split** — `build-runtime-manifest.sh` SC2034 is
frozen at 3: `PUSH_IMAGES` and `PUSH_INTERMEDIATE_IMAGES` are real out-vars, but
`r` in `_manifest_wrapper_gate`'s local list is dead. Dropping `r` alone takes the
row 3 → 2, which the four-way rule FAILS as an unrecorded shrink. Code fix and
re-baseline land together or not at all.

**Two SC2206 quotings** — `01-core/cross-env.sh:680` and `02-toolchain/build-clang.sh:280`
and `:283` pass unquoted `${...}` into cmake argv arrays. Quoting is a strict
improvement and behaviour-identical for every value those knobs can hold today.
The only real risk is a cmake argv that stops being one word, which is exactly what
a build shows and a suite does not.

**One split** — `03-media/.../build-gstreamer-monorepo.sh | _gst_monorepo_tflite_flags`
(cc 18) is three unrelated TFLite workarounds under one name: the cross pkg-config
probe that emits `-idirafter`/`-L`/`-rpath-link`, the idempotent sanitizer for the
stray `}` an old `generate_pkgconfig_file` left in `tensorflow-lite.pc`, and the
symlink farm that exists only because Meson probes via `-print-file-name` and
ignores `-L`. Seams are clean; only an arm64 **and** riscv64 monorepo stage that
still resolves TFLite proves the split. (Its sibling from the same extent fix,
`override_soundtouch_codeberg_checksum` cc 16, was reviewed and is a **KEEP** — all
16 paths are refusals to re-pin, and merging any two trades a named WARNING for a
silent TOFU re-pin.)

**One that is not a build question at all** —
`06-packaging/package_archive.sh` parses `--appdata-file`, `--app-id` and
`--appimage-extract-and-run` and then ignores them (`APPIMAGE_EXTRACT_AND_RUN=1`
is exported unconditionally), and assigns `ResolvedBinary` with an explaining
comment and never reads it. **Nothing in this repo invokes
`package_archive.sh`.** Decide whether the script has a consumer before spending
anything on it; the flags mislead a reader, not a build.

**And one flagged, not changed:** `vulkan.sh:268` is the one `SC2155` in the tree
whose masked callee is not trivially total —
`export PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir …):${host_pkgconfig}"`.
`cross_pkg_config_libdir` only probes directories today so it cannot fail; if that
ever changes, the failure is silent and `PKG_CONFIG_LIBDIR` keeps only the host
path.

### GH1. Nothing runs the other ~316 mutation entries between commit and CI [M, ★★]

The pre-commit hook samples at most `PRECOMMIT_MUTATION_CAP` (**16** since
2026-09-04) of the entries whose target is staged, newest first, and says so. CI
runs all **332**. Between the two there is nothing.

A **pre-push hook** is the right home: `--changed`'s existing semantics
(everything committed since `origin/main`) are exactly push semantics, and a batch
pays once instead of per commit. Sharding made the price reasonable — the full
332-entry gate is **2m06s** at the default `--jobs 8` on a 32-core host, and
`--changed` over a branch is a fraction of that.

**Still blocked on one thing:** `verify_gate_registry.py`'s `HOOK` constant is a
single path, so adding `linux/host-config/git-hooks/pre-push` makes the generated
table report the `mutations` slug as CI-only — a false statement in a generated
file. Generalise `HOOK` to a list (`hook_slugs`, `hook_tier` and `hook_blocks` all
read one text today; union them), THEN add the hook, with its own case set.

**Memory note, new 2026-09-04:** the default `--jobs 8` holds eight ~200 MB
mirrors, ~1.6 GB of `TMPDIR`, and on this host `/tmp` is tmpfs. Fine for CI and
for an idle machine; a hook firing during a live cross build now peaks higher than
it used to. `--jobs 1` is the escape hatch. If it turns out to matter, lower the
default rather than dropping the sharding.

### GH2. The shared `(count, reason)` allow reader is half landed [S, ★★]

`quality_allow.load_rows(path, keys, fmt) -> {key: (count, reason)}` shipped and
`verify_shellcheck_warnings.rows()` was deleted in its favour; a malformed row is
now `ERROR: <file>:<line>: expected '<fmt>'` at exit 2 instead of a
`ValueError` traceback, and an inline `#` no longer truncates a reason.

**`docs/scripts/verify_code_dupes.load_allow()` still carries its own parse**, and
moving it needs the shared reader widened first. Two concrete blockers, both
measured:

* its duplicate-row check is intrinsically about the UNORDERED `frozenset` key, so
  `a | b` and `b | a` must collide;
* its message quotes raw line numbers (`code-dupes.allow:2: duplicate row …
  (first at line 1)`) that `load_rows` does not surface, and both a suite case and
  the `code-dupes.duplicate-row` mutation pin that wording.

The clean close is one commit: widen the reader to `{key: (count, reason, lineno)}`
and update all four call sites. Note the docs/ ↔ linux/ boundary — that file's
docstring advertises "No network, no project imports", so importing `quality_allow`
needs a `sys.path.insert` plus a corrected docstring, and `test-code-dupes.sh`'s
`_fixture` must start copying `quality_allow.py` into `${fix}/linux/scripts/`.

**Two smaller pieces of the same item.** `keys=None` is a transitional
compatibility mode that reproduces the old arity-from-the-right exactly, and it
keeps the mis-keying alive for `code-complexity.allow`, `function-size.allow` and
`file-size.allow` — a `|` in one of those reasons is now a named error rather than
a traceback, but it is still an error. Declaring `keys=3 / keys=2 / keys=1` at
those three call sites is a two-line follow-up. When complexity does declare
`keys=3`, its own `check_rows()` `len(key) != 3` branch becomes dead and the
`code-complexity.allow-row-arity` mutation becomes unkillable — delete both in the
same commit.

### GH3. `trailing-conditional`'s four false negatives [S each, ★–★★]

The gate shipped 2026-09-04 with 18 frozen predicates and four live defects fixed.
All four remaining limits are false NEGATIVES by design — a noisy gate earns an
allow row, and an allow row is cover — and are written up in
[`code-quality-tooling.md`](code-quality-tooling.md#trailing-conditional-returns-trailing-conditional):

the last-statement-only rule, the block closer, the trusted top-level `||` and the
one-line definition. Do not restate them here; that page has the shapes and the
named instance for each.

Closing the first two is real work and worth doing only if the shape kills another
build. Sitting next to them, not fixed and out of the gate's reach: the sibling
fallback at `01-core/cross-env.sh:433` is still an `a && b || c` chain
(`[ -x "${_cxx_fb}" ] && _ert_out[cxx]="${_cxx_fb}" || return 1`). Correct today,
and exactly the shape SC2015 warns about.

### GH4. The env-knobs owner scan reads no `arch-flags-*.env` [S, ★★]

Thirteen build-window knobs were re-homed to `: "${NAME:=default}"` at their
readers this wave and their registry rows deleted. **`MEDIA_SKIP_CSOUND` was
deliberately NOT converted and must not be**: its value is DATA, not an operator
choice — `03-media/core/arch-flags-riscv64.env` sets it to `1` and
`arch-flags-arm64.env` to `0`, and `media_load_arch_flags`
(`03-media/core/common.sh:65`) sources whichever matches the target arch. A
`: "${MEDIA_SKIP_CSOUND:=0}"` at a reader would be a second, competing claim.

The real gap is the gate's scope: `lint-env-knobs.sh`'s owner scan reads
`versions.env`, Dockerfile `ARG`/`ENV`, and script-side assignments in `*.sh` —
and nothing reads `03-media/core/arch-flags-*.env`. Teaching it that file set
re-homes `MEDIA_SKIP_CSOUND` and its four `MEDIA_SKIP_*` siblings properly and
shrinks the registry by five more rows.

**Two owner shapes the scan will deliberately still not count**, unchanged:
`-e "NAME=$(...)"` container-env injection (`RT_PROBE_SH`, `SMOKE_ONNX_PY`,
`RT_TREE_PY`) and `NAME=value` words passed to a test helper that later
`export "$@"`s them (`BUILD_RC`, `DISK_OK`, `HAS_PINNED_BASE`, `TRANSIENT`). Both
carry the name inside a quoted word, so counting them means un-masking string
content — the exact hole the 2026-09-04 walker closed. They are honest allow rows.

### GH5. Twelve preflight slugs are frozen as unproven [M, ★★]

`gate-registry` reports **34 slugs; 22 proven; 12 unproven, 12 frozen in
`gate-proofs.allow`**. Three left the freeze on 2026-09-04 — `doc-dupes`, then
`stdout-returns`, then `pkg-names` — and the new `trailing-conditional` shipped
proven.

**The "cheap sweep" an earlier version of this entry prescribed cannot be run as
written, and that prescription stays deleted.** It said to take the rows whose
`mutations` column is `—` and write a `return rc → return 0` mutation "and see
whether its suite survives". Measured: all twelve have BOTH an empty tests list and
an empty mutations list (`verify_gate_registry.rows()` — copy-coverage,
critical-fixes, patch-integrity, arg-consistency, version-snapshot,
mirror-consistency, runtime-paths, dockerfile-lint, workflow-lint, secret-scan,
android-parity, sbom). There is no suite for the mutation to turn red; the
experiment has nothing to run.

What actually closes a frozen row is **writing the suite**. Two worked examples now
exist: `stdout-returns` (16 assertions over throwaway trees at the gate's own
`parents[2]` depth, four mutations, one new doc section) and `pkg-names` (a
20-assertion characterisation suite driving the extractor through its real `--list`
CLI in a throwaway tree, plus seven mutations). The nine remaining
tree-consistency checkers are the cheapest next batch because they share that
shape.

**One trap this wave hit and someone else will.** `dockerfile-lint` was one signature
away from leaving the list for the wrong reason. A mutation that edits
`lint-dockerfiles.sh` and is caught by the **shellcheck ratchet** would be credited
to `dockerfile-lint` by the registry's mechanical rule (`target in own_files`) and
the row would read `proven` — while nothing had proved that the hadolint gate itself
can fail. That entry was therefore **not** written. The rule is: the mutation's test
must be the SLUG'S OWN proof, not any gate that happens to notice the edit.

The hollow-mention hazard the entry also named is real but lives among the 22
**proven** slugs, not these twelve: the test half of the proof is still a mention
(`[t for t, txt in tests.items() if mentions(needle, txt)]`), so a suite that names
a gate's script and asserts nothing about it still reads `proven`. The mutation half
is no longer circular.

### GH6. Two holes in `dead-functions`, one narrow and one deep [S / L, ★★]

* **Narrow, and CL3 is the live instance:** a function that names itself in a
  `printf` reads as used, because the corpus scan strips comments and definition
  heads but not string literals. Cheap to close.
* **Deep — same-name masking:** one name table for the whole corpus, so a dead
  `log()` is kept alive by a live `log()` anywhere. Every short helper name is
  unguarded. The interim mitigation landed 2026-09-04: `--census` now has a second
  tier keyed on `(file, name)` — definitions their own file never names again
  whose name a **second file also defines** — reporting **93** of the 410
  candidates today, which is exactly the surface where the gate's verdict comes
  from a name it does not own. (The first tier is still inert: `0 of those in a
  file that sources nothing and that nothing else names`, which is why the second
  tier had to exist.) That is a watch list, not a fix. Closing it properly needs `source_module`-
  aware scoping, i.e. a real call graph.

One smaller note on the same gate is still open: the census's own headline figures
in `code-quality-tooling.md` are re-typed prose that nothing derives — which is how
they came to be wrong by 11 functions and 8 rows before 2026-09-04. Deriving them in
`test-doc-numbers.sh` the way it already derives the manifest totals is the obvious
fix, and that file's `--update` mode makes it small.

**The `_fixture` note is closed, and it was bigger than it read.** Migrating
`test-dead-functions.sh`'s tree builder onto `tests/gate-tree.sh` made the two
`_fixture` bodies IDENTICAL and `code-dupes` immediately found a fresh 13-shingle
pair — the duplicated unit was the whole fixture, not just the tree builder. The
owner is now `gate_tree_subject <allow-name> <subject> <allow> <module.py>…`, both
`test-dead-functions.sh` and `test-trailing-conditional.sh` are three-line calls to
it, and two mutations (`gate-fixture.plants-the-subject`, `.plants-the-allow`) hold
it — one aimed at each consumer on purpose. All nine pre-existing
`dead-functions.*` / `trailing-conditional.*` mutations were re-run through the new
fixture and still bite, so the refactor hollowed neither suite.

### DISK2. The buildkit fallback is not wired into the two `build-cross-chain.sh` gates [S, ★★★]

DISK1 shipped where it bit: `_disk_guard_buildkit_fallback` runs
`buildctl prune --filter type==regular --keep-storage <keep×1000>` after the
cache-export trim comes up short, once per caller, and credits what it reclaimed
in the `[disk-reclaim]` line. The 2026-09-03 incident took the in-stage watchdog
path, so the defect is closed where it happened. Behaviour, log lines, the
120-vs-40 keep-storage reconciliation and the 100 GB floor are owned by
[`build-cache-tiers.md`](build-cache-tiers.md#321-the-buildkit-store-fallback-disk1).

**Two call sites in `build-cross-chain.sh` are still unwired**, and neither was
touched because another lane held the file:

* `_chain_runtime_lane_disk_gate` (~line 600) does `_disk_guard_trim_cache_export`
  → `_disk_guard_reclaim_record "runtime-lane-entry"` → `err`s the run out.
  Inserting `_disk_guard_buildkit_fallback "${bc_dir}" "${need}"` between the
  second and third lets a 415G store rescue the lane instead of refusing it.
* `_chain_stage_disk_guard` (~line 486) sets `CROSS_NO_LOCAL_CACHE_EXPORT=1` when
  its own LRU loop cannot reach the threshold; the same call belongs just before
  that give-up.

Pair the wiring with cases in `tests/test-chain-lifecycle.sh` — its lane-gate cases
stub `_disk_guard_free_gb` and would otherwise exercise a real prune.

**Five things only a live run can answer** (the suite proves the guard's shape, not
the daemon's behaviour): whether a mid-stage prune actually reclaims (buildkit
skips in-use records, so it may free far less than the 223G the between-stage
manual rescue got); whether the `exec.cachemount` records survive a prune issued
while a build holds them open; the wall-clock cost of the prune and of the
`buildctl du` reachability probe under load (36s was measured on an IDLE store,
and the watchdog runs on a 120s tick); whether `BUILDKIT_HOST` defaults correctly
for the chain's own uid in the rootless stack (only `prune-safe.sh` has ever run
that line, always from an interactive shell); and whether 120G of retained layers
is in fact enough to avoid recompile churn afterwards — the 100G floor is
inherited from a memory note, not from a reproducible measurement.

**One unresolved duplication:** `prune-safe.sh` and the guard both know the
filtered command and the GB→MB (`×1000`) keep-storage convention. No shared code
owner was extracted — `prune-safe.sh` runs `main` on load and cannot be sourced,
and it lives in `linux/host-config`. The overlap is ~3 lines and `code-dupes` does
not flag it, but the policy has one *written* owner rather than one *code* owner.
Sourcing `01-core/disk-guard.sh` from `prune-safe.sh` and calling
`_disk_guard_buildkit_prune` would close it. Worth one `buildctl prune --help`
check by a human with the daemon up: the `×1000` unit was inherited from what was
proven in anger on 2026-09-03, not re-derived against the installed flag
semantics, and a units change would silently turn 120000 into the wrong retention.

### HT2. The tree-arch exemption table is reasoned, not measured [S, ★★]

`check_manifest_tree_arch` shipped 2026-09-04 in `smoke-runtime-image.sh`: one
in-image scanner reads the ELF header of every object under each of the
**15** manifest trees and aggregates `(tree, machine) -> count`; anything that is
not the image's own machine is FATAL and names the tree plus an example path.
Design, probe-path arms and the no-vacuous-pass guards are owned by
[`artifact-copy-completeness.md`](artifact-copy-completeness.md#the-shipped-trees-must-carry-the-images-own-arch).

**The exemption table was reasoned, not measured** — that page's own
"What only a real build can tell you" subsection records which tree was ruled
in or out by reading which script, including the one tree the reading DID catch
(`/opt/vulkan` keeps the SDK's x86_64 host tools, so the gate probes
`/opt/vulkan/active`). What is open is the verification, below.

**What the first real run decides.** If any exempt tree still holds a legitimate
builder-arch helper the gate reds and names it, and the fix is one arm with a
written reason. Two trees could not be ruled out statically: `/opt/flutter`
(`bin/cache` can hold host-named engine artifacts even after the per-arch
bootstrap) and `/usr/local/rustup` (leftovers under `downloads/`). MISSING is
fatal by design — every manifest tree must exist as a directory — and no run has
confirmed all 13 non-exempt trees exist on all three arches;
`verify-artifact-copy-parity.sh` only proves the COPY line is written. The scan is
capped at 20000 files per tree with a deterministic sorted walk and reports
`TREECAP` when it hits; watch that INFO line and the added container-start cost
under QEMU.

The advertised-key half of the same file is proven the same way: static proof
covers the verdict function and the gate loop, but only a run proves the sixteen
remaining keys really are ENV-advertised and probe-readable on all three arches.
The 2026-09-04 run's own log is the evidence relied on (16 OK, `PYTHON_VERSION`
the single SKIP, zero "could not read" lines), so the new `UNSET`/`UNREAD` arms
should stay silent. If one fires, it is naming a real defect.

### YB. sccache loses thousands of cache entries per chain to an intermittent spawn ENOENT — MITIGATED 2026-09-03, root cause still open [medium]

**Read [`build-cache-tiers.md`](build-cache-tiers.md#what-was-measured-about-the-enoent-class)
first — it is the canonical record** and it already contains more than a fresh
investigation recovers: the 3062 bypasses of the 2026-09-01 run, the 2952x ENOENT
class on sccache's own `-E` pass, its intermittency in the heavily parallel steps
only, the absolute compiler path and live-build-dir cwd, the direct fallback of
the same argv succeeding right after, and the explicit instruction not to derive a
root cause from the message alone. (The launcher's own header is five lines now
and points at that section; it is no longer where the record lives.)

**Disproved by experiment 2026-09-03, so nobody repeats them:** the failing
`argv[0]` is never bare or relative; all six failing compiler paths exist and are
executable in the image; a plain sccache cross-compile returns rc=0; a
375-variable / 65 KB environment does not trigger it (and would be `E2BIG`). Two
lookalikes were reproduced and carry DIFFERENT messages: a missing `-MF` directory
is a compiler error *after* a successful spawn, and a deleted cwd gives
`Couldn't determine current working directory`. A 2026-09-03 re-derivation also
nominated `current_dir()`, which the record above had already ruled out — the cost
of not reading it first.

**MITIGATION SHIPPED 2026-09-03: the launcher retries once** before giving up the
cache entry. Behaviour, bounds and log lines are owned by
[`build-cache-tiers.md`](build-cache-tiers.md#the-single-retry-2026-09-03) — do
not restate them here. Guarded by `tests/test-sccache-launcher.sh` (14 assertions)
and mutation `sccache.retry-once`.

**MEASURED on the 2026-09-03 media-arm64 build, and the result is NEGATIVE:**

| outcome | count |
|---|---|
| `retry succeeded (cache kept)` | **27** |
| `failed twice` | **514** |

**~5% recovery.** So the honest answer to "is this class transient?" is **mostly
no** — a retry issued immediately does not get a different result. Keep the retry
(it is nearly free and 27 entries is 27 entries) but do **not** treat it as the
fix, and do not size the remaining work as if it were. A scheduling race or a
momentary resource shortage would recover far more than 5%, so neither is the
mechanism; something about the specific invocation fails repeatably within a short
window, which points at per-request state inside the server rather than at the
environment.

**One thing is still open here.** The measurement is now written down where it
belongs: [`build-cache-tiers.md`](build-cache-tiers.md#the-single-retry-2026-09-03)
carries the 27/514 table, the negative verdict and the cached-step caution, and its
opening premise was corrected in the same edit — it used to assert that "the same
invocation succeeds immediately afterwards", which is precisely what the retry
measurement disproved; what succeeds is the DIRECT FALLBACK. **That paragraph and
the `~5% recovery` paragraph above are a deliberate ownership split** (the doc owns
the measurement, this entry owns the interpretation) and they sit just under the
`doc-dupes` threshold — do not re-expand this one with the doc's wording or the
gate goes red, as it did at 47 shared shingles before the split.

**What remains: no fresh counts exist.** The 2026-09-04 run was `--only runtime`
and its log contains zero `sccache-launcher` lines, so 27/514 from the 2026-09-03
media-arm64 build is still the only data. Defer new root-cause work until the next
compile-heavy build (media or toolchain) can produce a second sample.

Reading the log needs one caution learned here: a **cached** BuildKit step replays
its old output verbatim. The first read of the 2026-09-03 build showed 496 hits of
the pre-retry message, all from one cached step (`#30`), which would have looked
like the new launcher failing to take effect.

### HT2. Five builder-arch LLVM libraries ship in both foreign images [M, ★★★]

The tree-arch gate, once it could see past its own file cap, found this in the
images shipped on 2026-09-05 — and it is exactly the class HT1 was written for:

```
/usr/local/llvm-target/lib/libLLVM.so.20.1      X86-64, in the arm64 AND riscv64 images
/usr/local/llvm-target/lib/libLLVM.so.21.1      X86-64
/usr/local/llvm-target/lib/libclang-21.so.21    X86-64
/usr/local/llvm-target/lib/libclang-23.so.23    X86-64
/usr/local/llvm-target/lib/libclang-cpp.so.21.1 X86-64
```

Five files, the same five on both foreign arches, in the tree that is supposed
to hold the TARGET-built LLVM. The rest of that tree measures correctly, so
this is not a wholesale wrong-arch copy: something adds host libraries to the
target prefix. The version spread is the clue — 20.1, 21.1 and 23 against a
pinned `LLVM_RELEASE=23.1.0`, so at least two of them are not even this
release, which points at Ubuntu's `llvm-20`/`llvm-21` packages rather than the
source build.

FROZEN, NOT WAIVED: `_RT_TREE_ARCH_FROZEN` in `smoke-runtime-image.sh` carries
the count, so a sixth file fails the gate and a fix that removes one fails it
too (the count moved). The list only ratchets down.

To close: find what writes those five into `/usr/local/llvm-target/lib`, decide
whether anything in the image loads them (they are libraries, so `readelf -d`
on the target binaries answers it), and either build them for the target or
stop copying them. Then delete the two frozen rows.

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are now fully reviewed: 33 function rows over 80 lines
and 68 `cc` rows over 15, every one carrying a verdict that says what its number IS.
Read the reasons, not the numbers.

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

**The next things to actually do — the first two are outside the closure:**

* **`verify_doc_dupes.py main`** — cc 23, 81 lines, the undecomposed twin of
  `verify_code_dupes.py main`, which is already decomposed at 85. The template for
  the fix exists in its sibling; mirror those helper names rather than inventing a
  second vocabulary. Cheapest real item in this entry.
* **`slang_compile_combined_wgsl`** (87) — its `while read` body is 50 of the 87
  lines with THREE distinct outcomes, so it extracts as `_slang_emit_one_wgsl`
  returning 0/1/2 with the caller keeping `wgsl_failed` / `wgsl_invalid`. The
  prerequisite is a fixture (a manifest JSON plus a fake `slangc`, which the
  function already takes as `$1`), not a build.
* Inside the closure the best-shaped candidate is `smoke-cross-all-arches.sh main`
  (96): five numbered probe sections sharing only the harness's pass/fail globals,
  so the helpers need no parameters.

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
local cache args survive — then extract.

### F2. Files over ~800 lines [L each, low priority]

**`file-size.allow` is the authority — do not transcribe it here.** The ten-row
table that used to sit in this entry was wrong within a day of being written, twice.
This entry's prose then broke its own rule again on 2026-09-04 by quoting
`smoke-runtime-image.sh` at 1739 when the allow file had carried the correct number
and the reason all along. The gate prints `files: 10 over 800 lines; 10 frozen`;
read it there.

**All ten rows were reviewed 2026-09-04 and nine are NOT split targets**, each with
a reason a stranger can act on. The file's own HEADER was the thing that had stopped
measuring what it claimed — it said "Shell files currently over the size limit"
while three of ten rows are `docs/scripts/*.py` and `linux/Dockerfile.media`, two of
those carrying the copy-pasted reason "newly in scope (python/Dockerfile)". Header
corrected to state `verify_code_size.py`'s actual scope.

**One row IS a real split, and it is blocked on coverage rather than on risk:**
`lib/agentic-loop.sh` (874) is two subjects wearing one name — engine adapters and
the loop driver — and it is outside the build closure, so it could be cut at any
time. Nothing covers it: `test-lib-smoke.sh` gives it parse + source-clean +
defines-a-function, and `test-lib-modules.sh` skips it by name. The row names the
three characterisation cases to write first: config load, one faked `invoke_agent`,
one drain of the executor queue.

**Two verdicts worth not re-litigating.** `build-app-wheelhouse.sh` is the
near-miss: the stage suites extract blocks from it **by line range**, so a file
split silently re-aims them. And `smoke-runtime-image.sh` — which every earlier
version of this entry nominated as THE one to split — is an explicit **NO**: 63
functions, all `check_*` / `_probe_*` over one image through one `_rt_run` under one
`main()`. Its length is the number of assertions it makes about the shipped bytes,
and that number growing is the gate succeeding.

**One small thing that will move a row when someone does it:**
`docs/scripts/sync_versions.py` has NO module docstring at all — shebang straight
into `from __future__` — despite being the authority for the version-propagation
ritual and despite its sibling `bump_versions.py` carrying a full one. It was left
undone only because no honest `docs/*.md#anchor` exists to end the header with yet.
Adding it also moves that file's `file-size.allow` row from 849.

### F3. Clone families worth one owner [S-M each]

The gate reads `3266 units in 352 files, no block over 10 shared 12-token shingles
(246 allowlisted pair(s); 801 shingle(s) suppressed as idiom at >6 owners)` on the
integrated tree. The decided/reviewed items (the source-or-fallback KEEP decision,
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
