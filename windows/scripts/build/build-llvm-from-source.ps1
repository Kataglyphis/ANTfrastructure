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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #108: container mounts are FLAT (C:\temp\scripts), the repo nests one level deeper.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$LlvmVersion = Get-SourceBuildVersion -EnvironmentVariables @('LLVM_WINDOWS_VERSION') -DefaultValue '23.1.0'
Write-Host "=== clang/LLVM $LlvmVersion source build (AArch64 instruction-size fixes) ==="

# Toolchain-level home for the aarch64 builtins (#135 follow-up, landed in the
# 2026-08-31 rebuild window). The source build ships host builtins only, so the
# arm64 GStreamer link died on __udivti3 and the merge stage self-healed by
# downloading this lib EVERY cross run. Staging it here makes the toolchain image
# complete; the merge self-heal stays as the fallback and now never fires.
# FAIL-OPEN (warning): only the cross lane needs the lib, and the downstream
# self-heal still covers a miss - a GitHub blip must not kill the LLVM layer.
function Install-TargetCompilerRt {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$Version)
    $existing = @(Get-ChildItem -Path (Join-Path $Prefix 'lib\clang') -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) { Write-Host "aarch64 compiler-rt already staged ($($existing[0].FullName))."; return }
    $hostLib = @(Get-ChildItem -Path (Join-Path $Prefix 'lib\clang') -Recurse -Filter 'clang_rt.builtins-x86_64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($hostLib.Count -eq 0) { Write-Warning 'clang_rt.builtins-x86_64.lib not found - cannot place the aarch64 lib; merge-stage self-heal will cover the cross lane.'; return }
    $tmp = if ($env:TEMP_DIR) { $env:TEMP_DIR } else { $env:TEMP }
    $rtArchive = Join-Path $tmp "clang+llvm-$Version-aarch64-pc-windows-msvc.tar.xz"
    $rtExtract = Join-Path $tmp 'llvm-aarch64-rt'
    try {
        Write-Host "Staging aarch64 compiler-rt from the LLVM $Version release archive..."
        Invoke-DownloadWithRetry -Url "https://github.com/llvm/llvm-project/releases/download/llvmorg-$Version/clang%2Bllvm-$Version-aarch64-pc-windows-msvc.tar.xz" -DestinationPath $rtArchive
        $rtSha = "$env:LLVM_WINDOWS_AARCH64_RT_SHA256".Trim()
        if (-not $rtSha) {
            # The patched-llvm RUN bakes no env for this pin; it mounts versions.env
            # as this script's SIBLING (container layout) - read the key from there.
            $envFile = Join-Path $PSScriptRoot 'versions.env'
            if (Test-Path $envFile) {
                $m = [regex]::Match((Get-Content $envFile -Raw), '(?m)^LLVM_WINDOWS_AARCH64_RT_SHA256=(\S+)\s*$')
                if ($m.Success) { $rtSha = $m.Groups[1].Value }
            }
        }
        if ($rtSha) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $rtArchive).Hash
            if (-not [string]::Equals($actual, $rtSha, [StringComparison]::OrdinalIgnoreCase)) { throw "aarch64 compiler-rt archive SHA256 mismatch: expected $rtSha, got $actual" }
            Write-Host 'aarch64 compiler-rt archive SHA256 verified (LLVM_WINDOWS_AARCH64_RT_SHA256).'
        } else {
            Write-Warning 'LLVM_WINDOWS_AARCH64_RT_SHA256 is empty - staging the aarch64 compiler-rt UNVERIFIED (pin it in versions.env, same contract as the QNN/TensorRT zips).'
        }
        # System32 bsdtar, never GNU tar: GNU parses C:\... as a remote-host spec.
        $rtTar = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
        if (-not $rtTar) { throw 'No tar.exe found to extract the aarch64 compiler-rt archive.' }
        New-Item -ItemType Directory -Force -Path $rtExtract | Out-Null
        & $rtTar -xf $rtArchive -C $rtExtract '*clang_rt.builtins-aarch64.lib'
        $found = @(Get-ChildItem -Path $rtExtract -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($found.Count -eq 0) { throw "clang_rt.builtins-aarch64.lib not found inside $rtArchive - upstream archive layout changed." }
        Copy-Item -Path $found[0].FullName -Destination $hostLib[0].Directory.FullName -Force
        Write-Host "aarch64 compiler-rt staged -> $(Join-Path $hostLib[0].Directory.FullName 'clang_rt.builtins-aarch64.lib')"
    } catch {
        Write-Warning "aarch64 compiler-rt staging failed: $($_.Exception.Message) - the merge-stage self-heal still covers the cross lane."
    } finally {
        Remove-Item -Path $rtArchive -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $rtExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$clangCl = Join-Path $InstallPrefix 'bin\clang-cl.exe'
if ($SkipIfPresent -and (Test-Path $clangCl)) {
    # NOT a bare return: a cached C:\llvm-patched from before 2026-08-31 has no
    # aarch64 builtins, and skipping the staging here would leave it that way forever.
    Write-Host "Patched clang already present at $clangCl - verifying the aarch64 compiler-rt staging."
    Install-TargetCompilerRt -Prefix $InstallPrefix -Version $LlvmVersion
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
    '-DLLVM_ENABLE_RUNTIMES=compiler-rt',
    '-DLLVM_TARGETS_TO_BUILD=AArch64;X86',
    "-DCMAKE_INSTALL_PREFIX=$InstallPrefix",
    '-DLLVM_ENABLE_ASSERTIONS=OFF',
    '-DLLVM_INCLUDE_TESTS=OFF',
    '-DLLVM_INCLUDE_BENCHMARKS=OFF',
    '-DLLVM_INCLUDE_EXAMPLES=OFF',
    '-DLLVM_ENABLE_PDB=OFF',
    # DIA needs ATL, absent from the container's VS Build Tools (C1083), and only
    # powers PDB symbolisation in the LLVM tools.
    '-DLLVM_ENABLE_DIA_SDK=OFF',
    # compiler-rt builtins only: provides __udivti3, __umodti3 etc. for lld-link.
    # The fuzzer, profile, sanitizer and ORC runtimes are unnecessary and some
    # (profile/ROCm) fail to compile under clang-cl.
    '-DCOMPILER_RT_BUILD_BUILTINS=ON',
    '-DCOMPILER_RT_BUILD_FUZZER=OFF',
    '-DCOMPILER_RT_BUILD_PROFILE=OFF',
    '-DCOMPILER_RT_BUILD_SANITIZERS=OFF',
    '-DCOMPILER_RT_BUILD_ORC=OFF',
    '-DCOMPILER_RT_BUILD_MEMPROF=OFF',
    '-DCOMPILER_RT_BUILD_XRAY=OFF',
    '-DCOMPILER_RT_BUILD_CTX_PROFILE=OFF'
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
Install-TargetCompilerRt -Prefix $InstallPrefix -Version $LlvmVersion
Write-Host "Patched clang installed to $InstallPrefix - put its bin\ ahead of the scoop shims on PATH."
