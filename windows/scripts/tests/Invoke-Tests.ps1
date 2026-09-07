#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Runs every *.Tests.ps1 in this directory against the shared modules and exits non-zero
# on any failure. Harness-style suites need nothing installed (see TestHarness.psm1);
# Pester-style suites require Pester >= 5, and the run FAILS (never silently skips) when
# it is missing, so CI can't go green on "0 tests".
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modDir = Join-Path (Split-Path $here -Parent) 'modules'

Import-Module (Join-Path $here 'TestHarness.psm1') -Force -DisableNameChecking
# Ordering no longer matters: nested Shared imports inside the modules are now
# guarded and un-Forced (repo-wide rule, 2026-08-04), so they can't unload a
# top-level import. Shared stays explicitly imported for the suites that use
# its exports directly; -Force everywhere gives dev sessions fresh code.
Import-Module (Join-Path $modDir 'WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsBuildKit.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsBuildDriver.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsGstPlugins.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsTesting.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsClang.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsScripts.Shared.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsTargetArch.Common.psm1') -Force -DisableNameChecking
# Merge-lane and TVM leaf modules (#134). They are NOT in the buildmods closure
# -- that is the point of them -- but the suite loads every module it tests, and
# six fixture suites used to reach these functions through the stage scripts'
# ASTs instead.
Import-Module (Join-Path $modDir 'WindowsMeson.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsRustToolchain.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsTvm.Common.psm1') -Force -DisableNameChecking

Reset-TestState

# This directory holds two kinds of suite: zero-dependency ones written
# against TestHarness.psm1 (dot-sourced below) and Pester-style ones using
# BeforeAll/Context. Dot-sourcing the latter throws "The BeforeAll command
# may only be used inside a Describe block" and aborts the whole run, so
# they are detected and handed to Pester instead. Detection keys on
# Pester-only block keywords (BeforeAll/BeforeEach/AfterAll/AfterEach/
# Context) — NOT on Describe, which TestHarness.psm1 also exports, so a
# Describe-based discriminator would misroute every harness suite to Pester.
$pesterFailures = 0
$pesterPassed = 0
$pesterTotal = 0
$skippedSuites = @()
$pesterMinVersion = [version]'5.0'
$pesterAvailable = $null -ne (Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge $pesterMinVersion } | Select-Object -First 1)
$testFiles = Get-ChildItem -Path $here -Filter '*.Tests.ps1' | Sort-Object Name
$harnessFiles = @()
$pesterFiles = @()
foreach ($f in $testFiles) {
    $isPesterStyle = (Get-Content $f.FullName -Raw) -match '(?m)^\s*(BeforeAll|BeforeEach|AfterAll|AfterEach|Context)\s'
    if ($isPesterStyle) { $pesterFiles += $f } else { $harnessFiles += $f }
}

# Pass 1: harness suites, dot-sourced. This MUST happen before Pester is ever
# imported into this session: Pester also exports Describe/It, and once imported
# it would shadow the harness functions, silently rerouting dot-sourced suites
# through Pester's standalone-Describe path (whose failures do not reach $results
# and therefore never fail the run).
foreach ($f in $harnessFiles) {
    Write-Host ''
    Write-Host "== $($f.Name) ==" -ForegroundColor Yellow
    . $f.FullName
}

