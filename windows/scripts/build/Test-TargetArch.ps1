#requires -Version 7.0

# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Asserts every shipped binary in a tree was built for the expected target
    architecture.
.DESCRIPTION
    The Windows arm64 lane is a CROSS build: an x64 container emitting aarch64
    binaries. Nothing it produces can be EXECUTED on the build host, so the
    usual "run it and see" smokes are unavailable and this static check is the
    primary in-lane correctness signal.

    The failure it exists to catch is x64 leakage: a host tool (in-tree protoc,
    flatc, a CMake code generator) or a prebuilt vendor DLL landing in the
    install prefix alongside genuinely cross-built output. That produces a
    bundle that looks complete, passes every presence check, and dies on first
    load on real hardware.

    This is the Windows twin of the Linux lane's ELF-machine check in
    validate-media-runtime.sh, including its escape-hatch convention.

    THREE deliberate design points, each learned from a gate that could not fail:

      1. A MINIMUM inspected count (-MinInspected). A tree that staged nothing,
         or a path typo, otherwise passes green with zero files checked - the
         exact failure mode Dockerfile.smoke-gate's MIN_PASSED floor exists for.
      2. COFF archives (.lib) are NOT PE files. A naive bytes[0x3C] walk over an
         archive reads whatever happens to sit at that offset and may compare
         equal by accident. Archives are decoded from their first member header
         instead.
      3. The host-tool allowlist is EXPLICIT and reported. Anything skipped is
         printed, so "we allowlisted the whole tree" cannot happen quietly.
.PARAMETER Path
    One or more roots to scan. Defaults to C:\runtime.
.PARAMETER Arch
    Expected target architecture. Defaults to the resolved WINDOWS_TARGET_ARCH.
.PARAMETER MinInspected
    Minimum number of binaries that must be inspected for the run to count as
    meaningful. 0 disables the floor (only for a deliberately tiny tree).
.PARAMETER HostToolPattern
    Regex of paths that are permitted to remain host-architecture (build-time
    tools that never ship to the target). Matched against the full path.
.PARAMETER IncludeArchives
    Also verify .lib archives. Off by default: import libraries for a target are
    unambiguous, but static archives pulled from vendor SDKs are a common source
    of noise. Turn on for a strict release gate.
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
    # #127 (2026-08-25): after the machine check, walk every inspected PE's
    # import table (plus the native members of every wheel under the roots)
    # and resolve each imported DLL name against (a) the bundle itself, (b) the
    # loader's virtual API sets (api-ms-*/ext-ms-*), (c) the OS DLL name list of
    # this container's System32. On a CROSS lane the CRT family
    # (vcruntime/msvcp/concrt/...) is NOT accepted from System32: a clean device
    # has no redist, so the bundle must carry it. An unresolved import is the
    # 0xC0000135-at-first-touch class the machine check cannot see (#124).
    [switch]$ImportWalk,
    # Regex of import names that are legitimately external to both bundle and
    # OS (driver/toolkit-provided). Reported, never counted.
    [string]$ImportAllowlist = '^(nvcuda|nvml|nvapi64|cudart64_[0-9]+|cublas|cublasLt|cudnn|nvinfer|nvonnxparser|nvrtc|cufft|curand|cusparse|cusolver|nvjitlink|nvcomp|vulkan-1|opengl32|d3d12core|QnnHtp|QnnCpu|QnnSystem)[A-Za-z0-9_-]*\.dll$',
    # Regex of OS DLLs that a Windows CLIENT SKU ships but this Server Core
    # reference container does not, so they never appear in (c) above yet are
    # on every device the bundle targets. Measured arm64 run 13 (2026-08-25),
    # each name a real import of a shipped plugin: DirectSound (gstdirectsound*),
    # Media Foundation (gstmediafoundation -- MF is absent on Server Core, the
    # same fact behind OpenCV's WITH_MSMF=OFF), and the print spooler
    # (tcl9tk90.dll -> winspool.drv). libcdsprpc/libadsprpc are Qualcomm's
    # FastRPC drivers (ADSP/CDSP), imported by the QAIRT HTP stub DLLs and
    # present on every Windows-on-Snapdragon device -- the exact target of the
    # arm64 lane (found 2026-08-31 once the QNN EP landed in the bundle).
    # Reported as "device OS", never counted.
    # Keep it to names the client SKU carries unconditionally -- an optional
    # feature (e.g. a Media Feature Pack SKU) would belong in -ImportAllowlist.
    [string]$ClientOsPattern = '^(dsound|mf|mfplat|mfreadwrite|mfcore|winspool)\.(dll|drv)$|^lib(cds|ads)prpc\.dll$',
    # Opt-in for a tree that legitimately holds (almost) no binaries. Required
    # whenever -MinInspected is 0 or less, so that "no coverage floor" can only
    # ever be a deliberate statement rather than a dropped build-arg.
    [switch]$AllowEmptyTree
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets live beside this script in the flat
# layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$archModulePath = Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1'
if (-not (Test-Path $archModulePath)) { throw "Required module not found: $archModulePath" }
Import-Module $archModulePath -Force

