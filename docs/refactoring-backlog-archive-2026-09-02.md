# Refactoring backlog — CLOSED 2026-09-02 (RVA23 rebuild window)

> Split out of [`refactoring-backlog.md`](refactoring-backlog.md) so that file
> shows only OPEN work. Nothing here needs action; it is kept because the entries
> record WHY a thing is the way it is — including several closed by being
> CORRECTED or REFUTED rather than fixed, the kind of finding that gets
> re-discovered if the reasoning disappears. Earlier rounds:
> `refactoring-backlog-archive-2026-08-10.md`,
> `refactoring-backlog-archive-2026-08-27.md`,
> `refactoring-backlog-archive-2026-08-30.md`,
> `refactoring-backlog-archive-2026-08-31.md`.

Closed during the RVA23 media rebuild (2026-09-01/02). Gates at closure:
48/48 shell suites green, `shellcheck -S error` clean tree-wide, duplication
gate OK (244 allowlisted pairs, **0** still unreviewed), full preflight green.
The rebuild itself proved the media stage on all three arches; the runtime lane
was still ahead when this cut was made.

**Two entries were rescued from this cut, not archived:** the runtime-smoke
standalone hang and the `preflight.sh` gitleaks death were filed under F7
(ArmNN), which they have nothing to do with. They are OPEN and now live under
F9 in the main file. Section H's LB10–LB13 likewise stayed behind — its header
says CLOSED, but four of its items are open work.

## C. Pre-existing, found while auditing 2026-08-31

- **`test-preflight-slugs.sh` feeds `comm` unsorted input — FIXED, and the last
  other call site closed 2026-09-02** [S·★★]. The test now runs
  `LC_ALL=C comm` over two `LC_ALL=C sort` inputs and carries a comment naming
  this bug; no "not in sorted order" warning remains.

  This entry's instruction — *"grep for other call sites while fixing"* — was
  audited 2026-09-02. `build-runtime-manifest.sh:140` and
  `test-codec-so-map-convergence.sh` were already correct. `lint-env-knobs.sh:58`
  was **not**: both its inputs are produced with `LC_ALL=C sort -u`, but `comm`
  itself ran in the ambient locale. `comm` checks sortedness in ITS OWN
  collation, so on a host that collates differently it would disagree with files
  this script sorted in C and report a wrong set difference — silently, since the
  gate prints only counts. Now `LC_ALL=C comm`; the gate still passes (635
  consumed knobs, all owned). ORIGINAL ENTRY:
  prints `comm: file 1 is not in sorted order` (×2) and still reports
  `5 assertion(s) passed`. `comm` on unsorted input does not compute a correct
  set difference, so its `_missing` / `_orphan` assertions may be passing
  VACUOUSLY. Not touched by the 2026-08-31 window (the file is unmodified), but
  it is exactly the toothless-gate class standing rule 5 is about. Sort both
  inputs, then re-check that the assertions still pass for the right reason.
  REINFORCED 2026-08-31: the same bug bit THREE times in one day while auditing
  (measuring ORT clone overlap, and twice while checking package lists), each
  time turning a real answer into a wrong one — `LC_ALL=C` changed "0 shared"
  into "36 shared" and "12 packages missing" into "1". Any `comm` in this tree
  wants `LC_ALL=C sort` on both inputs; grep for other call sites while fixing.

- **D2. Two package names are dead on Ubuntu 26.04 ports — RESOLVED, verified
  2026-09-02** [S·★]. `install-deps.sh:191` now calls `libopenexr-dev`, the
  correct name; the dead first attempt is gone. `libvvdec-dev` stays on purpose —
  the comment above it records that the package does not exist on ports at all,
  so the guard is deliberate and vvdec builds from source. Nothing left to do.
  ORIGINAL ENTRY:
  `libopenexr-3-dev` (renamed `libopenexr-dev`) and `libvvdec-dev` (gone
  entirely), both in `03-media/build/gstreamer/install-deps.sh:183,186`.
  Neither breaks a build — both already carry `|| …|| true` fallbacks, and vvdec
  falls through to a full source build — so this is cleanup, not an outage. But
  every run pays a failed apt round-trip and, for vvdec, an entire compile.
  NB the openexr fallback to the new name is already there; only the dead first
  attempt needs removing.

- **D5. Failed stages still write their cache exports — FIXED, verified
  2026-09-02** [S·★★]. `_cross_salvage_disk_ok` (`cross-stage-build.sh:44`) now
  gates the salvage on free space via `SALVAGE_MIN_FREE_GB`, falling back to
  `CROSS_DISK_GUARD_GB`, exactly as this entry proposed — "conditional on free
  space rather than on the operator remembering". ORIGINAL ENTRY:
  `cross-stage-build.sh:206` salvages local cache exports for all 15 named media
  stages after a FAILED build — burning disk on stages that will be rebuilt
  anyway, at exactly the moment disk is scarce. `SALVAGE_CACHE_EXPORT=0` already
  disables it; consider making it conditional on free space rather than on the
  operator remembering.