# Pass 2: Pester suites.
foreach ($f in $pesterFiles) {
    Write-Host ''
    Write-Host "== $($f.Name) ==" -ForegroundColor Yellow

    if (-not $pesterAvailable) {
        Write-Host "   SKIPPED (Pester-style suite; Pester >= $pesterMinVersion is not installed)" -ForegroundColor Yellow
        $skippedSuites += $f.Name
        continue
    }

    Import-Module Pester -MinimumVersion $pesterMinVersion -ErrorAction Stop
    # Pester 5+ configuration object (-Quiet is Pester 3/4 legacy; Output.Verbosity
    # 'None' is its replacement and works on both Pester 5.x and 6.x).
    $pesterConf = New-PesterConfiguration
    $pesterConf.Run.Path = $f.FullName
    $pesterConf.Run.PassThru = $true
    $pesterConf.Output.Verbosity = 'None'
    $pesterRun = Invoke-Pester -Configuration $pesterConf
    Write-Host ("   Pester: {0}/{1} passed" -f $pesterRun.PassedCount, $pesterRun.TotalCount) `
        -ForegroundColor $(if ($pesterRun.FailedCount -gt 0) { 'Red' } else { 'Green' })
    foreach ($ft in @($pesterRun.Failed)) {
        Write-Host "   FAIL $($ft.ExpandedPath)" -ForegroundColor Red
        # The assertion text is the diagnosis; without it a red suite costs a
        # second run under Invoke-Pester -Output Detailed (2026-08-25).
        foreach ($er in @($ft.ErrorRecord)) { if ($er) { Write-Host "        $(($er.Exception.Message -split "`r?`n")[0])" -ForegroundColor DarkRed } }
    }
    $pesterFailures += $pesterRun.FailedCount
    $pesterPassed += $pesterRun.PassedCount
    $pesterTotal += $pesterRun.TotalCount
}

$results = @(Get-TestResult)
$failed = @($results | Where-Object { -not $_.Ok })
$passed = $results.Count - $failed.Count + $pesterPassed
$total = $results.Count + $pesterTotal
$failCount = $failed.Count + $pesterFailures

Write-Host ''
Write-Host ('=' * 60)
$color = if ($failCount -gt 0) { 'Red' } else { 'Green' }
Write-Host " $total tests | $passed passed | $failCount failed" -ForegroundColor $color
Write-Host ('=' * 60)
foreach ($x in $failed) {
    Write-Host "  FAIL [$($x.Group)] $($x.Name)" -ForegroundColor Red
    Write-Host "       $($x.Err)" -ForegroundColor Red
}

if ($pesterFailures -gt 0) {
    Write-Host "  $pesterFailures Pester test(s) failed (see the per-file lines above)" -ForegroundColor Red
}

# A skipped suite is a FAILED gate: silently dropping suites previously produced a
# green "0 tests" run on hosts without Pester, which is exactly what this pre-build
# gate exists to prevent.
if ($skippedSuites.Count -gt 0) {
    Write-Host "  $($skippedSuites.Count) suite(s) SKIPPED (Pester >= $pesterMinVersion required):" -ForegroundColor Red
    foreach ($s in $skippedSuites) { Write-Host "    $s" -ForegroundColor Red }
    Write-Host '  Install it with: Install-Module Pester -MinimumVersion 5.7 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Red
}

# MINIMUM COUNT (2026-08-26 audit): the checks above fire on failures and on
# skipped suites, but a run that DISCOVERED nothing -- a glob that matched no
# file, a wrong working directory, a suite dir that moved -- printed
# "0 tests | 0 passed | 0 failed" and exited 0. That is the same
# "verified nothing, reported PASS" shape MIN_PASSED guards in the smoke gate
# and -MinInspected in the arch gate. The floor is measured with headroom for a
# suite that is legitimately retired; raise it when the suite count grows, and
# never lower it to make a red run green.
#
# 690 -> 700 (2026-08-26 evening): the suite went 702 -> 708 the same day
# (+4 BuildKit.ModuleClosure, +1 Modules.ScriptCallClosure, +3 the AArch64
# fixup-range selector fixtures, -1 the retired B6 parity check) while the floor
# stayed where 702 had put it. That is the drift this comment's own instruction
# exists to prevent: at 690 against 708 the gate tolerated losing 18 tests.
# ~1% headroom is the standing ratio.
# 700 -> 714 (2026-08-28): caught a -Force harness import that silently dropped
# 104 assertions. 714 -> 718 with BuildKit.PatchedLlvm; suite is 725.
# 718 -> 757 (2026-08-28): the three merge-stage script suites
# (VerifyTargetArch 20 + StageTargetPythonDeps 10 + BundleManifest 9) took the
# suite to 765; floor at ~1% headroom.
# 757 -> 763 (2026-08-28): BuildDriver.ResourceSampler (6 tests) took the suite
# to 771.
# 763 -> 762 (2026-08-31): the classic lane's deletion removed 8 tests (-6
# Invoke-DockerWithRetry/Get-DockerBuildArgList, -1 ClosureScope, PreflightParity
# 4 -> PreflightContract 3) and +1 came from the whole-dir-mount gate. Suite is
# 770, so the floor DROPS for the first time -- measured, not to hide a red run.
# 762 -> 791 (2026-09-06): Wait-ContainerExit's detach-tolerant wait added 20
# tests (WindowsContainerBuild.Reuse + Orchestrators), taking the suite to 799.
# Same run took the suite from 6 red to 0: five of those failures were stale
# names left by the approved-verb rename (build-*-all.ps1 globs, the
# toggle-rdna4-gpu and build-resource-sampler patterns, build-media-tvm-all) and
# one was a real APP_REF pin drift. Floor back to the standing ~1% headroom.
# 791 -> 797 (2026-09-06): the bind-mount false-green/evidence fixes added 6
# tests (name-held fallback, live-leftover refusal, keep-on-failure,
# stderr-notice and unknown/empty-state waits); the suite measured 806.
$minTests = 797
if ($total -lt $minTests) {
    Write-Host "  FLOOR: only $total test(s) ran, expected at least $minTests -- suites were not discovered (glob, working directory, or a moved suite dir), not 'nothing to do'." -ForegroundColor Red
    exit 1
}

if ($failed.Count -gt 0 -or $pesterFailures -gt 0 -or $skippedSuites.Count -gt 0) { exit 1 }
exit 0
