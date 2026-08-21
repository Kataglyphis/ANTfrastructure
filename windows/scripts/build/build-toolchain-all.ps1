#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# CACHE-BUST 2026-08-05 (2nd use of the documented sidestep, AGENTS.md
# failure table): the toolchain RUN's snapshot commit died persistently on
# identical chain-IDs (ActivateLayer 0x20) — debris from a finalize attempt
# that raced the 0x3-canary's export. New file content -> new chain-IDs.


# Toolchain run+commit entrypoint (windows/build.ps1 Invoke-RunCommitStage). The
# thin builder (Dockerfile.toolchain-builder) already cloned CPython and wrote
# Directory.Build.props; this runs the CPU-bound `PCbuild\build.bat` at the
# container's full --cpu-count, then trims build artifacts and verifies. Moving the
# compile out of `docker build` (2-CPU-capped on this host) into `docker run
# --cpu-count N` is what lets CPython build on all cores. See docs/windows-builds.md
# § Build isolation and CPU parallelism.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$src = 'C:\temp\cpython'

Write-Host "==> Building CPython from source at $src (NUMBER_OF_PROCESSORS=$env:NUMBER_OF_PROCESSORS)"
if (-not (Test-Path $src)) { throw "CPython source tree missing at $src (builder image did not clone it)" }

# CPython's PCbuild\find_python.bat bootstraps a build Python via nuget, fetching nuget.exe
# from https://aka.ms/nugetclidl -- a Microsoft redirect that intermittently serves a ~190 KB
# HTML error page instead of the ~8 MB binary, after which build.bat aborts with "The system
# cannot execute the specified program". Pre-seed a valid nuget.exe at externals\nuget.exe from
# the stable dist.nuget.org URL (via the resilient shared downloader): find_python's
# `if NOT exist "%_Py_NUGET%"` guard then skips the flaky aka.ms fetch entirely.
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force

# Re-read versions.env if a fresh copy is reachable: the NUGET_VERSION /
# NUGET_EXE_SHA256 env vars below come from the BASE-BAKED Machine env, so a
# versions.env nuget bump would silently lag until a base rebuild — a fresh
# file beats the baked env. Preference order (#52): a SIBLING versions.env
# first (the BK lane bind-mounts script + file side by side under C:\bkmnt,
# so edits never bust the CPython layer), then the classic lane's COPY at
# $env:TEMP_DIR. Degrades gracefully: neither present -> baked env.
$versionsEnvFile = ''
foreach ($cand in @((Join-Path $scriptAssetRoot 'versions.env'),
        $(if ($env:TEMP_DIR) { Join-Path $env:TEMP_DIR 'versions.env' }))) {
    if ($cand -and (Test-Path $cand)) { $versionsEnvFile = $cand; break }
}
if ($versionsEnvFile) {
    # Precedence (aligned with load-versions.ps1, 2026-08-21): the fresh file
    # beats base-BAKED values, but a value someone forwarded deliberately
    # (process differs from the Machine-baked one) beats the file — the old
    # unconditional overwrite silently reverted --build-arg experiments.
    Write-Host "Overriding process env from fresh $versionsEnvFile (baked values only; forwarded overrides win)"
    foreach ($entry in (ConvertFrom-VersionsEnv -Path $versionsEnvFile).GetEnumerator()) {
        $procVal = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        $machVal = [Environment]::GetEnvironmentVariable($entry.Key, 'Machine')
        if ($procVal -and $procVal -ne $machVal -and $procVal -ne $entry.Value) {
            Write-Host "  keeping forwarded $($entry.Key)=$procVal (file has $($entry.Value))"
        } else {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
}

$nugetExe = Join-Path $src 'externals\nuget.exe'
# Versioned URL + SHA256 pin (NUGET_VERSION / NUGET_EXE_SHA256 in versions.env, baked
# env) instead of the floating /latest/ URL, so the seeded binary is reproducible.
$nugetVer = if ($env:NUGET_VERSION) { $env:NUGET_VERSION } else { '7.6.0' }
$nugetUrl = "https://dist.nuget.org/win-x86-commandline/v$nugetVer/nuget.exe"
if (-not (Test-Path $nugetExe)) {
    # -ExpectSignature MZ rejects AND retries an HTML error page served in place of the binary
    # (the exact aka.ms-style flake this pre-seed exists to dodge) instead of choking build.bat.
    Invoke-DownloadWithRetry -Url $nugetUrl `
        -DestinationPath $nugetExe -Description "nuget.exe $nugetVer (CPython build bootstrap)" `
        -ExpectSignature MZ -ExpectedSha256 ([string]$env:NUGET_EXE_SHA256)
    Write-Host "Pre-seeded valid nuget.exe ($([int]((Get-Item $nugetExe).Length / 1KB)) KB) at $nugetExe"
}
# Belt-and-suspenders: point find_python.bat's own fallback download at the stable direct URL
# instead of the flaky aka.ms redirect (used only if the seed above is ever absent).
$env:NUGET_URL = $nugetUrl

# PCbuild\build.bat drives MSBuild, which parallelizes across available CPUs — under
# the run+commit container that is --cpu-count, not the 2-CPU docker build cap.
& cmd /c "cd /d $src && PCbuild\build.bat -e -p x64 -c Release"
if ($LASTEXITCODE -ne 0) { throw "CPython build.bat failed (exit $LASTEXITCODE)" }

# Trim dead weight in place (matches the old Dockerfile.toolchain cleanup layer):
# compile intermediates, external dep trees, and the shallow git history — the
# external DLLs are already copied into PCbuild\amd64.
foreach ($d in @("$src\PCbuild\obj", "$src\externals", "$src\.git")) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# Verify the built interpreter.
$pyExe = "$src\PCbuild\amd64\python.exe"
if (-not (Test-Path $pyExe)) { $pyExe = "$src\PCbuild\amd64\python_d.exe" }
if (-not (Test-Path $pyExe)) { throw 'Python build failed - interpreter not found' }
# Gate on the exit code: a clang-built python.exe that dies at startup used to
# still commit as the toolchain image (Test-Path alone can't catch that).
$pyVersionLine = & $pyExe --version 2>&1 | Select-Object -First 1
if ($LASTEXITCODE -ne 0) { throw "source-built python failed to run (exit $LASTEXITCODE)" }
Write-Host "Python version: $pyVersionLine"
Write-Host "Python built at: $pyExe"

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0