- **D7. Warning audit 2026-08-31 — do not repeat it** [closed, recorded so it
  is not re-done]. Every warning in a full 3-arch run was classified. ~12,700 are
  compiler warnings inside UPSTREAM sources (ONNX Runtime's
  `lifetime_capture_by`, glslang array-bounds, LLVM `PointerType::get`
  deprecations, Dawn) — not our code, not fixable here. ~50 more are upstream
  TOOLING noise: the Vulkan SDK's own profile parser (`jsonschema` module
  missing) and GStreamer `.gir` parsing. Exactly ONE was ours, and it is fixed
  (the OpenCV build-stage cv2 import check could never succeed; commit
  b3dbd32a). Counting warnings by grepping the log OVERCOUNTS badly: BuildKit
  echoes each RUN's command text, so warning strings inside a Dockerfile command
  are matched as if they had fired. Count only real output lines
  (`^#N <time> WARNING`) — that is the difference between "TVM build failed 23×"
  and "TVM built fine".

- **DC. A pinned stage's cache-export slug is dead weight, and nothing reclaims
  it — FIXED DIFFERENTLY 2026-09-02** [M·★★★, cost SIX manual interventions]. `kata-buildcache`
  is keyed per stage slug (`..._cross-media-riscv64`, `..._cross-android-amd64`,
  …). The moment `[stage X] pinned <digest>` is logged, that stage is built,
  pushed and will not be rebuilt in this run — its slug can never be read again,
  yet it sits on disk until the end. Measured 2026-09-02 in one `media..runtime`
  run: the three media slugs held **83 G** and the three android slugs **39 G**,
  all of it dead, while the runtime lane was starving.

  `_chain_stage_disk_guard` does prune this directory, but only below
  `CROSS_DISK_GUARD_GB` (40 G) — far too late for a lane whose own entry gate
  wants ~120 G, so the run either stops at the gate or needs a human. In that
  one run the free-space curve went 154 G → 78 G → (prune) → 191 G → 61 G →
  (prune) → 143 G, with every recovery manual.

  The fix is not a lower threshold, it is a *trigger*: reclaim a slug when its
  stage is pinned, not when the disk is nearly full. The chain already knows
  the moment (it logs it) and already knows the mapping (the slug is derived
  from the tag). Guard rails worth keeping: never touch the slug of a stage in
  the current build set, and keep the LRU path as the emergency backstop for
  everything the trigger does not cover. See [[rebuild-disk-management]] for why
  `nerdctl builder prune` must never be the answer here.

- **DD. riscv64 Node.js is FOUR majors behind the pin — CORRECTED, and it is a
  decision, not a defect** [S·★★, owner call]. The original wording here said the
  pin is "silently dropped". That was wrong on both counts, and reading
  `base-image.sh` corrected it: the fallback is deliberate, documented, scoped
  and has an escape hatch (`NODE_RISCV64_MAJOR_REQUIRED=1` restores a hard
  failure), and it warns **loudly** — the major-lag warning fired 5 times.

  What is worth an owner's attention is the *size*: pin `26.8.1`, installed
  `v22.22.1`. Four major versions, because ubuntu-ports lags and there is no
  official Node tarball for riscv64. The code's justification is that Node there
  only backs optional JS/web tooling (litert-web / onnx-web) that the Python and
  native runtime never import. That justification is sound **if it is still
  true** — so the question is whether that tooling works on Node 22, not whether
  the fallback should exist.

  No code change made. The mechanism is right; only this entry was wrong.

- **DE. `IREE_BUILD_COMPILER=OFF` does not produce `iree-tblgen` — FIXED 2026-09-02** [M·★★, costs a
  full host compiler build]. `[WARN] IREE host stage (IREE_BUILD_COMPILER=OFF)
  left /tmp/app-wheelhouse/iree-build-host/install/bin missing: iree-tblgen —
  retrying with the full host compiler`, twice in one run. The two-stage build
  in `docs/iree-two-stage-build.md` exists precisely to avoid that compiler
  build; the fallback works, so the cost is invisible in the exit code. Either
  the OFF stage needs `IREE_BUILD_TOOLS` (or whatever now gates tblgen) or the
  two-stage split should be retired as ineffective.

