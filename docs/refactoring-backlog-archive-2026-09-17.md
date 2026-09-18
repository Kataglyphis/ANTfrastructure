<!-- Closed Linux refactor items, archived 2026-09-17. OPEN work lives in refactoring-backlog.md. -->

# Refactoring backlog archive — 2026-09-17

Closed on 2026-09-17 and moved out of
[`refactoring-backlog.md`](refactoring-backlog.md), which is OPEN-only. Each
entry keeps the evidence that closed it.

**Nothing here was proven by a build.** The Linux chain was not rebuilt for this
wave, so every verdict below is a static gate, a bash suite or a Pester
assertion on an idle tree. The 2026-09-05 experience is the standing warning: a
full green battery still preceded two build-killing bugs in minutes. Read
[`build-watch-list.md`](build-watch-list.md) while the next chain runs.

**What this archive holds:** the three AS1 neighbours, the five consumer issues
(CON1, CON2, CON3, CON5, CON6; CON4 stays open and blocked), the two F1 seams,
the F2 register's one new row, the whole F4 27-row extraction window, and the
Windows path-spelling fix in the six extent/registry gates.

---

## AS1. CLOSED — the host stanza, the amd64/i386 target, and the security default [S, ★]

The three latent neighbours the pocket fix left behind, all closed. Every one
was latent while every cross stage builds on `linux/amd64`.

1. **The compiler-stage host stanza now follows the BUILD arch.** The literal
   `amd64` is gone from `build_python.sh`'s `_python_cross_enable_multiarch_apt`
   (it takes `build_arch_oci` and `ubuntu_arch_uses_ports`; `Dockerfile.media`
   was already fixed 2026-09-10). A non-amd64 build host no longer writes a
   stanza that skips its own packages — and deb822 `Architectures:` replaces
   rather than intersects.
2. **An amd64/i386 cross TARGET gets an archive, not just an architecture.**
   `cross-apt.sh` gained `cross_apt_sources_file_for_arch` and
   `cross_apt_mirror_url_for_arch`; `cross_configure_foreign_arch_apt_sources`
   lost its early return for non-ports targets, so it writes
   `ubuntu-archive-<arch>.sources` for amd64/i386 and `ubuntu-ports-<arch>.sources`
   for everything else. `cross_prune_foreign_arch_apt_sources` prunes both
   prefixes, `cross_ensure_installed_foreign_arch_sources` writes whichever
   family an installed foreign arch needs, and `ubuntu_arch_uses_ports` accepts
   `386` alongside `i386` (`cross_target_arch` answers `386`).
   `test-cross-apt.sh` gained the archive-target cases.
3. **The fast mirror rewrites the security URI by default.**
   `FAST_UBUNTU_REWRITE_SECURITY` in `use-fast-ubuntu-mirror.sh` flipped from
   `false` to `true`; `false` remains the explicit opt-out and the only way to
   keep `security.ubuntu.com`. With the old default, the host `-security` came
   from one archive and the target pocket from another, and
   `cross_align_host_apt_pockets` could not see it because it compares suite
   names, never URIs. The decision is written in the file, in
   [`cross-build-verification.md`](cross-build-verification.md)
   § *Host and target apt sources must expose the same pockets*, and in
   [`linux-build-basics.md`](linux-build-basics.md); the default-ON and
   opt-out arms are pinned by `test-cross-fallback-parity.sh`. The
   `cross-build.arch-table-knows-ports` and `python.host-apt-source-keeps-security`
   mutations were re-pointed at the new shapes.

---

## CON1. CLOSED — the web lane installs a DATED nightly [S, ★★★]

`install_web_lane_toolchain` (`06-packaging/setup-package-image.sh`) installs
`${RUST_NIGHTLY_TOOLCHAIN}` — `versions.env:139`, `nightly-2026-06-28` — where
it used to install the floating `nightly` channel. A dated toolchain is
immutable, so the install is a genuine no-op on a warm image; the floating
channel is *updated* by the same command, and the update renames files out of a
read-only image layer (`Invalid cross-device link`, os error 18). A consumer
that still names the channel gets it auto-installed per run into the writable
`RUSTUP_HOME`.