$targetArch = Get-WindowsTargetArch -Arch $Arch
$expected = Get-PeMachineType -Arch $targetArch
$expectedName = (Get-WindowsTargetArchInfo -Arch $targetArch).PeMachineName

# Known COFF machine types, for a diagnostic that names what was actually found
# instead of printing a bare hex number.
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

# Machine types that legitimately satisfy a given target. ARM64EC and ARM64X are
# part of the ARM64 family and DO appear in Microsoft's own SDK: on a stock
# Windows Kit, ucrt\arm64\ucrt.osmode_permissive.lib reports 0xA641 while its
# siblings report 0xAA64. Comparing against 0xAA64 alone rejects a perfectly
# good Microsoft library and prints "UNRECOGNIZED", which names nothing and
# sends the reader hunting a non-existent build defect.
$acceptedMachines = @{
    0x8664 = @(0x8664)
    0xAA64 = @(0xAA64, 0xA641, 0xA64E)
}
function Format-Machine {
    param([int]$Value)
    $name = if ($machineNames.ContainsKey($Value)) { $machineNames[$Value] } else { 'UNRECOGNIZED' }
    return ('0x{0:X4} ({1})' -f $Value, $name)
}

<#
Reads the COFF machine type from a PE image (.exe/.dll) or a COFF object (.obj).
Returns $null when the file is not a recognizable PE/COFF image, so callers can
report "unreadable" separately from "wrong architecture" - conflating the two
sent past investigations chasing the wrong problem.
#>
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
            # PE image: e_lfanew at 0x3C points at the "PE\0\0" signature, and the
            # COFF header (whose first field is Machine) follows it.
            if ($fs.Length -lt 0x40) { return $null }
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            if ($peOffset -le 0 -or ($peOffset + 6) -ge $fs.Length) { return $null }
            $fs.Position = $peOffset
            $sig = $br.ReadBytes(4)
            if ($sig[0] -ne 0x50 -or $sig[1] -ne 0x45 -or $sig[2] -ne 0 -or $sig[3] -ne 0) { return $null }
            return [int]$br.ReadUInt16()
        }

        # Unlinked COFF object: the IMAGE_FILE_HEADER starts at byte 0, so the
        # first two bytes ARE the Machine field.
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