- **DF. The media ELF gate guesses whether a foreign-arch .so is a vendor blob — FIXED 2026-09-02**
  [S·★★]. It prints `MISMATCH (advisory, may be vendor): libpython3.14.so.1.0
  ELF machine=Advanced Micro Devices X86-64 != expected RISC-V` and then
  `NOTE: 3 advisory .so ELF mismatch(es) (likely bundled vendor SDKs; not
  failing)`. It logs **basenames only** and the word is *likely* — the script
  already carries a list of directories that legitimately hold foreign-arch
  vendor binaries (QNN, SNPE, NeuroPilot), so it could classify by path and fail
  on anything outside them. As written, a genuine x86-64 leak into a riscv64
  image would print exactly the same line as a MediaTek blob. (The three
  libpython hits are almost certainly the amd64 build container's own Python and
  therefore harmless — but the gate cannot tell you that, which is the point.)

- **DG. The media stage's qemu functional check has never passed on a foreign
  arch — REMOVED 2026-09-02** [S·★★]. `WARN: /usr/bin/qemu-riscv64 gst-launch-1.0 --help failed (may
  be expected for cross builds without full sysroot)` — 4× for riscv64 and 3×
  for arm64 in one run, for `gst-launch-1.0`, `cam` and `ffmpeg`, every one
  excused by the same clause. A check that always fails and is always excused is
  not a check; it is training to ignore WARN lines. Real functional coverage
  does exist later (the runtime-image smoke boots the actual image), so either
  give this one a sysroot or delete it.

- **AB. `onnxruntime-webgpu`'s dependency edges are dangling on riscv64 — FIXED 2026-09-02**
  [S·★★★]. `flatbuffers` and `protobuf` are declared requirements of the
  installed wheel and absent from the venv, so an import can fail in the user's
  process rather than in our build.

  Root cause is deliberate and must not be reverted: `assemble-torch-app.sh`
  installs every local wheel with `--no-deps --force-reinstall`, and its comment
  names this exact hazard — *"without it uv re-resolves the wheels' deps to
  LATEST and floats the venv off the lock (numpy, protobuf MAJOR)"*. The run
  bears the comment out: `protobuf==6.33.6` was installed twice and
  `protobuf==7.36.1` once across the three arches.

  **Correction:** an earlier draft of this entry called `PROTOBUF_VERSION=6.31.1`
  "a pin nothing honours". That was wrong — it is the **C++** protobuf runtime
  for LiteRT-LM, deliberately slaved to that project's internal pin, and
  versions.env says so. It has nothing to do with the Python package.

  Both packages publish a pure-Python `any` wheel, so neither is blocked on
  riscv64 and the fix is cheap: install them explicitly next to the local ORT
  wheel at the version the app lock already uses on amd64 (`protobuf 6.33.6`,
  `flatbuffers 25.12.19`). Do **not** drop `--no-deps`.

- **AA-followup. The optuna install was in the wrong place — FIXED 2026-09-02**
  [S·★★★]. Found by checking the AA/AB fixes against the lane they were about to
  run in, before the runtime stage got there. The install had two defects, either
  of which would have let the gate name `optuna` again:

  1. It sat in `reconcile_local_wheels`, which runs **before**
     `ensure_project_package_installed`. Measured against PyPI: optuna's closure is
     `any`-wheel everywhere **except `PyYAML`**, which publishes no `any` wheel and
     no riscv64 wheel — only an sdist. Run at that point it would source-build
     under emulation; run after the project install it is already satisfied. This
     is the same ordering the `docs` extra already documents.
  2. It was nested under `if [ "${#other_wheels[@]}" -gt 0 ]` — a condition about
     the ORT wheel set, unrelated to optuna. With no local `other_wheels` it would
     never have run at all.

  Moved to `install_fallback_project_extras`, which runs only on the riscv64
  fallback path and only after `uv pip install "${APP_DIR}"`. Both defects go away
  with the move; no new condition was needed. `protobuf`/`flatbuffers` stay where
  they are — they are the ORT wheel's own dangling edges and have zero runtime
  dependencies, so neither concern applies. Reasoning in
  docs/riscv64-venv-parity.md#optuna.

  Also verified while there: the AA exemption arms are keyed correctly. The probe
  normalises with `lower().replace("_","-").replace(".","-")`, and `scipy`,
  `scikit-learn`, `pandas` are already in that form, so
  `riscv64:ml-ai:<pkg>` matches. And optuna's `numpy` requirement is
  **unconstrained**, so the install cannot float the venv off the lock — the
  hazard `--no-deps` exists to prevent.

- **UB. Replace our OpenCV FFmpeg-8 patch with the upstream commits — DONE 2026-09-02**
  [S·★★★]. Upstream fixed this on `4.x` in `700cd32ffd` and `83ed22ca28`; `5.x`
  did not get it. Both are saved in `docs/upstream/patches/` and were verified
  to apply to `5.x` with **no conflicts**, after which our own patch no longer
  applies at all. Ours also guards on the wrong idiom
  (`LIBAVCODEC_VERSION_MAJOR >= 62` vs their `LIBAVCODEC_BUILD >=
  CALC_FFMPEG_VERSION(61, 13, 100)`) and trusts a `{0,0}` terminator where the
  new API returns a count. Swap ours out for theirs.

