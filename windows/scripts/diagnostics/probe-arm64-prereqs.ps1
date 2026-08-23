#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Phase 0 of the Windows arm64 cross lane: answer, against the EXISTING base
    image and without rebuilding anything, the upstream facts the whole lane
    rests on.

.DESCRIPTION
    Every arm64 claim in this repo is currently a derivation. Nothing has been
    built and no arm64 binary has ever run. Most of the open questions are not
    about our code at all -- they are upstream facts (does the pinned clang-cl
    emit AArch64, is the Windows SDK really architecture-complete, does LunarG's
    maintenancetool exist in scoop's app dir) that no amount of static analysis
    can settle.

    This probe settles them in minutes instead of a 33-minute base rebuild,
    because it runs against the base image that already exists.

    REPORTING ONLY. It installs nothing, changes nothing, and never throws on a
    negative result -- a "no" here is data, not a failure. It exits non-zero
    only when the probe could not be carried out at all (wrong base image), so
    a broken probe can never masquerade as a clean answer.

    READ THE CONTROL FIRST. Q4 (MSVC lib\arm64) is EXPECTED TO FAIL on a base
    predating the VC.Tools.ARM64 change. If it reports OK you are probing a
    newer image than you think; if every question reports OK, distrust the run.

.PARAMETER Nonce
    Cache-buster forwarded by run-diagnostic-probe.ps1. Without it the RUN is
    served from the layer cache and an OLD verdict is reprinted as if fresh.

.EXAMPLE
    .\windows\scripts\diagnostics\run-diagnostic-probe.ps1 `
        -ProbeScript probe-arm64-prereqs.ps1 `
        -BaseImage docker.io/local/kataglyphis:bk-windows-base
#>
[CmdletBinding()]
param(
    [string]$Nonce = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

Write-Host "=== arm64 prerequisite probe nonce=$Nonce ==="
Write-Host ''

# Report-only helpers. Deliberately NOT Assert-*: a negative answer here is the
# measurement, not an error, and a probe that aborts on the first 'no' would
# hide every answer after it -- which is the whole point of running this.
$script:Findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Detail = ''
    )
    $mark = if ($Ok) { '[ OK ]' } else { '[FAIL]' }
    Write-Host ("{0} {1}" -f $mark, $Question)
    if ($Detail) { Write-Host ("       {0}" -f $Detail) }
    $script:Findings.Add([pscustomobject]@{ Question = $Question; Ok = $Ok; Detail = $Detail })
}

# Sanity: are we in the image we think we are? This is the ONLY hard failure in
# the probe -- everything else is a question whose answer may legitimately be no.
foreach ($tool in @('clang-cl', 'lld-link')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not on PATH -- this is not a Kataglyphis Windows base image, so no answer here would mean anything."
    }
}
Write-Host ("clang-cl : " + ((& clang-cl --version 2>&1 | Select-Object -First 1)))
Write-Host ("lld-link : " + ((& lld-link --version 2>&1 | Select-Object -First 1)))
Write-Host ''

# ---------------------------------------------------------------------------
# Q1 -- THE load-bearing assumption: can the pinned clang-cl emit AArch64?
#
# If this is false the entire cross lane is void, and everything else in this
# repo's arm64 work is moot. It has never been tested.
# ---------------------------------------------------------------------------
$triple = 'aarch64-pc-windows-msvc'
$stem = Join-Path $env:TEMP ('arm64probe-' + [guid]::NewGuid().ToString('N'))
$src = "$stem.c"
$obj = "$stem.obj"
Set-Content -LiteralPath $src -Value 'int probe(int x){return x+1;}' -Encoding ASCII
$clangOut = (& clang-cl "--target=$triple" /c $src "/Fo$obj" 2>&1 | Out-String).Trim()
if (Test-Path $obj) {
    # An unlinked COFF object starts with IMAGE_FILE_HEADER, so bytes 0..1 ARE
    # the Machine field (little-endian) -- no PE offset walk needed.
    $b = [System.IO.File]::ReadAllBytes($obj)
    # [int] casts are LOAD-BEARING. PowerShell's -shl keeps the LEFT operand's
    # type, so [byte]0xAA -shl 8 overflows to 0, not 0xAA00. Without them this
    # reads 0x0064 for a perfectly good ARM64 object -- a false FAIL on the one
    # question that decides whether the cross lane is viable at all.
    $machine = [int]$b[0] -bor ([int]$b[1] -shl 8)
    Add-Finding -Question "clang-cl emits AArch64 objects (--target=$triple)" `
        -Ok ($machine -eq 0xAA64) `
        -Detail ('object machine 0x{0:X4} (expect 0xAA64 = ARM64)' -f $machine)
} else {
    Add-Finding -Question "clang-cl emits AArch64 objects (--target=$triple)" -Ok $false `
        -Detail ("no object produced. clang-cl said: " + ($clangOut -split "`n" | Select-Object -First 3) -join ' | ')
}

