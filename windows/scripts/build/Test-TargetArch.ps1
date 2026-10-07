#requires -Version 7.0

# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Asserts every shipped binary in a tree was built for the expected target architecture.
.DESCRIPTION
    The cross lane's output cannot run here, so this static check catches x64 leakage from host tools or vendor DLLs.
    See docs/windows-cross-builds.md § Verification.
.PARAMETER Path
    One or more roots to scan. Defaults to C:\runtime.
.PARAMETER Arch
    Expected target architecture. Defaults to the resolved WINDOWS_TARGET_ARCH.
.PARAMETER MinInspected
    Minimum number of binaries inspected for the run to count; 0 needs -AllowEmptyTree.
.PARAMETER HostToolPattern
    Regex of full paths allowed to stay host-architecture (build tools that never ship).
.PARAMETER IncludeArchives
    Also verify .lib archives; off by default because vendor static archives are noisy.
.EXAMPLE
    Test-TargetArch.ps1 -Path C:\runtime -Arch arm64 -MinInspected 20
#>

#requires -Version 7.0

[CmdletBinding()]
param(
    [string[]]$Path = @('C:\runtime'),
    [string]$Arch = '',
    [int]$MinInspected = 1,
    [string]$HostToolPattern = '',
    [switch]$IncludeArchives,
    # Resolves every import against bundle, API sets and System32 (never the CRT on cross): the 0xC0000135 class; extracts and machine-checks every wheel too.
    [switch]$ImportWalk,
    # Regex of driver-, toolkit- or device-interpreter-provided imports; reported, never counted (python313.dll: the cp313 torch stack's interpreter).
    [string]$ImportAllowlist = '^(nvcuda|nvml|nvapi64|cudart64_[0-9]+|cublas|cublasLt|cudnn|nvinfer|nvonnxparser|nvrtc|cufft|curand|cusparse|cusolver|nvjitlink|nvcomp|vulkan-1|opengl32|d3d12core|QnnHtp|QnnCpu|QnnSystem)[A-Za-z0-9_-]*\.dll$|^python313\.dll$',
    # DLLs every client SKU ships but Server Core lacks, plus Qualcomm's FastRPC drivers; reported as device OS, never counted.
    [string]$ClientOsPattern = '^(dsound|mf|mfplat|mfreadwrite|mfcore|winspool)\.(dll|drv)$|^lib(cds|ads)prpc\.dll$',
    # The tree ships without the image behind it (a relocatable app bundle): the walk gates as on a cross lane.
    [switch]$Standalone,
    # Required for -MinInspected 0 or less, so a dropped build-arg cannot disable the floor.
    [switch]$AllowEmptyTree
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$archModulePath = Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1'
if (-not (Test-Path $archModulePath)) { throw "Required module not found: $archModulePath" }
Import-Module $archModulePath -Force

$targetArch = Get-WindowsTargetArch -Arch $Arch
$expected = Get-PeMachineType -Arch $targetArch
$expectedName = (Get-WindowsTargetArchInfo -Arch $targetArch).PeMachineName

# Named, so a diagnostic says what was found instead of a bare hex number.
$machineNames = @{
    0x0000 = 'UNKNOWN'
    0x014C = 'I386'
    0x8664 = 'AMD64'
    0xAA64 = 'ARM64'
    0xA641 = 'ARM64EC'
    0xA64E = 'ARM64X'
    0x01C0 = 'ARM'
    0x01C4 = 'ARMNT'
    0x0200 = 'IA64'
    0x5032 = 'RISCV32'
    0x5064 = 'RISCV64'
}

# ARM64EC and ARM64X belong to the ARM64 family and appear in Microsoft's own SDK libs.
$acceptedMachines = @{
    0x8664 = @(0x8664)
    0xAA64 = @(0xAA64, 0xA641, 0xA64E)
}
function Format-Machine {
    param([int]$Value)
    $name = if ($machineNames.ContainsKey($Value)) { $machineNames[$Value] } else { 'UNRECOGNIZED' }
    return ('0x{0:X4} ({1})' -f $Value, $name)
}

# COFF machine of a PE image or object; $null keeps "unreadable" apart from "wrong architecture".
function Get-CoffMachine {
    param([Parameter(Mandatory)][string]$LiteralPath)

    try {
        $fs = [System.IO.File]::OpenRead($LiteralPath)
    } catch {
        return $null
    }
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        if ($fs.Length -lt 4) { return $null }

        $mz = $br.ReadBytes(2)
        if ($mz[0] -eq 0x4D -and $mz[1] -eq 0x5A) {
            # e_lfanew at 0x3C points at "PE\0\0", followed by the COFF header whose first field is Machine.
            if ($fs.Length -lt 0x40) { return $null }
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            if ($peOffset -le 0 -or ($peOffset + 6) -ge $fs.Length) { return $null }
            $fs.Position = $peOffset
            $sig = $br.ReadBytes(4)
            if ($sig[0] -ne 0x50 -or $sig[1] -ne 0x45 -or $sig[2] -ne 0 -or $sig[3] -ne 0) { return $null }
            return [int]$br.ReadUInt16()
        }

        # An unlinked COFF object starts with IMAGE_FILE_HEADER, whose first field is Machine.
        $fs.Position = 0
        $machine = [int]$br.ReadUInt16()
        if ($machineNames.ContainsKey($machine) -and $machine -ne 0) { return $machine }
        return $null
    } catch {
        return $null
    } finally {
        $fs.Dispose()
    }
}