- **`verify-shipped-wrapper.sh` carried a private `_is_truthy`** — **DONE
  2026-09-02** (`e2da351c`). It now sources `01-core/platform.sh` via its own
  `_here` and uses the canonical `is_truthy` at all three call sites. Safe because
  `platform.sh` has **zero top-level statements**, so sourcing it has no side
  effects; the two `case` arms were byte-identical and a differential test over 21
  inputs (`True`, `tRuE`, `enabled`, empty, whitespace, …) agreed on every one.
  Verified in the manifest builder's exact invocation form — the gate reaches its
  own logic, so the `source` resolves at runtime and not merely under `bash -n`.
  The four `code-dupes.allow` pairs it needed were retired in the same commit; the
  gate itself flagged them as stale, which is the allowlist working as designed.
  The test stubs (`test-chain-lifecycle.sh`, `test-parallel-loop.sh`,
  `test-ffmpeg-dnn-contract.sh`) keep their own copies on purpose — a test that
  sourced the real one could no longer prove the shipped copy behaves. They are
  the 4-file family the gate still reports for this block, and that is correct.

### F4. The duplication gate's own defects [S each]

- **Clone-family clustering degenerates.** Union-find over shared files
  transitively collapses most of the tree into one meaningless "88 files"
  family. Cluster on the shared BLOCK, not on file adjacency.
- **The genai Python is STILL unlinted — FIXED 2026-09-02 in the EXTRACTOR, not
  the source** [was: re-measured 2026-09-02]. `extract-embedded-python.py` now
  assembles `cat`ed fragment FAMILIES (two or more sharing a marker prefix) in
  file order and emits them only when the result parses, so the 217 lines reach
  ruff without touching the runtime path or the four Dockerfiles that copy
  `smoke-common.sh`.

  **Three** defects surfaced while doing it, all silent: the marker class
  `[A-Z_]*` **excluded digits**, so `GENAI_PY_T1..T4` — four of six fragments —
  were skipped; and the interpreter pattern hard-coded lowercase `${py}`, so
  `"${PY}" - <<'PYEOF'` was not recognised and `assert_pinned_versions`' 312-line
  program had never been linted at all. Tree-wide coverage after the fixes:
  **16 files, 861 lines** of embedded Python now reach ruff. Both are now
  mutation-tested. A lone fragment is still never extracted: `ast.parse` catches
  syntax errors but not undefined names, so linting one alone reports bogus
  findings — the original rule was right about that. ORIGINAL ENTRY: `smoke_genai_py` went from one 196-line
  heredoc to six `_smoke_genai_py_tier*` helpers totalling **217 lines**, each
  emitting its fragment with `cat <<'GENAI_PY_T*'`. `extract-embedded-python.py`
  handles only **directly-executed** heredocs and says so; run against
  `smoke-common.sh` it reports *"no directly-executed heredocs found"*. So ruff
  sees none of it — and assembled fragments are harder to extract than the single
  heredoc was. Satisfying F1's length metric and F4's lintability goal pulled in
  opposite directions here; a real `.py` file that the smoke pipes in still
  settles both.

### F8. libyuv's RVV rows are dispatched but never compiled — FIXED 2026-09-02 [DONE]

Enabling the vector baseline made libcamera's bundled libyuv fail to link on
riscv64:

```
ld.lld: error: undefined symbol: ARGBBlendRow_RVV
ld.lld: error: undefined symbol: BlendPlaneRow_RVV
```

The first diagnosis written here was wrong. `row_rvv.cc` IS compiled — it sits in
`libyuv.a` as `source_row_rvv.cc.o`. It compiles to *nothing*, because the file
guards itself on `defined(__clang__)` while `row.h` enables all 57 `HAS_*_RVV`
entry points for any RVV compiler. Upstream has since dropped that clang gate;
`patches/libyuv/001-rvv-build-with-gcc.patch` backports exactly that change to
libcamera's pinned revision, and `verify_libyuv_rvv_rows` in `build-libcamera.sh`
fails the build if the rows are ever absent again.

Measured with our own cross GCC 16.2.0: 0 -> 54 (`row_rvv.cc`) and 0 -> 25
(`scale_rvv.cc`) RVV symbols, both previously-undefined symbols now defined. The
`-DLIBYUV_DISABLE_RVV` workaround is gone — vector stays on.
docs/riscv64-rva23-baseline.md#libyuv-rvv

The general shape to expect from the rest of the vector switch is recorded in
docs/riscv64-rva23-baseline.md#libyuv-rvv.

