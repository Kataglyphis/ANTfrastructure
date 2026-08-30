# Refactoring backlog — CLOSED 2026-08-30

> Split out of [`refactoring-backlog.md`](refactoring-backlog.md) so that file
> shows only OPEN work. Nothing here needs action; it is kept because the
> entries record WHY a thing is the way it is, and because one was closed by
> being REFUTED rather than fixed — the kind of finding that gets re-discovered
> if the reasoning disappears. Earlier rounds: `refactoring-backlog-archive-2026-08-10.md`,
> `refactoring-backlog-archive-2026-08-27.md`.

## Closed on 2026-08-30

- ✅ **sccache caches NOTHING in the OpenCV step — CLOSED by REFUTATION.**
  The entry (OPEN 2026-08-26) attributed 2359 sccache-launcher bypass
  messages to an OpenCV-specific failure ("sccache fails on EVERY compile
  with the main build dir /tmp/opencv-1/build as cwd"). That attribution is
  wrong. The 2359 faults were the **wrong-server bug**: pre-UDS, media
  stages ran CONCURRENT BuildKit containers that reached each other's sccache
  server over the fixed TCP port (4226), the wrong server accepted the job
  ("Server sent CompileStarted") and then could not find the caller's files —
  `caused by: No such file or directory (os error 2)`. Fixed 2026-08-27:
  b4078ad1 (container-local server identity) + 4aa92fb6 (`SCCACHE_SERVER_UDS`
  — the address is a filesystem path in /tmp, private by construction), the
  same night the guarded launcher (fece3558) started carrying the build past
  the failures. DOCUMENTED at the time in `docs/build-cache-tiers.md` § 5.1:
  "SCCACHE_SERVER_UDS took the media stage from 2359 sccache faults to zero."
  Evidence trail that closes it (log forensics, 2026-08-30):
  - staged-media7.log (2026-08-26 22:02, PRE-UDS): 2359 bypass messages in
    BOTH the opencv 2/3 and onnxruntime 2/9 steps — not OpenCV-exclusive,
    as the entry claimed.
  - Every post-UDS run: 0 bypass messages — staged-media9.log, staged-media10.log,
    and media-arm64.log (2026-08-30, the QNN-LINUX build, where OpenCV
    compiled all 1660 objects with the launcher in place and the ffmpeg
    sibling step recorded 3104 compile requests at 99.64 % cache-hit rate).
  No code change was needed beyond the already-landed fixes; the item is
  closed as REFUTED, with the wrong-server writeup kept on record so the
  misdiagnosis is not re-discovered.
- ✅ **F2 — Compiler-cache abstraction consolidation — DONE.** All launcher
  resolution now routes through ONE resolver. `01-core/compiler-cache.sh`
  gained `_resolve_compiler_cache_launcher()`, which uses common.sh's
  `compiler_cache_launcher()` (01-core) when it is loaded — the case for
  every media/ORT caller — and otherwise falls back to an inline bootstrap
  (the android preamble sources compiler-cache.sh standalone). Both paths
  implement the identical decision: guarded launcher when reachable, bare
  sccache when not, ccache when the server is dead, never empty. setup_ccache
  and setup_sccache both consume it; the verify-critical-fixes.sh gate
  (guarded-launcher-plus-sccache decision) still passes without edits.
  Pinned by the new suite `linux/scripts/tests/test-compiler-cache.sh`
  (8 assertions, mutation-covered): framework-path verdict pass-through,
  bootstrap guarded-launcher preference, dead-server and absent-sccache
  fallbacks, and setup_sccache keeping RUSTC_WRAPPER sccache-class even on a
  ccache verdict (Rust has no ccache fallback). Behavior-identical by
  construction — no zip/closure rebuild needed to validate; the first media
  run after landing double-checks the stats lines.
- ✅ **C — --no-push OCI-layout stage handoff — DONE 2026-08-30.** The last
  open half of the orchestrator-lifecycle item. Hook points:
  - `cross-stage-build.sh` — `cross_local_handoff_enabled()`,
    `cross_ensure_local_context_workdir()` (mints `${CROSS_CONTEXT_ROOT}/
    cross-flow.XXXXXX` once per run, age-based orphan sweep mirroring the
    runtime lane's), `cross_stage_context_dir()`; the push=0 parent path in
    `_cross_stage_run_resolve_parent` appends
    `--build-context <parent-tag>=oci-layout://<dir>` when the parent's
    `index.json` exists (i.e. the parent was BUILT THIS RUN); `cross_stage_run`
    exports every local stage to its layout after the build, and android
    additionally to `<workdir>/android-artifacts/<arch>` for the runtime lane.
  - `build-cross-chain.sh` — `_chain_no_push_guard` now ALLOWS full chains
    (from base) and refuses only mid-chain resumes; parse-time `--no-push`
    message updated; `run_runtime_stage` passes `ARTIFACT_CONTEXT_ROOT` +
    `ARTIFACT_CONTEXT_MODE=oci` to the runtime helper under `--no-push` (its
    existing `runtime_use_local_artifact_context` path consumes the android
    layout); `_chain_on_exit` reclaims the workdir.
  - Proven on the live host with a two-stage test build: stage A built + saved
    to a layout, stage B's `FROM localtest:stage-a` with
    `--build-context localtest:stage-a=oci-layout://…` resolved from the LOCAL
    layout (`--pull=false`, marker file verified inside B). Unit-pinned by
    `tests/test-cross-oci-handoff.sh` (15 assertions, incl. mutation-style
    guard cases: handoff-off refuses, mid-chain refuses, FORCE escapes).
  - Why the guard still refuses mid-chain: `--from-stage` after base resuming
    a no-push chain has no locally-built parent to serve; the registry would
    be the stale-parent bug again. Documented in the usage text + guard.
  - Residual (documented, not done): a REAL multi-arch no-push chain has not
    been run end-to-end (validation remains on-demand; mechanism + guard are
    unit- and live-proven at the buildkit level).