# ---------------------------------------------------------------------------
# Q2 -- is the Windows SDK really architecture-complete?
#
# setup-vs.ps1's comment asserts this to justify NOT adding an SDK component
# alongside VC.Tools.ARM64. If it is wrong, the base change is incomplete and
# an arm64 link would fail on kernel32.lib.
# ---------------------------------------------------------------------------
$sdkLibRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
$sdkArm = Get-ChildItem $sdkLibRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'um\arm64\kernel32.lib' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
Add-Finding -Question 'Windows SDK ships um\arm64 import libs (architecture-complete)' `
    -Ok ([bool]$sdkArm) `
    -Detail $(if ($sdkArm) { $sdkArm } else { "none found under $sdkLibRoot" })

# ---------------------------------------------------------------------------
# Q3 -- does LunarG's maintenancetool.exe exist where setup-scoop-tools expects it?
#
# The component-add step was written blind. This kills or confirms the first of
# its three unknowns for free -- and it is the one that decides whether the
# other two are even worth investigating.
# ---------------------------------------------------------------------------
$vkRoot = if ($env:VULKAN_SDK) { $env:VULKAN_SDK } else { Join-Path $env:USERPROFILE 'scoop\apps\vulkan\current' }
$maintenanceTool = Join-Path $vkRoot 'maintenancetool.exe'
Add-Finding -Question 'Vulkan SDK carries maintenancetool.exe (component-add is possible at all)' `
    -Ok (Test-Path $maintenanceTool) -Detail $maintenanceTool
if (Test-Path $vkRoot) {
    $vkSubs = (Get-ChildItem $vkRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    Write-Host "       VULKAN_SDK = $vkRoot"
    Write-Host "       subdirs    : $vkSubs"
    # Expected absent on a base predating the component change; listed so the
    # NEXT run (post-rebuild) has a directly comparable line.
    Add-Finding -Question 'Vulkan Lib-ARM64 present (expected NO before the base rebuild)' `
        -Ok (Test-Path (Join-Path $vkRoot 'Lib-ARM64')) -Detail (Join-Path $vkRoot 'Lib-ARM64')
}

# ---------------------------------------------------------------------------
# Q4 -- CONTROL. Expected to FAIL on a base built before VC.Tools.ARM64.
#
# Its job is to prove the probe is honest. An all-green run means you are
# probing a different image than you think.
# ---------------------------------------------------------------------------
$vcToolsRoots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) |
    Where-Object { $_ } |
    ForEach-Object { Join-Path $_ 'Microsoft Visual Studio' } |
    Where-Object { Test-Path $_ }