* `test-setup-package-image.sh` pins the dated argument, the env-override path
  (`RUST_NIGHTLY_TOOLCHAIN=nightly-2099-01-01`) and that the floating channel is
  not installed beside it.
* Mutation `rust.web-lane-nightly-channel` was renamed and re-pointed to
  `rust.web-lane-nightly-pin`.
* [`consumer-image-contract.md`](consumer-image-contract.md) and
  [`build-watch-list.md`](build-watch-list.md) were updated in the same window.

**Consumer note:** FRB v2.13.0 names the pin with
`--wasm-pack-rustup-toolchain nightly-2026-06-28` (otherwise wasm-pack
auto-installs the floating channel per invocation). That is the consumer half,
not work here.

---

## CON2. CLOSED — flatpak refs are probed in BOTH scopes [S, ★★]

`app_packaging_setup_dependencies_for_container` ran `flatpak --user install`
unconditionally, so the CI image's system-wide runtime pair was pulled a second
time per run as a per-user copy — the issue measured ~1.9 GB per arch. The
scope probe now has one owner, `app_packaging_flatpak_ensure_refs`
(`lib/app-packaging.sh`): a remote is added only when neither scope knows it, a
ref is installed only when neither scope has it, `container` mode wraps every
call in `dbus-run-session` and installs per-user, `runtime` mode installs
user-first with a system fallback. `app_packaging_ensure_flatpak_runtime` was
repointed to the same owner, which is the shape the entry asked for.

Four `test-app-packaging-flatpak.sh` cases pin it: a system-installed ref is not
pulled again, a missing ref still installs per-user, a known remote in either
scope skips `remote-add`, and a failing per-user install is fatal.
`dead-functions.allow` dropped its two rows for the now-suite-referenced
functions.

---

## CON3. CLOSED — `GSTREAMER_ROOT_ANDROID` was already exported [S, ★★]