# Machine of a COFF archive (.lib), which is not a PE file, read from its first real member.
function Get-ArchiveMachine {
    param([Parameter(Mandatory)][string]$LiteralPath)

    try {
        $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    } catch {
        return $null
    }
    if ($bytes.Length -lt 8) { return $null }
    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
    if ($magic -ne "!<arch>`n") { return $null }

    # A malformed archive must read as unreadable, never throw and abort the whole scan unnamed.
    try {
        $pos = 8
        while (($pos + 60) -le $bytes.Length) {
            $sizeText = [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 48, 10).Trim()
            [int]$size = 0
            if (-not [int]::TryParse($sizeText, [ref]$size)) { return $null }
            if ($size -lt 0) { return $null }
            $name = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 16).Trim()
            $dataStart = $pos + 60

            # Skip linker and ARM64EC symbol members; a short-import Machine field is bytes 6..7, hence +8.
            if ($name -notmatch '^/{1,2}$' -and $name -ne '<ECSYMBOLS>' -and
                $size -ge 20 -and ($dataStart + 8) -le $bytes.Length) {
                $m0 = [int]$bytes[$dataStart] -bor ([int]$bytes[$dataStart + 1] -shl 8)
                if ($m0 -eq 0x0000 -and ([int]$bytes[$dataStart + 2] -bor ([int]$bytes[$dataStart + 3] -shl 8)) -eq 0xFFFF) {
                    # Short-import header: Sig1=0, Sig2=0xFFFF, Version, Machine.
                    return [int]$bytes[$dataStart + 6] -bor ([int]$bytes[$dataStart + 7] -shl 8)
                }
                if ($machineNames.ContainsKey($m0) -and $m0 -ne 0) { return $m0 }
            }

            # Members are 2-byte aligned.
            $next = $dataStart + $size + ($size % 2)
            if ($next -le $pos) { return $null }   # no forward progress: refuse to spin
            $pos = $next
        }
    } catch {
        return $null
    }
    return $null
}

