# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Toolchain run+commit entrypoint (windows/build.ps1 Invoke-RunCommitStage). The
# thin builder (Dockerfile.toolchain-builder) already cloned CPython and wrote
#requires -Version 7.0

# Directory.Build.props; this runs the CPU-bound `PCbuild\build.bat` at the
# container's full --cpu-count, then trims build artifacts and verifies. Moving the
# compile out of `docker build` (2-CPU-capped on this host) into `docker run
# --cpu-count N` is what lets CPython build on all cores. See docs/windows-builds.md
# § Build isolation and CPU parallelism.

$ErrorActionPreference = 'Stop'
$src = 'C:\temp\cpython'

Write-Host "==> Building CPython from source at $src (NUMBER_OF_PROCESSORS=$env:NUMBER_OF_PROCESSORS)"
if (-not (Test-Path $src)) { throw "CPython source tree missing at $src (builder image did not clone it)" }

# CPython's PCbuild\find_python.bat bootstraps a build Python via nuget, fetching nuget.exe
# from https://aka.ms/nugetclidl -- a Microsoft redirect that intermittently serves a ~190 KB
# HTML error page instead of the ~8 MB binary, after which build.bat aborts with "The system
# cannot execute the specified program". Pre-seed a valid nuget.exe at externals\nuget.exe from
# the stable dist.nuget.org URL (via the resilient shared downloader): find_python's
# `if NOT exist "%_Py_NUGET%"` guard then skips the flaky aka.ms fetch entirely.
Import-Module (Join-Path $PSScriptRoot 'modules\WindowsScripts.Shared.psm1') -Force
$nugetExe = Join-Path $src 'externals\nuget.exe'
if (-not (Test-Path $nugetExe)) {
    # -ExpectSignature MZ rejects AND retries an HTML error page served in place of the binary
    # (the exact aka.ms-style flake this pre-seed exists to dodge) instead of choking build.bat.
    Invoke-DownloadWithRetry -Url 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' `
        -DestinationPath $nugetExe -Description 'nuget.exe (CPython build bootstrap)' -ExpectSignature MZ
    Write-Host "Pre-seeded valid nuget.exe ($([int]((Get-Item $nugetExe).Length / 1KB)) KB) at $nugetExe"
}
# Belt-and-suspenders: point find_python.bat's own fallback download at the stable direct URL
# instead of the flaky aka.ms redirect (used only if the seed above is ever absent).
$env:NUGET_URL = 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe'

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
& $pyExe --version
Write-Host "Python built at: $pyExe"