Verified, no edit needed: the image exports
`GSTREAMER_ROOT_ANDROID=/opt/android/gstreamer` in `linux/Dockerfile.android`
(the ENV block at line 70 after CON5's insert; it was line 66) and
`linux/Dockerfile.package:291`. The consumer workaround
(`export_android_gstreamer_env` in OmniAccelerANT) can be deleted outright.

---

## CON5. CLOSED — API 37 ships alongside 36 [S, ★★★]

`ANDROID_EXTRA_COMPILE_SDK=37.0` and `ANDROID_EXTRA_BUILD_TOOLS=37.0.0` were
added to `versions.env`; `Dockerfile.android` declares and ENVs them;
`android-sdk.sh` installs `platforms;android-${ANDROID_EXTRA_COMPILE_SDK}` and
`build-tools;${ANDROID_EXTRA_BUILD_TOOLS}` beside the 36 pair. Google's
repository names API 37's base platform `platforms;android-37.0` — there is no
`platforms;android-37`, and only API 36 kept the un-suffixed name — which the
versions.env comment records. The consumer's `permission_handler_android` 13.0.1
pin and its three-line reason can be dropped once the image ships.

The Android SDK section of [`linux-cross-builds.md`](linux-cross-builds.md)
carries the fact, and `bump_versions.py`'s MANUAL registry lists the two keys so
they are classified rather than reported unclassified (they are deliberate
extras, not feed-tracked pins).

---

## CON6. CLOSED — `finish-args` gained an append-only hook [S, ★★]

`KATAGLYPHIS_FLATPAK_FINISH_ARGS` (space-separated) appends to the generated
four (`--share=network`, `--socket=wayland`, `--socket=fallback-x11`,
`--device=dri`) through the new owner
`app_packaging_flatpak_finish_args_block`, which the manifest heredoc calls. So
a V4L2 app can ask for `--device=all` (flatpak has no `--device=video`) and a
user-chosen model path for a `--filesystem=` without forking the generator.

* Three suite cases pin the four base args, append-not-replace, and one YAML
  line per knob entry; a fourth asserts the heredoc calls the block.
* The knob is registered in `lint-env-knobs.allow` and documented in
  [`shared-script-libraries.md`](shared-script-libraries.md).
* `app_packaging_package_linux_bundle_flatpak` went 91 → 88 lines
  (`function-size.allow` re-trued), which is the extraction CON6 needed.

---

## F1. CLOSED — both named seams cut, and a row fell out with them [M]

**`run_agentic_loop` 95 → 73 lines, cc 21 → under 15.** The planner phase is
`_agentic_planner_phase` (`lib/agentic-loop.sh`), which reports `planner_ran`
back through a nameref — the loop state the row said a split had to thread.
`test-agentic-loop.sh` gained five cases (skip on pending, starvation guard,
blocked-only queue, refactor cycle, and the delegation itself), and **both allow
rows are deleted, not re-baselined**: `function-size.allow` and
`code-complexity.allow`. The seam is listed in
[`agentic-loop-build-matrix.md`](agentic-loop-build-matrix.md).

**The registry-cache drop is `_cross_build_drop_registry_cache_after_flake`**
(`01-core/cross-stage-build.sh`), taking `build_cmd` and `_regcache_fails` by
nameref. The four `test-cross-stage-build-cmd.sh` cases from `d7fbfd39` were the
safety net and ran unchanged; the two mutation entries that neuter the drop were
re-pointed at the helper's guard lines. [`build-cache-tiers.md`](build-cache-tiers.md)
now names the function instead of the old line range.

**One row fell out as a side effect:** the same extraction took
`_cross_stage_build_impl` from 91 lines to under 80, so its `function-size.allow`
KEEP row was deleted. The row's own argument — the retry must not be separated
from the thing retried — is why the extracted helper is a decision the loop
*calls*, not a second retry loop.

---

## F2. ONE ROW ADDED — `app-packaging.sh` crossed 800 [record]

`lib/app-packaging.sh` went 797 → 851 with CON2's scope probe and CON6's
finish-args block, so `file-size.allow` gained its first new row in a while —
with the NOT-a-split reason and the note that CON6's seam was extracted rather
than inlined. The register's verdict is unchanged: no row in that file is a
split target. The allow file remains the authority for the numbers.

---

## F4. CLOSED — all 27 PowerShell extractions applied in one window [S-M each]

The 2026-09-09 review identified 27 extractable PowerShell pairs and never
applied them; this window applied the outstanding work, and every one of the 27
is applied as of this archive. No new dependency edges, no behaviour changes —
the test suites that existed ran unchanged.

### The owners, grouped by what they replaced

* **AST mechanics.** `Get-CommandParameterArgumentMap` + `Get-AstDefaultValue`
  (`SourceBuild.PinParity.Tests.ps1`): the two scanners keep only their
  differing arms; row 233 → 154.
* **Fixtures and harnesses.** `$script:WriteArMemberHeader`
  (`SourceBuild.VerifyTargetArch.Tests.ps1`, 85 → 74); the hoisted
  `$newFakeSccache` (`SourceBuild.SccacheSession.Tests.ps1`, 28 → 26); the
  file-scope `$newStageTree` (`SourceBuild.Chain.Tests.ps1`); the existing
  `Assert-ManualTestOutcome` (`Testing.ManualExecutable.Tests.ps1`).
* **Enumeration policy.** `Get-ProjectSourceFiles`
  (`WindowsFormatting.Common.psm1`, 118 → 43), seeded by the `-match`/`-notmatch`
  drift that once formatted zero files; the three inline uv delegates in
  `WindowsFormatting`/`WindowsWebDav` repointed to the existing
  `New-UvBuildDelegates` (pair row retired, 42).
* **Cache wiring.** `Enable-SccacheCompilerWrapper`
  (`WindowsBuild.Common.psm1`, row 30 → 20) now owns the five assignments and
  the CUDA-launcher comment once.
* **Probes and host scripts.** `WindowsSiloProbe.Common.psm1` ends as the
  five-function owner the plan named (`Get-CdbPath`, `Initialize-LsmProbeOutDir`,
  `Start-SiloBaitContainer -PassThru`, `Wait-ForNewSilo`, `Get-SiloSvchost`),
  with `Get-WininitProcessId` and `Get-SiloServicesProcess` folded away — the
  nine LSM rows keep their budgets because their residual overlap survives;
  `Show-Exclusions` (`Sync-DefenderExclusions.ps1`, row retired);
  `Start-HostServices` (`WindowsHostMaintenance.Common.psm1`, one new row) and
  its three host-script callers.
* **Downloads and tool paths.** `Assert-FileSha256`
  (`WindowsScripts.Shared.psm1`) now owns the verify-or-warn policy at four call
  sites (Install-Tensorrt, Resolve-QnnSdk, Invoke-DownloadWithRetry, and the
  compiler-rt staging); `Install-AArch64CompilerRt`
  (`WindowsSourceBuild.Common.psm1`, re-exported) owns the compiler-rt mining
  recipe; `Resolve-BuildCtlPath` owns the Stevedore candidate list, retiring
  three buildctl rows; `Assert-NoCacheStageMatched` (`Build-Buildkit.ps1` self)
  owns the matched-nothing gate at both call sites, retiring the self-row.
* **Already migrated before the wave:** the two docker.exe walkers in
  `Test-LayerRename.ps1` and `Test-ProcessIsolationCommit.ps1` already called
  `Get-PreferredToolPath` at the wave's base; the wave finished the same
  migration for `Test-BuildCopy.ps1` and `Test-GpuPassthrough.ps1`.
  `Test-BuildCopy.ps1`'s self row was retired.

### The bookkeeping, measured

Across `docs/scripts/code-dupes.allow`: **39 stale rows removed, 23 budgets
re-trued, 2 rows added**, and the allowlist stands at **591 pairs**. The
re-trued set includes several shrank-only rows whose reasons now say what the
residual overlap is, and the twelve rows the F4 extractions shrank without
retiring were re-worded to "Applied 2026-09-17" in the same pass. The deleted set
includes the rows of the eight probes #159 removed (the gate's corpus effect),
not only F4's own.

**Residue, stated plainly.** Twelve of the 27 keep an allow row because the
extraction shrank the overlap without taking it under the threshold: the nine
LSM rows, `SourceBuild.Chain.Tests.ps1`, `Testing.ManualExecutable.Tests.ps1`
and the already-migrated `Test-LayerRename` ↔ `Test-ProcessIsolationCommit`
pair. One further suppression flip (`WindowsBuild.Common.psm1` ↔
`WindowsWebDav.Common.psm1`, 13 → 12) was re-trued at the wave tip. The gate is
green: no unallowlisted pair, no stale row.

---

## Fixed 2026-09-17 — the extent gates' Windows path spelling

`verify_code_size.py`, `verify_code_complexity.py`, `verify_comment_size.py`,
`verify_dead_functions.py`, `verify_trailing_conditional.py` and
`verify_gate_registry.py` **mis-resolved every allow/owner key when run with
Windows Python**: `os.path.relpath` spells backslashes there while the allow rows
and `mutations.json` targets are posix-spelled, so frozen rows reported twice
(once as "over the limit and not frozen", once as "STALE freeze") and 66
mutation ids read as off-convention. The fix is one normalization at each walker
(`.replace(os.sep, "/")`) plus posix joins in the registry's
`imported_modules`/`shelled_out`; all six are green under Windows Python and
unchanged under WSL. A mutation cannot pin this on a Linux runner (removing the
replace is a no-op there), so the proof is the two-host run, not a suite case.
`docs/refactoring-backlog.md` no longer carries the "run these under WSL" advice
because it is no longer needed.