# One tree file or wheel member, reported as -Label: a host tool is skipped, no PE/COFF is unreadable; $true once inspected.
function Add-MachineVerdict {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][string]$Label, [switch]$Archive)
    if ($HostToolPattern -and $LiteralPath -match $HostToolPattern) { $script:skippedHostTools += $Label; return $false }
    $machine = if ($Archive) { Get-ArchiveMachine -LiteralPath $LiteralPath } else { Get-CoffMachine -LiteralPath $LiteralPath }
    if ($null -eq $machine) { $script:unreadable += $Label; return $false }
    $script:inspected++
    $ok = if ($acceptedMachines.ContainsKey($expected)) { $acceptedMachines[$expected] -contains $machine } else { $machine -eq $expected }
    if (-not $ok) { $script:violations += [pscustomobject]@{ Path = $Label; Machine = $machine } }
    return $true
}

# A .pyd is a DLL too; skipping it would also hide it from -MinInspected.
$extensions = @('.dll', '.exe', '.pyd')
if ($IncludeArchives) { $extensions += '.lib' }

$inspected = 0
$skippedHostTools = @()
$unreadable = @()
$violations = @()
$script:peFiles = @()

foreach ($root in $Path) {
    if (-not (Test-Path $root)) {
        Write-Warning "verify-target-arch: path not found, skipping: $root"
        continue
    }
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
        ForEach-Object {
            $isLib = $_.Extension -ieq '.lib'
            if ((Add-MachineVerdict -LiteralPath $_.FullName -Label $_.FullName -Archive:$isLib) -and -not $isLib) { $script:peFiles += $_.FullName }
        }
}

# Static import walk
$importUnresolved = @()
$importWalked = 0
$importExternal = @()
$importClientOs = @()
if ($ImportWalk) {
    $walkFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $script:peFiles) { $walkFiles.Add($f) }
    # A wheel's native members are what pip installs on the device, so they are machine-checked like the tree.
    $wheelTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('archgate-wheels-' + [guid]::NewGuid().ToString('N'))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $wheelCount = 0
    # A cp3XYt wheel's modules may import only its python3XYt.dll; the bundle ships the GIL runtime too, so the walk resolves either.
    $ftModuleRuntime = @{}
    $ftWheelHits = [ordered]@{}
    foreach ($root in $Path) {
        foreach ($whl in @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.whl' -File -ErrorAction SilentlyContinue)) {
            # Numbered: each CPython tree's ensurepip ships the same pip wheel, and a second extract into one directory throws.
            $wheelCount++
            $dest = Join-Path $wheelTmp ('{0}-{1}' -f $wheelCount, [IO.Path]::GetFileNameWithoutExtension($whl.Name))
            [System.IO.Compression.ZipFile]::ExtractToDirectory($whl.FullName, $dest)
            $ftRuntime = if ($whl.BaseName -match '-cp(\d+)-cp\1t-[^-]+$') { "python$($Matches[1])t.dll" } else { '' }
            if ($ftRuntime) { $ftWheelHits[$whl.FullName] = 0 }
            foreach ($m in @(Get-ChildItem -Path $dest -Recurse -File -Include '*.dll', '*.pyd', '*.exe')) {
                $walkFiles.Add($m.FullName)
                $member = '{0}!{1}' -f $whl.FullName, $m.FullName.Substring($dest.Length + 1)
                if ($ftRuntime -and $m.Extension -ieq '.pyd') { $ftModuleRuntime[$m.FullName] = @($ftRuntime, $whl.FullName, $member) }
                [void](Add-MachineVerdict -LiteralPath $m.FullName -Label $member)
            }
        }
    }
    # Names only: consumers register the bundle's DLL homes, so the loader just needs the name somewhere there.
    $bundleNames = @{}
    foreach ($f in $walkFiles) { $bundleNames[([IO.Path]::GetFileName($f)).ToLowerInvariant()] = $true }
    $systemNames = @{}
    foreach ($d in @(Get-ChildItem -Path (Join-Path $env:SystemRoot 'System32') -Filter '*.dll' -File -ErrorAction SilentlyContinue)) { $systemNames[$d.Name.ToLowerInvariant()] = $true }
    # A cross device or a standalone bundle has no image PATH behind it.
    $standsAlone = (Test-WindowsCrossTarget -Arch $targetArch) -or $Standalone
    $crtPattern = '^(vcruntime|msvcp|concrt|vcomp|vccorlib|vcamp|msvcr|mfc)[0-9]'
    $ftAbiFindings = @()
    foreach ($f in $walkFiles) {
        $imports = try { Get-PeImportNames -Path $f -IncludeDelayLoad } catch { $unreadable += $f; continue }
        $importWalked++
        if ($ftModuleRuntime.ContainsKey($f)) {
            $want, $owner, $member = $ftModuleRuntime[$f]
            $runtimes = @($imports | Where-Object { $_ -match '^python\d+t?(_d)?\.dll$' })
            if ($runtimes -contains $want) { $ftWheelHits[$owner]++ }
            foreach ($other in @($runtimes | Where-Object { $_ -ne $want })) { $ftAbiFindings += "$member imports $other, not $want" }
        }
        foreach ($imp in $imports) {
            $n = $imp.ToLowerInvariant()
            if ($n -match '^(api|ext)-ms-') { continue }
            if ($bundleNames.ContainsKey($n)) { continue }
            if ($ImportAllowlist -and $imp -match $ImportAllowlist) { $importExternal += "$f -> $imp"; continue }
            $isCrt = ($n -match $crtPattern)
            if ($systemNames.ContainsKey($n) -and -not ($standsAlone -and $isCrt)) { continue }
            if ($ClientOsPattern -and $n -match $ClientOsPattern) { $importClientOs += "$f -> $imp"; continue }
            $importUnresolved += [pscustomobject]@{ File = $f; Import = $imp; Crt = $isCrt }
        }
    }
    Remove-Item -Path $wheelTmp -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($w in @($ftWheelHits.Keys | Where-Object { $ftWheelHits[$_] -eq 0 })) { $ftAbiFindings += "$w has no module importing its free-threaded runtime" }
}