### F7. ArmNN + ACL — DECIDED 2026-09-01: ship them [DONE]

They were cross-compiled, stripped and verified on every arm64 chain and then
dropped at the package boundary: `Dockerfile.package` named them zero times, the
shipped image had neither directory, `libarmnn*` existed nowhere in it, and the
only `libarm_compute.so` present came with PyTorch's own wheel.

Owner decision: **ship them.** `Dockerfile.package` now copies `/opt/armnn` and
`/opt/acl` from `artifact-source` (safe on every arch — the media stage creates
empty dirs on non-arm64), and `configure-runtime.sh` writes `000-armnn.conf` so
they win their lookup like every other `/opt` tree.

Note the same shape is CORRECT for `/opt/tvm`, `/opt/pyav` and `/opt/app-wheels`:
their content is installed into `/opt/venv` (tvm and av are importable in the
shipped image). ArmNN had no such path.

### F6. Cache-key blast radius in Dockerfile.media — FIXED 2026-09-02, awaiting build proof [M each, measured]

Numbers from `out/build-logs/f2-media-validation.log` (2026-08-31, amd64, warm
ccache): the media stage is 134.3 min of RUN time across 90 steps, dominated by
app-wheelhouse 1523.5s, ORT `--step cpu` 1452.0s, tvm 1377.1s, litert 1353.6s.
The waste is not compute — it is over-broad mounts above that work.

Two are FIXED (2026-09-01): `verify-media-artifacts.sh` no longer sits in the
shared `base` stage (8 edits since 2026-08-01, each re-paying the whole media
stage on every arch), and `linux/qnn-sdk/*.md` is out of the build context (a
README-only dir mounted into the five heaviest RUNs).

**Both narrowings DONE 2026-09-02, pending build validation:**
- **ORT `--step cpu`** now mounts three paths instead of the whole
  `build/onnxruntime` tree: `build-onnxruntime.sh`, `30-build-native.sh` and
  `build/lib/`. Derived, not guessed — the `cpu|native)` arm dispatches to
  `30-build-native.sh` and nothing else, that script sources only
  `lib/common.sh` plus `source_build_acceleration_helpers` (which loads from
  `/opt/scripts/core`, already mounted), and it references neither
  `30-build-native-amd.sh` nor `-nvidia.sh`.
- **tvm** now mounts its five `tvm*.sh` files instead of all of
  `05-frameworks`. `tvm.sh` sources exactly four siblings, and none of them
  sources anything further in that directory — the rest of the tree is `torch/`
  and `flutter/`.

Still open here: the genai / wasm / js RUNs have the same over-broad shape and
were left alone, because unlike the two above they are not on the critical path
that the next build will exercise.

**The next media build is the proof.** A missed transitive `source` fails hours
in, so treat a green media stage as the close condition for this entry.

### F5. The duplication baseline is frozen, not reviewed [L, measurable]

`verify_code_dupes.py` reports OK, but that means **no NEW or GROWING** copy —
not "no duplication". Re-measured 2026-09-02: `docs/scripts/code-dupes.allow` now
holds **260** pairs (was 251), of which **236 still say "baseline 2026-08-31, not
yet reviewed"**. So nine pairs were added since the baseline and the unreviewed
tail has not moved at all — every pair reviewed so far was a NEW one.

**PROGRESS 2026-09-02.** The top pair is done: `build-runtime-artifacts.sh` ↔
`build-runtime-manifest.sh` went **199 → 28** shingles. The 17 option lines both
documented identically now live in `runtime_shared_usage_options`
(`01-core/runtime-build-fns.sh`), beside the `runtime_shared_usage_env_overrides`
that library already owned — those flags are handled BY the library, so the
duplication was a symptom of documentation living in the wrong place. `--help`
verified unchanged in content on both scripts.

That one change also **retired three allowlist entries** the gate then reported
as stale (`build-cross-chain` ↔ both runtime scripts, and manifest ↔
`build-sdk-artifacts`) — dedup at one site can dissolve overlaps at others, so
expect the list to shrink faster than the number of entries you touch.

Two entries were ADDED in the same pass, both honestly labelled: my own new test
cases had duplicated four lines of extract-and-count boilerplate (fixed with a
helper instead of an allowlist line), and `runtime-build-fns` ↔
`build-cross-chain` now share 14 shingles — recorded as *unfinished*, not
deliberate, because the chain orchestrator could call the same helper.

**Second pair done:** `iree/android/build-android.sh` ↔
`litert/android/build-android.sh`, **179 → 12**. The duplicated
`resolve_host_compiler` (source-or-fallback, ~25 lines) moved into
`android-build-preamble.sh`, which both already source and every android stage
shares. The iree copy's own comment said *"aligned with the litert copy"* — the
duplication was known and simply had no owner.

