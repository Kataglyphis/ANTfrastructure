#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Builds clang/LLVM at the pinned LLVM_WINDOWS_VERSION from source, carrying
    the two AArch64 instruction-size fixes this repo needs, and installs it
    where it shadows the scoop clang-cl.

.DESCRIPTION
    WHY THIS EXISTS. The cross lane pays for two workarounds in
    build-opencv-from-source.ps1 -- `+force-32bit-jump-tables` for the whole
    build and `/Ob1` on two TUs -- because clang-cl 23.1.0 aborts on
    OpenCV/protobuf sources for aarch64:

        error: value evaluated as <N> is out of range.
        error: fixup value out of range

    Root cause (backlog #135 (a2)): AsmPrinter emits a NOP after an EH_LABEL
    under async EH (/EHa, which OpenCV passes), while getInstSizeInBytes reports
    EH_LABEL as a zero-size meta-instruction. Every MIR-level block-size
    estimate is then 4 bytes short per label, and both consumers --
    BranchRelaxation and AArch64CompressJumpTables -- pick an encoding the
    assembler rejects. Filed upstream as llvm/llvm-project#219275; the SEH
    sizing companion is #219276.

    WHY 23.1.0 AND NOT main. Both fixes apply CLEANLY to the pinned 23.1.0
    release, which matters for three separate reasons:
      * clang still reports `clang version 23.1.0`, so verify-toolchain.ps1's
        provenance gate passes with LLVM_WINDOWS_VERSION unchanged;
      * every clang-cl-shaped source patch under windows/scripts/patches/ was
        written against 23.1.0 behaviour (#129 probes, mlasi.h, softfloat) and
        stays valid;
      * a jump to LLVM 24 is a major-version move that would disturb all of the
        above for no additional benefit here.
    Verified 2026-08-27: both patches `git apply --check` clean on llvmorg-23.1.0.

    PROVENANCE. Same pinned tarball and SHA256 the TVM stage already uses, so
    the download policy (backlog #47: never fetch unpinned) is satisfied by a
    pin that is already in the repo. Nothing is fetched from a fork or a git
    revision; the delta is exactly the two .patch files under
    windows/scripts/patches/llvm/, which are the upstream commits.

    COST. This is a large build -- clang plus LLVM, X86 and AArch64 targets.
    It is a base-layer concern, so it is paid once and cached; sccache is used
    when SCCACHE_DIR/serve are configured, exactly as the other source builds do.

.PARAMETER InstallPrefix
    Where the built toolchain lands. Must come BEFORE the scoop shims on PATH
    for the lane to pick it up -- every build script resolves the compiler by
    bare name (`$env:CC = 'clang-cl'`, `--cc=clang-cl`), so shadowing is all
    that is required and no build script changes.

.PARAMETER SkipIfPresent
    Do nothing when a patched clang is already installed at the prefix. Lets the
    stage be re-entered cheaply.
#>
[CmdletBinding()]
param(
    [string]$LlvmVersion = '',
    [string]$InstallPrefix = 'C:\llvm-patched',
    [string]$SourceRoot = 'C:\temp\llvm-src',
    [switch]$SkipIfPresent
)

$ErrorActionPreference = 'Stop'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets live beside this script in the flat
# layout and one level up in the repo layout.
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

# SHA pins per version. An unknown version must THROW rather than download
# unpinned (backlog #47). Keep in step with the table in
# build-tvm-from-source.ps1 -- both consume the same tarball.
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

# --- the two AArch64 sizing fixes -------------------------------------------
# Applied by the SAME helper the OpenCV patches use, so a drifted patch fails
# loudly here rather than producing a silently-unpatched compiler. Both are
# upstream commits, not local inventions: llvm#219275 and llvm#219276.
$patchDir = Join-Path $scriptAssetRoot 'patches\llvm'
foreach ($p in @('001-aarch64-ehlabel-size.patch', '002-aarch64-seh-pseudo-size.patch')) {
    Invoke-SourcePatch -PatchFile (Join-Path $patchDir $p) -SourceDir $srcDir `
        -Description "llvm: $p" -IgnoreWhitespace
}

# Load-bearing drift assertion: a silently unapplied patch here would rebuild
# the very compiler bug this stage exists to remove, and the failure would only
# resurface hours later in the OpenCV stage as an unattributable MC-layer error.
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
    # DIA needs ATL (atlbase.h), which the container's VS Build Tools does not
    # install: llvm/DebugInfo/PDB/DIA dies with C1083. DIA only powers PDB
    # symbolisation in the LLVM tools, nothing the compiler itself needs.
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
# The banner must still say the pinned version, or verify-toolchain.ps1's
# provenance gate will reject this compiler. Building the release plus patches
# rather than a main snapshot is what keeps that true.
if ($banner -notmatch [regex]::Escape($LlvmVersion)) {
    throw "Built clang reports '$banner' but LLVM_WINDOWS_VERSION is $LlvmVersion - the provenance gate would fail."
}
Write-Host "Patched clang installed to $InstallPrefix - put its bin\ ahead of the scoop shims on PATH."