Write-Host ''
Write-Host "=== target-arch verification ($targetArch / $expectedName) ==="
Write-Host ("  roots      : {0}" -f ($Path -join ', '))
Write-Host ("  inspected  : {0}" -f $inspected)
Write-Host ("  violations : {0}" -f $violations.Count)
if ($ImportWalk) {
    Write-Host ("  import walk: {0} file(s) walked, {1} unresolved import(s), {2} allowlisted external(s), {3} device-OS (client SKU) import(s)" -f $importWalked, $importUnresolved.Count, $importExternal.Count, $importClientOs.Count)
    foreach ($e in ($importExternal | Select-Object -First 20)) { Write-Host "    external (driver/toolkit): $e" }
    foreach ($e in ($importClientOs | Select-Object -First 20)) { Write-Host "    device OS (client SKU, not on this Server Core reference): $e" }
    if ($importUnresolved.Count -gt 0) {
        # By name first: hundreds of edges are usually a few DLLs, and the name says whether the gap is real.
        $byName = $importUnresolved | Group-Object { $_.Import.ToLowerInvariant() } | Sort-Object Count -Descending
        $heading = if ($standsAlone) { '  UNRESOLVED IMPORTS (the device loader could not satisfy these):' } else { '  unresolved against the roots + System32 (native lane: the image PATH resolves these -- informational):' }
        Write-Host $heading -ForegroundColor $(if ($standsAlone) { 'Red' } else { 'Yellow' })
        foreach ($g in $byName) { Write-Host ("    {0,5}x  {1}" -f $g.Count, $g.Name) }
        foreach ($u in ($importUnresolved | Select-Object -First 40)) {
            $why = if ($u.Crt) { ' [CRT: must ship inside the bundle on a cross lane -- a clean device has no redist]' } else { '' }
            Write-Host ("    - {0}  imports  {1}{2}" -f $u.File, $u.Import, $why)
        }
        if ($importUnresolved.Count -gt 40) { Write-Host ("    ... {0} more edge(s), all in the by-name summary above" -f ($importUnresolved.Count - 40)) }
    }
    Write-Host ("  cp3XYt wheels: {0} wheel(s), {1} module(s) import their free-threaded runtime, {2} finding(s)" -f $ftWheelHits.Count, (@($ftWheelHits.Values) | Measure-Object -Sum).Sum, $ftAbiFindings.Count)
    foreach ($e in $ftAbiFindings) { Write-Host "    FREE-THREADED ABI: $e" -ForegroundColor Red }
}