<#
Reads the machine type of a COFF archive (.lib) from its first real member.
An archive is NOT a PE file: it starts with the "!<arch>\n" magic followed by
60-byte member headers. Import libraries additionally carry a short-import
header whose Machine field sits at offset 4 of the member payload.
#>
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

    # The whole member walk is guarded: a malformed or truncated archive must
    # yield $null ("unreadable"), never an IndexOutOfRangeException. An escaping
    # exception would abort the entire scan without naming the offending file -
    # breaking the contract the caller relies on to separate "unreadable" from
    # "wrong architecture".
    try {
        $pos = 8
        while (($pos + 60) -le $bytes.Length) {
            $sizeText = [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 48, 10).Trim()
            [int]$size = 0
            if (-not [int]::TryParse($sizeText, [ref]$size)) { return $null }
            if ($size -lt 0) { return $null }
            $name = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 16).Trim()
            $dataStart = $pos + 60

            # Skip the linker members ("/", "//") and the ARM64EC symbol member.
            # A short-import header is 20 bytes and its Machine field sits at
            # offset 6..7, so the guard must cover $dataStart+7 - the previous
            # +6 bound was two bytes short and threw on a small final member.
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

# .pyd is a DLL with a different suffix and IS staged into the scanned tree
# (build-onnx-genai copies *.pyd into C:\runtime\lib\...; opencv5 ships them
# too). Omitting it meant native Python extensions were skipped SILENTLY and,
# because they never incremented the inspected count, -MinInspected could not
# notice either - a hole in the default mode with no flag to reveal it.
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
            $file = $_
            if ($HostToolPattern -and $file.FullName -match $HostToolPattern) {
                $skippedHostTools += $file.FullName
                return
            }
            $machine = if ($file.Extension -ieq '.lib') {
                Get-ArchiveMachine -LiteralPath $file.FullName
            } else {
                Get-CoffMachine -LiteralPath $file.FullName
            }
            if ($null -eq $machine) {
                $unreadable += $file.FullName
                return
            }
            $inspected++
            $ok = if ($acceptedMachines.ContainsKey($expected)) { $acceptedMachines[$expected] -contains $machine } else { $machine -eq $expected }
            if (-not $ok) {
                $violations += [pscustomobject]@{ Path = $file.FullName; Machine = $machine }
            }
            if ($file.Extension -ine '.lib') { $script:peFiles += $file.FullName }
        }
}

# ── #127: static import walk ─────────────────────────────────────────────────
$importUnresolved = @()
$importWalked = 0
$importExternal = @()
$importClientOs = @()
if ($ImportWalk) {
    $walkFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $script:peFiles) { $walkFiles.Add($f) }
    # Wheels: their native members are what `pip install` puts into the device's
    # site-packages; walk them exactly like shipped files.
    $wheelTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('archgate-wheels-' + [guid]::NewGuid().ToString('N'))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($root in $Path) {
        foreach ($whl in @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.whl' -File -ErrorAction SilentlyContinue)) {
            $dest = Join-Path $wheelTmp ([IO.Path]::GetFileNameWithoutExtension($whl.Name))
            [System.IO.Compression.ZipFile]::ExtractToDirectory($whl.FullName, $dest)
            foreach ($m in @(Get-ChildItem -Path $dest -Recurse -File -Include '*.dll', '*.pyd', '*.exe')) { $walkFiles.Add($m.FullName) }
        }
    }
    # Name universes. Bundle = every DLL/PYD/EXE file name under the roots and
    # inside the wheels (consumers register the bundle's DLL homes; the device's
    # loader only needs the NAME to exist somewhere it is told to look).
    $bundleNames = @{}
    foreach ($f in $walkFiles) { $bundleNames[([IO.Path]::GetFileName($f)).ToLowerInvariant()] = $true }
    $systemNames = @{}
    foreach ($d in @(Get-ChildItem -Path (Join-Path $env:SystemRoot 'System32') -Filter '*.dll' -File -ErrorAction SilentlyContinue)) { $systemNames[$d.Name.ToLowerInvariant()] = $true }
    $crossLane = Test-WindowsCrossTarget -Arch $targetArch
    $crtPattern = '^(vcruntime|msvcp|concrt|vcomp|vccorlib|vcamp|msvcr|mfc)[0-9]'
    foreach ($f in $walkFiles) {
        $imports = try { Get-PeImportNames -Path $f -IncludeDelayLoad } catch { $unreadable += $f; continue }
        $importWalked++
        foreach ($imp in $imports) {
            $n = $imp.ToLowerInvariant()
            if ($n -match '^(api|ext)-ms-') { continue }
            if ($bundleNames.ContainsKey($n)) { continue }
            if ($ImportAllowlist -and $imp -match $ImportAllowlist) { $importExternal += "$f -> $imp"; continue }
            $isCrt = ($n -match $crtPattern)
            if ($systemNames.ContainsKey($n) -and -not ($crossLane -and $isCrt)) { continue }
            if ($ClientOsPattern -and $n -match $ClientOsPattern) { $importClientOs += "$f -> $imp"; continue }
            $importUnresolved += [pscustomobject]@{ File = $f; Import = $imp; Crt = $isCrt }
        }
    }
    Remove-Item -Path $wheelTmp -Recurse -Force -ErrorAction SilentlyContinue
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
        # By NAME first: 200 edges are usually three DLLs, and the name says
        # whether the gap is real (measured amd64 run 4, 2026-08-25: 186x
        # python314.dll + 8x python3.dll -- the HOST interpreter lives outside
        # the roots on the native lane -- and 6x scoop's libcrypto/libssl-4-x64).
        $byName = $importUnresolved | Group-Object { $_.Import.ToLowerInvariant() } | Sort-Object Count -Descending
        $heading = if ($crossLane) { '  UNRESOLVED IMPORTS (the device loader could not satisfy these):' } else { '  unresolved against the roots + System32 (native lane: the image PATH resolves these -- informational):' }
        Write-Host $heading -ForegroundColor $(if ($crossLane) { 'Red' } else { 'Yellow' })
        foreach ($g in $byName) { Write-Host ("    {0,5}x  {1}" -f $g.Count, $g.Name) }
        foreach ($u in ($importUnresolved | Select-Object -First 40)) {
            $why = if ($u.Crt) { ' [CRT: must ship inside the bundle on a cross lane -- a clean device has no redist]' } else { '' }
            Write-Host ("    - {0}  imports  {1}{2}" -f $u.File, $u.Import, $why)
        }
        if ($importUnresolved.Count -gt 40) { Write-Host ("    ... {0} more edge(s), all in the by-name summary above" -f ($importUnresolved.Count - 40)) }
    }
}

