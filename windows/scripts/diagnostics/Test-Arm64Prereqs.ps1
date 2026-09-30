#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Answers the upstream facts the Windows arm64 cross lane rests on, against the existing base image.
.DESCRIPTION
    Report-only: a "no" is data; it throws only when run in the wrong image.
    Read the control first: Q4 must say NO on a pre-rebuild base, and an all-OK run is not to be trusted.
.PARAMETER Nonce
    Cache-buster from Invoke-DiagnosticProbe.ps1, so a cached old verdict is never reprinted.
.EXAMPLE
    .\windows\scripts\diagnostics\Invoke-DiagnosticProbe.ps1 `
        -ProbeScript Test-Arm64Prereqs.ps1 `
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

# Not Assert-*: aborting on the first 'no' would hide every answer after it.
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

# The only hard failure: the wrong image would make every answer meaningless.
foreach ($tool in @('clang-cl', 'lld-link')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not on PATH -- this is not a Kataglyphis Windows base image, so no answer here would mean anything."
    }
}
Write-Host ("clang-cl : " + ((& clang-cl --version 2>&1 | Select-Object -First 1)))
Write-Host ("lld-link : " + ((& lld-link --version 2>&1 | Select-Object -First 1)))
Write-Host ''

# Q1: can the pinned clang-cl emit AArch64? If not, the whole cross lane is void.
$triple = 'aarch64-pc-windows-msvc'
$stem = Join-Path $env:TEMP ('arm64probe-' + [guid]::NewGuid().ToString('N'))
$src = "$stem.c"
$obj = "$stem.obj"
Set-Content -LiteralPath $src -Value 'int probe(int x){return x+1;}' -Encoding ASCII
$clangOut = (& clang-cl "--target=$triple" /c $src "/Fo$obj" 2>&1 | Out-String).Trim()
if (Test-Path $obj) {
    # A COFF object starts with IMAGE_FILE_HEADER, so bytes 0..1 are the Machine field.
    $b = [System.IO.File]::ReadAllBytes($obj)
    # The [int] casts matter: -shl keeps the left operand's type, so [byte]0xAA -shl 8 is 0.
    $machine = [int]$b[0] -bor ([int]$b[1] -shl 8)
    Add-Finding -Question "clang-cl emits AArch64 objects (--target=$triple)" `
        -Ok ($machine -eq 0xAA64) `
        -Detail ('object machine 0x{0:X4} (expect 0xAA64 = ARM64)' -f $machine)
} else {
    Add-Finding -Question "clang-cl emits AArch64 objects (--target=$triple)" -Ok $false `
        -Detail ("no object produced. clang-cl said: " + ($clangOut -split "`n" | Select-Object -First 3) -join ' | ')
}

# Q2: is the Windows SDK architecture-complete, as Install-Vs.ps1 assumes? If not, arm64 links fail on kernel32.lib.
$sdkLibRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
$sdkArm = Get-ChildItem $sdkLibRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'um\arm64\kernel32.lib' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
Add-Finding -Question 'Windows SDK ships um\arm64 import libs (architecture-complete)' `
    -Ok ([bool]$sdkArm) `
    -Detail $(if ($sdkArm) { $sdkArm } else { "none found under $sdkLibRoot" })

# Q3: does LunarG's maintenancetool.exe exist where the Vulkan component-add expects it?
$vkRoot = if ($env:VULKAN_SDK) { $env:VULKAN_SDK } else { Join-Path $env:USERPROFILE 'scoop\apps\vulkan\current' }
$maintenanceTool = Join-Path $vkRoot 'maintenancetool.exe'
Add-Finding -Question 'Vulkan SDK carries maintenancetool.exe (component-add is possible at all)' `
    -Ok (Test-Path $maintenanceTool) -Detail $maintenanceTool
if (Test-Path $vkRoot) {
    $vkSubs = (Get-ChildItem $vkRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    Write-Host "       VULKAN_SDK = $vkRoot"
    Write-Host "       subdirs    : $vkSubs"
    # Expected absent before the rebuild; listed so the next run has a comparable line.
    Add-Finding -Question 'Vulkan Lib-ARM64 present (expected NO before the base rebuild)' `
        -Ok (Test-Path (Join-Path $vkRoot 'Lib-ARM64')) -Detail (Join-Path $vkRoot 'Lib-ARM64')
}

# Q4, the control: must fail on a base built before VC.Tools.ARM64, proving the probe honest.
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

# Q5: is there an aarch64 compiler-rt builtins lib? The GStreamer build hands one to every link.
$llvmLibRoot = Join-Path $env:USERPROFILE 'scoop\apps\llvm\current\lib\clang'
$builtins = @(Get-ChildItem $llvmLibRoot -Recurse -Filter 'clang_rt.builtins-*.lib' -ErrorAction SilentlyContinue)
$builtinNames = ($builtins | Select-Object -ExpandProperty Name | Sort-Object -Unique) -join ', '
Add-Finding -Question 'compiler-rt builtins for aarch64 available' `
    -Ok ([bool]($builtins | Where-Object { $_.Name -match 'aarch64' })) `
    -Detail $(if ($builtinNames) { "found: $builtinNames" } else { "no clang_rt.builtins-*.lib under $llvmLibRoot" })

# Q5b: an aarch64 OpenSSL beside scoop's host one? Searched, since innounp nests it under a literal {app} dir.
$sslArm64Root = 'C:\opt\openssl-arm64'
$sslArm64Hit = @(Get-ChildItem $sslArm64Root -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue)
Add-Finding -Question 'aarch64 OpenSSL available (gst hls/dtls/aes + glib-networking TLS)' `
    -Ok ([bool]$sslArm64Hit.Count) `
    -Detail $(if ($sslArm64Hit.Count) { "found: $($sslArm64Hit[0].FullName)" } else { "no libcrypto.lib under $sslArm64Root" })

# Q6: which vcpkg triplets are materialized?
$vcpkgInstalled = 'C:\vcpkg\installed'
$triplets = @(Get-ChildItem $vcpkgInstalled -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
Add-Finding -Question 'vcpkg arm64-windows triplet already installed (expected NO pre-rebuild)' `
    -Ok ($triplets -contains 'arm64-windows') `
    -Detail $(if ($triplets) { "installed triplets: $($triplets -join ', ')" } else { "no vcpkg tree at $vcpkgInstalled" })

# Summary
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
Write-Host '  Q2 NO  -> Install-Vs.ps1 needs an SDK component too, not just VC.Tools.ARM64.'
Write-Host '  Q3 NO  -> the Vulkan component-add cannot work as written; rewrite it before the rebuild.'
Write-Host '  Q4 YES -> you probed the WRONG image. Distrust every line above.'
Write-Host ''
Write-Host 'probe complete'