if ($skippedHostTools.Count -gt 0) {
    # Printed: an over-broad allowlist is only noticed by what it swallowed.
    Write-Host ("  host-tool allowlist skipped {0} file(s) (pattern: {1}):" -f $skippedHostTools.Count, $HostToolPattern)
    $skippedHostTools | ForEach-Object { Write-Host "    - $_" }
}
if ($unreadable.Count -gt 0) {
    Write-Host ("  not PE/COFF, ignored: {0} file(s)" -f $unreadable.Count)
    $unreadable | Select-Object -First 20 | ForEach-Object { Write-Host "    ? $_" }
}

$failed = $false

if ($ImportWalk -and $importUnresolved.Count -gt 0) {
    if ($standsAlone) {
        throw "target-arch verification FAILED for $targetArch`: $($importUnresolved.Count) unresolved import(s) across $importWalked walked file(s) -- see the list above (#127)"
    }
    # The native lane ships the image, whose PATH supplies these; the walk gates only where the bundle stands alone.
    Write-Host ("  import walk: {0} edge(s) unresolved against the roots on the native lane -- informational, the image PATH supplies them (hard gate on cross lanes only)" -f $importUnresolved.Count) -ForegroundColor Yellow
}
# Every lane: a GIL module in a cp3XYt wheel installs fine and fails or re-enables the GIL on import.
if ($ImportWalk -and $ftAbiFindings.Count -gt 0) {
    throw "target-arch verification FAILED for $targetArch`: $($ftAbiFindings.Count) free-threaded wheel finding(s) -- see the FREE-THREADED ABI lines above"
}
if ($ImportWalk -and $MinInspected -gt 0 -and $importWalked -lt $MinInspected) {
    throw "target-arch verification FAILED: the import walk covered only $importWalked file(s), below the -MinInspected floor of $MinInspected"
}
if ($violations.Count -gt 0) {
    Write-Host ''
    Write-Host 'ARCHITECTURE VIOLATIONS:' -ForegroundColor Red
    foreach ($v in $violations) {
        Write-Host ("  {0}  is {1}, expected {2}" -f $v.Path, (Format-Machine $v.Machine), (Format-Machine $expected)) -ForegroundColor Red
    }
    $failed = $true
}

# [int]$null is 0, so an ARCH_GATE_MIN_INSPECTED build-arg that stops reaching the RUN must fail here, not disable the floor.
if ($MinInspected -le 0 -and -not $AllowEmptyTree) {
    throw ("verify-target-arch: -MinInspected resolved to $MinInspected, which disables the coverage floor " +
           'entirely. That is almost never intended -- it usually means the ARCH_GATE_MIN_INSPECTED build-arg ' +
           'did not reach the RUN environment. Pass -AllowEmptyTree to accept a deliberately tiny tree.')
}
if ($MinInspected -gt 0 -and $inspected -lt $MinInspected) {
    # A clean result over an empty tree is indistinguishable from a broken scan.
    Write-Host ''
    Write-Host ("INSUFFICIENT COVERAGE: inspected {0} binaries, expected at least {1}." -f $inspected, $MinInspected) -ForegroundColor Red
    Write-Host '  A pass over an empty or mis-pathed tree is not evidence of anything.' -ForegroundColor Red
    $failed = $true
}

if ($failed) {
    throw "target-arch verification FAILED for $targetArch ($($violations.Count) violation(s), $inspected inspected)"
}

Write-Host ''
Write-Host "TARGET ARCH VERIFICATION PASSED for $targetArch ($inspected binaries)" -ForegroundColor Green
