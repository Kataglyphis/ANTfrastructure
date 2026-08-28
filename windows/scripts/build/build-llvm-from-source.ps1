#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Builds clang/LLVM at the pinned LLVM_WINDOWS_VERSION carrying the two
    AArch64 instruction-size fixes (llvm#219275, llvm#219276), installed where
    it shadows the scoop clang-cl.

.DESCRIPTION
    Unpatched, clang-cl aborts on OpenCV/protobuf aarch64 sources, which is what
    the lane's `+force-32bit-jump-tables` and `/Ob1` workarounds pay for. Root
    cause and evidence: backlog #135, docs/windows-refactor-backlog.md.

    Built from the pinned release, not main: the banner must still report
    LLVM_WINDOWS_VERSION for verify-toolchain.ps1's provenance gate, and the
    source patches under windows/scripts/patches/ were written against it.

.PARAMETER InstallPrefix
    Where the built toolchain lands. Must come BEFORE the scoop shims on PATH:
    every build script resolves the compiler by bare name, so shadowing is all
    that is required.

.PARAMETER SkipIfPresent
    Do nothing when a patched clang is already installed at the prefix.
#>
[CmdletBinding()]
param(
    [string]$LlvmVersion = '',
    [string]$InstallPrefix = 'C:\llvm-patched',
    [string]$SourceRoot = 'C:\temp\llvm-src',
    [switch]$SkipIfPresent
)

$ErrorActionPreference = 'Stop'

# #108: container mounts are FLAT (C:\temp\scripts), the repo nests one level deeper.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$LlvmVersion = Get-SourceBuildVersion -EnvironmentVariables @('LLVM_WINDOWS_VERSION') -DefaultValue '23.1.0'
Write-Host "=== clang/LLVM $LlvmVersion source build (AArch64 instruction-size fixes) ==="

$clangCl = Join-Path $InstallPrefix 'bin\clang-cl.exe'
if ($SkipIfPresent -and (Test-Path $clangCl)) {
    Write-Host "Patched clang already present at $clangCl - nothing to do."
    return
}

# An unknown version must THROW rather than download unpinned (backlog #47).
# Keep in step with build-tvm-from-source.ps1 -- both consume the same tarball.
$llvmSrcSha = @{
    '22.1.8' = '922f1817a0df7b1489272d18134ee0087a8b068828f87ac63b9861b1a9965888'
    '23.1.0' = 'ab1f0e3ec52448c33e8782eaf0422504b87c7b016b22514653ee0d8fcee479ff'
}
if ($env:LLVM_WINDOWS_SRC_SHA256) { $llvmSrcSha[$LlvmVersion] = $env:LLVM_WINDOWS_SRC_SHA256 }
if (-not $llvmSrcSha.ContainsKey($LlvmVersion)) {
    throw ("No SHA256 pin for the llvm-project-$LlvmVersion source tarball - add it to " +
        "`$llvmSrcSha in this script AND in build-tvm-from-source.ps1. Refusing an unpinned download (backlog #47).")
}

$null = New-Item -ItemType Directory -Force -Path $SourceRoot
$tarball = Join-Path $SourceRoot "llvm-project-$LlvmVersion.src.tar.xz"
$srcDir = Join-Path $SourceRoot "llvm-project-$LlvmVersion.src"

if (-not (Test-Path $srcDir)) {
    Invoke-DownloadWithRetry `
        -Url "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/llvm-project-$LlvmVersion.src.tar.xz" `
        -DestinationPath $tarball -ExpectedSha256 $llvmSrcSha[$LlvmVersion] `
        -Description "llvm-project $LlvmVersion source tarball"
    # System32 bsdtar (xz support baked in); git's GNU tar would need xz.exe.
    $tarExe = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
    if (-not $tarExe) { throw 'No tar.exe found to extract the LLVM source tarball.' }
    & $tarExe -xf $tarball -C $SourceRoot
    if (-not (Test-Path $srcDir)) { throw "LLVM source did not extract to $srcDir - upstream archive layout changed." }
}

# The two AArch64 sizing fixes (upstream llvm#219275, llvm#219276), applied by the
# same helper the OpenCV patches use so a drifted patch fails loudly here.
$patchDir = Join-Path $scriptAssetRoot 'patches\llvm'
foreach ($p in @('001-aarch64-ehlabel-size.patch', '002-aarch64-seh-pseudo-size.patch')) {
    Invoke-SourcePatch -PatchFile (Join-Path $patchDir $p) -SourceDir $srcDir `
        -Description "llvm: $p" -IgnoreWhitespace
}

# Drift assertion: a silently unapplied patch rebuilds the very bug this stage
# removes, and would only resurface hours later as an unattributable MC error.
$instrInfo = Join-Path $srcDir 'llvm\lib\Target\AArch64\AArch64InstrInfo.cpp'
$text = [System.IO.File]::ReadAllText($instrInfo)
if ($text -notmatch 'eh-asynch') {
    throw ("AArch64InstrInfo.cpp carries no eh-asynch check after patching - the EH_LABEL fix did not " +
        "apply (llvm#219275). Without it OpenCV's protobuf TUs abort with 'value evaluated as <N> is out of range'.")
}
if ($text -notmatch 'isSEHInstruction\(MI\)\s*\)?\s*\r?\n?\s*return 0;') {
    Write-Warning 'The SEH sizing patch (llvm#219276) may not have applied - check the patch against this LLVM version.'
}

Enter-VsDevCmdEnvironment

$buildDir = Join-Path $SourceRoot 'build'
$null = New-Item -ItemType Directory -Force -Path $buildDir

# X86 stays in the target list: this is the HOST compiler for the cross lane and
# the amd64 lane uses the same image.
$cmakeArgs = @(
    '-G', 'Ninja',
    '-S', (Join-Path $srcDir 'llvm'),
    '-B', $buildDir,
    '-DCMAKE_BUILD_TYPE=Release',
    '-DLLVM_ENABLE_PROJECTS=clang;lld',
    '-DLLVM_TARGETS_TO_BUILD=AArch64;X86',
    "-DCMAKE_INSTALL_PREFIX=$InstallPrefix",
    '-DLLVM_ENABLE_ASSERTIONS=OFF',
    '-DLLVM_INCLUDE_TESTS=OFF',
    '-DLLVM_INCLUDE_BENCHMARKS=OFF',
    '-DLLVM_INCLUDE_EXAMPLES=OFF',
    '-DLLVM_ENABLE_PDB=OFF',
    # DIA needs ATL, absent from the container's VS Build Tools (C1083), and only
    # powers PDB symbolisation in the LLVM tools.
    '-DLLVM_ENABLE_DIA_SDK=OFF'
)
if ($env:SCCACHE_DIR -or $env:SCCACHE_SERVE) {
    $cmakeArgs += '-DCMAKE_C_COMPILER_LAUNCHER=sccache', '-DCMAKE_CXX_COMPILER_LAUNCHER=sccache'
    Write-Host 'sccache launcher enabled for the LLVM build'
}

Write-Host 'Configuring clang/LLVM...'
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "LLVM cmake configure failed ($LASTEXITCODE)" }

Write-Host 'Building clang/LLVM (this is the expensive one; it caches as a layer)...'
& cmake --build $buildDir --target install
if ($LASTEXITCODE -ne 0) { throw "LLVM build/install failed ($LASTEXITCODE)" }

if (-not (Test-Path $clangCl)) { throw "clang-cl.exe not found at $clangCl after install." }
$banner = (& $clangCl --version | Select-Object -First 1)
Write-Host "Installed: $banner"
# The banner must still say the pinned version or verify-toolchain.ps1's
# provenance gate rejects this compiler.
if ($banner -notmatch [regex]::Escape($LlvmVersion)) {
    throw "Built clang reports '$banner' but LLVM_WINDOWS_VERSION is $LlvmVersion - the provenance gate would fail."
}
Write-Host "Patched clang installed to $InstallPrefix - put its bin\ ahead of the scoop shims on PATH."