$msvcArm = $vcToolsRoots |
    ForEach-Object { Get-ChildItem $_ -Recurse -Directory -Filter 'MSVC' -ErrorAction SilentlyContinue } |
    ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } |
    ForEach-Object { Join-Path $_.FullName 'lib\arm64\libcmt.lib' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
Add-Finding -Question 'CONTROL: MSVC lib\arm64 present (expected NO on a pre-rebuild base)' `
    -Ok ([bool]$msvcArm) `
    -Detail $(if ($msvcArm) { "$msvcArm -- you are probing a NEWER base than expected" } else { 'absent, as expected: VC.Tools.ARM64 not installed in this image' })

# ---------------------------------------------------------------------------
# Q5 -- which compiler-rt builtins libs ship?
#
# build-gstreamer hands one of these to every link. Knowing now whether an
# aarch64 variant exists saves discovering it 90 minutes into a GStreamer build.
# ---------------------------------------------------------------------------
$llvmLibRoot = Join-Path $env:USERPROFILE 'scoop\apps\llvm\current\lib\clang'
$builtins = @(Get-ChildItem $llvmLibRoot -Recurse -Filter 'clang_rt.builtins-*.lib' -ErrorAction SilentlyContinue)
$builtinNames = ($builtins | Select-Object -ExpandProperty Name | Sort-Object -Unique) -join ', '
Add-Finding -Question 'compiler-rt builtins for aarch64 available' `
    -Ok ([bool]($builtins | Where-Object { $_.Name -match 'aarch64' })) `
    -Detail $(if ($builtinNames) { "found: $builtinNames" } else { "no clang_rt.builtins-*.lib under $llvmLibRoot" })

# ---------------------------------------------------------------------------
# Q5b -- is there an aarch64 OpenSSL beside the x64 one?
#
# scoop installs ONE architecture per app, so the image's openssl is the host's.
# Four GStreamer targets link OpenSSL (gst-plugins-bad ext/hls, ext/dtls, ext/aes
# and glib-networking's openssl TLS backend), and they fail at LINK -- ~25 minutes
# into the merge stage -- not at configure. setup-scoop-tools.ps1 installs the
# arm64 build beside the x64 one under C:\opt\openssl-arm64.
#
# Searched, never composed: innounp unpacks InnoSetup payloads under a literal
# '{app}' directory, so the real path is {app}\lib\VC\arm64\MD\libcrypto.lib and
# any hardcoded guess would report a false negative.
# ---------------------------------------------------------------------------
$sslArm64Root = 'C:\opt\openssl-arm64'
$sslArm64Hit = @(Get-ChildItem $sslArm64Root -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue)
Add-Finding -Question 'aarch64 OpenSSL available (gst hls/dtls/aes + glib-networking TLS)' `
    -Ok ([bool]$sslArm64Hit.Count) `
    -Detail $(if ($sslArm64Hit.Count) { "found: $($sslArm64Hit[0].FullName)" } else { "no libcrypto.lib under $sslArm64Root" })

# ---------------------------------------------------------------------------
# Q6 -- which vcpkg triplets are materialized right now?
# ---------------------------------------------------------------------------
$vcpkgInstalled = 'C:\vcpkg\installed'
$triplets = @(Get-ChildItem $vcpkgInstalled -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
Add-Finding -Question 'vcpkg arm64-windows triplet already installed (expected NO pre-rebuild)' `
    -Ok ($triplets -contains 'arm64-windows') `
    -Detail $(if ($triplets) { "installed triplets: $($triplets -join ', ')" } else { "no vcpkg tree at $vcpkgInstalled" })

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== summary ==='
foreach ($f in $script:Findings) {
    Write-Host ("{0} {1}" -f $(if ($f.Ok) { '[ OK ]' } else { '[FAIL]' }), $f.Question)
}
$okCount = @($script:Findings | Where-Object { $_.Ok }).Count
Write-Host ''
Write-Host ("{0}/{1} questions answered YES" -f $okCount, $script:Findings.Count)
Write-Host ''
Write-Host 'Reading the result:'
Write-Host '  Q1 NO  -> the cross lane is void as designed; nothing else matters. Stop and reconsider.'
Write-Host '  Q2 NO  -> setup-vs.ps1 needs an SDK component too, not just VC.Tools.ARM64.'
Write-Host '  Q3 NO  -> the Vulkan component-add cannot work as written; rewrite it before the rebuild.'
Write-Host '  Q4 YES -> you probed the WRONG image. Distrust every line above.'
Write-Host ''
Write-Host 'probe complete'
