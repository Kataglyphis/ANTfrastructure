# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Toolchain run+commit entrypoint (windows/build.ps1 Invoke-RunCommitStage). The
# thin builder (Dockerfile.toolchain-builder) already cloned CPython and wrote
# Directory.Build.props; this runs the CPU-bound `PCbuild\build.bat` at the
# container's full --cpu-count, then trims build artifacts and verifies. Moving the
# compile out of `docker build` (2-CPU-capped on this host) into `docker run
# --cpu-count N` is what lets CPython build on all cores. See docs/windows-builds.md
# § Build isolation and CPU parallelism.

$ErrorActionPreference = 'Stop'
$src = 'C:\temp\cpython'

Write-Host "==> Building CPython from source at $src (NUMBER_OF_PROCESSORS=$env:NUMBER_OF_PROCESSORS)"
if (-not (Test-Path $src)) { throw "CPython source tree missing at $src (builder image did not clone it)" }

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