if ($skippedHostTools.Count -gt 0) {
    # Printed, never silent: an over-broad allowlist is itself a defect, and the
    # only way to notice is to see what it swallowed.
    Write-Host ("  host-tool allowlist skipped {0} file(s) (pattern: {1}):" -f $skippedHostTools.Count, $HostToolPattern)
    $skippedHostTools | ForEach-Object { Write-Host "    - $_" }
}
if ($unreadable.Count -gt 0) {
    Write-Host ("  not PE/COFF, ignored: {0} file(s)" -f $unreadable.Count)
    $unreadable | Select-Object -First 20 | ForEach-Object { Write-Host "    ? $_" }
}

$failed = $false

if ($ImportWalk -and $importUnresolved.Count -gt 0) {
    if ($crossLane) {
        throw "target-arch verification FAILED for $targetArch`: $($importUnresolved.Count) unresolved import(s) across $importWalked walked file(s) -- see the list above (#127)"
    }
    # Native lane: the deliverable is the IMAGE, whose PATH carries the host
    # CPython, scoop's OpenSSL and the toolkits, so "not under the roots" is not
    # "not loadable". The walk stays informational here; it is a hard gate only
    # where the bundle must stand alone (measured amd64 run 4, 2026-08-25).
    Write-Host ("  import walk: {0} edge(s) unresolved against the roots on the native lane -- informational, the image PATH supplies them (hard gate on cross lanes only)" -f $importUnresolved.Count) -ForegroundColor Yellow
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

# "No floor" must be an explicit CHOICE, never an accident. The caller passes
# -MinInspected ([int]$env:ARCH_GATE_MIN_INSPECTED) from a Dockerfile ARG, and
# [int]$null is 0 -- so the day that ARG stops reaching the RUN environment (a
# renamed build-arg, an undeclared ARG silently dropped by buildctl, a stage that
# forgot to redeclare it across a FROM boundary) this gate would quietly stop
# being a gate and report a clean pass over whatever it happened to find. That is
# the exact "verified nothing, said PASS" shape this script exists to prevent, so
# it fails loudly instead.
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