**That consolidation exposed a four-site family**, which is the more useful
finding: the same host-compiler-preference logic lives in
`01-core/compiler-resolution.sh` (canonical), the preamble's fallback,
`ffmpeg-probe-framework.sh` and `build-app-wheelhouse.sh`. The preamble copy is
the **bootstrap paradox** in its purest form — a fallback must duplicate the
thing it stands in for, or it is not a fallback. The other two are not, and
that family wants one owner.

Note the accounting: this pair's number fell by 167 while
`preamble ↔ build-app-wheelhouse` rose 29 → 40. Total duplication went DOWN (two
copies became one) even though one pair's number went UP, because the surviving
copy now sits in a file that already overlapped there. Read the totals, not a
single row.

**The unreviewed tail is CLOSED: 225 → 0 (2026-09-02).** Be precise about what
that means, because the distinction is the whole value of the entry:

| how | count | what was actually done |
| --- | --- | --- |
| READ | 4 | the pairs whose longest shared run exceeded 12 lines and were not already covered — each carries its own finding |
| MEASURED | 221 | longest shared run computed per pair; the reason records the number so anyone can re-derive it |

Measuring is a real review — it answers "is this a copied block worth extracting
a helper for?" — but it is **not** reading each file, and the reasons say so
("NOT read line-by-line; revisit if it grows"). The distribution it produced:

| longest shared run | pairs | reading |
| ---: | ---: | --- |
| ≤6, structural only (`fi`/`esac`/`}`/`echo`) | 87 | the shape of sibling functions, not a copy |
| ≤6, substantive | 88 | a shared idiom, below any extraction threshold |
| 7–12 | 41 | small; watched via a pinned budget |
| >12 | 9 | four already covered, four read here, one is the family below |

**The recurring shape across the biggest offenders is source-or-fallback**:
`path-helpers`, `compiler-resolution` and host-python each have a canonical file
plus an inline copy for when it is absent. That is the bootstrap paradox and the
copies are load-bearing — the useful question is not "dedup them" but "is the
fallback still reachable at all, now that every image ships the canonical file?"

Eight stale entries were retired along the way — three from the first pair, five
from the second. Final count: **260 → 243 pairs, 0 unreviewed.**

Work the tail from the top; each line deleted or shrunk is real progress and the
gate enforces the new, lower budget automatically:

| shingles | pair |
| ---: | --- |
| 199 | `build-runtime-artifacts.sh` ↔ `build-runtime-manifest.sh` |
| 179 | `iree/android/build-android.sh` ↔ `litert/android/build-android.sh` |
| 95 | `lint-shell.sh` ↔ `lint-workflows.sh` |
| 90 | `smoke-runtime-image.sh` (same file, two blocks) |
| 88 | `tests/test-tvm-cmake-args.sh` (same file, two blocks) |

Two pairs alone are 378 shingles — 6% of the whole baseline. Reviewing an entry
means one of: shrink the twin and lower the budget, or replace "not yet reviewed"
with the reason it is deliberate. Both are improvements; leaving it is not.

- **The advertised-version gate covered 6 of 31 keys** [DONE 2026-09-01] —
  `verify-advertised-keys.py` (preflight slug `advert-keys`) now fails when any
  version-shaped `ENV`/`ARG` in `linux/Dockerfile.*` is neither checked by the
  smoke nor excused with a reason, and when an excuse goes stale. 16 keys are
  checked, 16 excused. Probes were measured against the shipped image, and each
  mutation was proven to go red (`test-advertised-keys.sh`).

- **`VULKAN_VERSION` could not disagree with itself** [DONE 2026-09-01] — its
  HAVE side parsed the version out of `/opt/vulkan/active`, a directory named by
  the ARG under test. Now measured from the loader (`vulkaninfo`), falling back
  to `VK_HEADER_VERSION`. The class matters more than the instance: any HAVE
  probe that re-reads the advertisement is a gate that cannot fail.

- **An absent `PYTORCH_EXTRA` silently shrank the venv gate** [DONE 2026-09-01] —
  the empty case was folded in with the `none` sentinel, so an image that failed
  to advertise the extra had it dropped from the checked set. Now `NOADV` fails;
  only the literal `none` is a torch-less image.

- **`pkg-names` treated a partial index fetch as authoritative** [DONE
  2026-09-01] — one failed component (`universe`, say) truncated the name set,
  cached it, and would then report live packages as dead. Now all-or-nothing
  with an honest SKIP. Also: the vendor-repo exemption covered whole FILES, so
  the plain Ubuntu packages `setup-rocm-repo.sh` installs before adding the
  vendor repo (`curl`, `gpg`, `ca-certificates`) were unfailable; it is now
  name-scoped. And `apt_install_available` was in no installer table at all —
  6 cross-toolchain packages were extracted nowhere (118 -> 121 call sites,
  522 -> 529 names).

- **riscv64 now builds at RVA23 (RVV ON)** [DONE 2026-09-01] — the earlier entry
  here had the risk INVERTED and is corrected: the shipped image's own glibc and
  loader already require RVV 1.0 (997 `vsetvli` in apt's `libc.so.6`), so a
  board without a vector unit could never run this image. Our binaries were the
  only sub-baseline objects in it. The cross GCC now defaults to
  `rva23u64_zifencei`/`lp64d` — the exact string apt's libc carries — with
  OpenCV, ORT, Rust and the gst-plugins-rs cargo wrapper wired separately
  because they gate vector paths on their own switches. A new smoke gate reads
  `Tag_RISCV_arch` off the shipped objects. See docs/riscv64-rva23-baseline.md.
  OPEN: TVM and IREE emit code at RUNTIME, so they need a codegen-target change
  (`-mattr=+v,+zvl128b` / `--iree-llvmcpu-target-cpu-features`), not a compile
  flag. Also budget a COLD riscv64 build — this invalidates the warm cache.

- **The destructive-delete guard now works on Linux** [DONE 2026-09-01] — it was
  PowerShell-only and `pwsh` is absent on this build host, so the answer to the
  2026-08-21 host wipe was INERT exactly where the incident happened, and the
  second registration it claimed in the user-level settings did not exist.
  `.claude/hooks/guard-destructive-deletes.py` is a Linux port with the same
  protocol, wired ahead of the PowerShell one. It denies the filesystem root,
  system directories, `$HOME`/`~` roots, credential dirs, the containerd and
  buildkit stores, block devices and package removals, while
  `linux/host-config/prune-safe.sh`, `nerdctl rmi` and
  `rm -rf ~/.cache/kata-buildcache/*` still pass. Pinned by
  `test-delete-guard.sh`; emptying the rule table turns 7 assertions red.

- **LB1 — correctness probe** [DONE] `--correctness` / `--correctness-only`
  (exit non-zero on a wrong answer); `run_benchmarks.sh` gates the sweep on it
  (`BENCH_SKIP_CORRECTNESS=1` bypasses). Validated: Qwen3-4B `Q4_0` 6/6,
  `IQ3_XXS` 0/6 BROKEN — the case every speed metric rated as a good run.
- **LB2 — TTFT/prefill** [DONE] `ttft_s`, `prefill_tok_per_sec`,
  `decode_tok_per_sec` (the pre-existing `tokens_per_sec` divides by the whole
  request and so hides prefill inside what reads as a decode rate).
- **LB3 — time to a finished answer** [DONE] `wall_s_to_answer` +
  `thinking_char_share`. A live run showed **77–86 % of output was `<think>`**.
- **LB4 — multi-endpoint + concurrent aggregate** [DONE] new `bench_lanes.py
  --lanes`. Reproduced the manual finding within 0.5 %: NPU **+0 %** when a CPU
  lane joins, CPU **−18 %**, aggregate 39.9 tok/s = 1.57x the best single lane.
- **LB5 — batching probe** [DONE] `bench_lanes.py --batching`. Verdict
  `SERIALISED` on GenieX: second request's TTFT 74.27 s vs the first's 74.10 s
  total.
- **LB6 — GGUF introspection** [DONE] new `inspect_gguf.py`: header-only read,
  tensor-type histogram, OK / LIKELY OK / RISKY verdict, exit 1 on RISKY.
  Correctly separates the broken `IQ3_XXS` (97.6 % sub-4-bit i-quants) from the
  working 27B `UD-Q4_K_M` (0.8 %).
- **LB7 — de-Ollama'd** [DONE] `LLM_BASE_URL` (old name still honoured);
  `detect_model_via_api` asks `/v1/models` first and takes a `base_url`. The
  hardcoded `"gemma4:26b"` probe is gone — it returned that name on any 200,
  mislabelling every non-gemma host.
- **LB8 — worker vs listener** [DONE] `top_cpu_processes()` primes before and
  reads after each request, so the summary names the PID that actually burned
  CPU. Encodes the trap: GenieX's port owner read 11 % of 800 % while its
  worker sat at 752 %.
- **LB9 — cross-platform hardware info** [DONE] `platform`/`psutil` fallback
  after the `/proc` reads, plus an explicit `incomplete` list so a gap is
  visible instead of silent.

**Viewer + test debt closed 2026-08-31 (second pass).** The first pass wired
the new metrics into the result JSON but not into the React viewer, although
LB2/LB3 explicitly said "and the viewer" — the data flowed in and surfaced
nowhere. Now: a correctness banner above every speed number, time-to-answer as
the leading column, TTFT/decode/prefill/thinking-share in the comparison and
drill-down tables, the busiest process per request, and legacy runs degrading
to `-` (charts drop them rather than drawing a `0` that would claim an instant
first token). `bench_lanes.py` and `inspect_gguf.py` gained 15 unit tests
(synthetic GGUFs, an in-process SSE server), taking the suite to 30 unit tests
that need no running stack. A server-side smoke render (`npm run smoke`)
renders every component against the real manifest, because `vite build` only
proves the JSX compiles — it caught a silently-failed edit that made the
comparison table render empty cells.

**Probe calibration fix:** truncation is now reported apart from wrongness
(exit 2 = INCONCLUSIVE, exit 1 = genuinely wrong). A model cut off mid-thought
was not wrong, it was unmeasured, and scoring it as a failure made a healthy
model look degraded. The arithmetic probe also moved 847*293 -> 23*17: a
healthy 4B could not finish the former inside 4000 thinking tokens, so the
check cried wolf on good models.

**Two pre-existing bugs found while doing this**, both fixed:
- the SSE parser matched `"data: "` **with** the space (optional per spec).
  GenieX omits it → nothing parsed, 0 tok/s reported, no TTFT possible. The
  harness was effectively blind to every non-Ollama server.
- servers ignoring `stream_options.include_usage` yielded 0 tokens; now falls
  back to a counted chunk total flagged `tokens_estimated`.

**Closed since the original harvest:** context-length quality scaling
(`bench_coding.py --context-tokens`, § 1e of the GenieX page) and tool/function
calling correctness (`bench_tools.py`, § 1f) — the latter found the one result
that does not crown the coding winner.

**Still open for a general LLM toolkit** (listed so it is not forgotten):



## LLM-BENCH: LB10–LB12, closed 2026-09-02

Re-checked rather than trusted, after F4 and F5 had both turned out stale the
same day. Two of the three were already done and the entries had simply not been
updated.

- ✅ **LB10 — embedding benchmarks.** Already implemented: `bench_embeddings.py`
  (194 lines) measures shape, speed **and meaning** — whether related texts land
  closer together than unrelated ones, the check a shape test cannot make. Its
  docstring quotes this entry's own justification verbatim, so the entry was
  written and then satisfied without being closed. 13 tests green.

- ✅ **LB12 — energy per token.** Resolved honestly rather than implemented:
  `bench_provenance.energy_proxy()` reports CPU-seconds under that name and
  refuses to report joules, because the host exposes no power rail (no RAPL on
  aarch64, no battery counter through WSL2, Snapdragon sensors not surfaced).
  *"Reporting joules would be inventing them."* Recorded as a PROXY so nobody
  later mistakes it for a measurement. That is the correct closure for this item;
  a real number needs hardware that exposes one.

- ✅ **LB11 — run-to-run regression comparison.** `bench_compare.py` (315 lines)
  existed, had its own test file, normalises BOTH report envelopes and exits 1 on
  a regression — and **nothing ever called it.** `run_benchmarks.sh` did not
  mention it; the "baseline" strings in that script are context-length labels.
  The tool was a tripwire nobody armed, the exact "gate that never runs" shape
  this repo keeps rediscovering.

  Closed by adding what was missing. `pair_directories()` + a `--dir` mode
  compare two run directories report-by-report, matching on file name, since the
  sweep writes one report per config and `_manifest.json` is the viewer's index
  rather than a report. A config that appeared or vanished between runs is
  printed as a change, not silently skipped — otherwise a shrinking sweep would
  pass. `run_benchmarks.sh` now calls it when `BENCH_COMPARE_TO` names a previous
  output directory: advisory by default, failing the run under
  `BENCH_COMPARE_STRICT=1`, because a sweep is not a gate unless the operator
  says so.

  Six tests added, and **all three mutations bite**: returning 0 unconditionally
  fails the regression test, dropping the vanished-config line fails the
  swallowing test, and treating `_manifest.json` as a report fails the pairing
  test. Verified end to end outside pytest as well — a 10/10 → 2/10 run prints
  `*** REGRESSION ***` with its Wilson intervals and `BENCH_COMPARE_STRICT=1`
  exits 1.

Full text of the three entries as they stood:

- **LB10 — embedding benchmarks** [M·★★] `tests/test_v1_api.py` exercises the
  embedding endpoints but nothing measures them. Relevant the moment a RAG or
  code-search path is added.
- **LB11 — run-to-run regression comparison** [S·★★] Every tool writes a JSON
  report and nothing diffs two of them. Without it a model swap or a runtime
  bump can silently cost accuracy or speed. Probably the highest-value item
  left: it turns a pile of one-off measurements into a tripwire.
- **LB12 — energy per token** [M·★] The interesting axis on a battery device,
  and the NPU's real argument over the CPU lane (165 % vs 752 % of 800 % CPU
  says something about power but does not measure it).
