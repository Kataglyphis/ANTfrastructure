# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Names the OTHER holder of the event LSM waits on during the container boot
    hang. name-lsm-wait-object.ps1 showed the event is unsignalled with
    HandleCount 2; this resolves who owns the second handle.

.DESCRIPTION
    Attaches non-invasively to the silo's LSM svchost to read the waited handle
    off the stack, then enumerates every handle on the system via
    NtQuerySystemInformation(SystemExtendedHandleInformation) and matches on the
    kernel object pointer. Whoever else holds that pointer is the component
    expected to signal the event.

    Run ELEVATED while container starts are happening (a build or probe loop).
    Findings go to out/lsm-attach/, readable by the caller.

.EXAMPLE
    pwsh -File windows\scripts\diagnostics\find-lsm-event-holder.ps1
.EXAMPLE
    pwsh -File windows\scripts\diagnostics\find-lsm-event-holder.ps1 -Handle 0x338 -LsmPid 37236
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [int]$WaitForSiloSec = 900,
    # Skip discovery and inspect a known process/handle pair.
    [int]$LsmPid = 0,
    [uint32]$Handle = 0,
    # Start the container to inspect instead of waiting for someone else's:
    # coordinating an elevated watcher with an external build is what made the
    # first three attempts miss the hang window entirely.
    [switch]$NoBait
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutDir) {
    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $OutDir = Join-Path $repoRoot 'out\lsm-attach'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class HandleScan {
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [StructLayout(LayoutKind.Sequential)]
    struct Entry {
        public IntPtr Object; public IntPtr Pid; public IntPtr Handle;
        public uint GrantedAccess; public ushort CreatorBackTraceIndex;
        public ushort ObjectTypeIndex; public uint HandleAttributes; public uint Reserved;
    }
    // ProcessId, HandleValue, Object -- one row per handle on the system.
    public static List<Tuple<long,long,long>> All() {
        int cls = 64, len = 1 << 22, ret = 0, st;
        IntPtr buf = IntPtr.Zero;
        try {
            while (true) {
                buf = Marshal.AllocHGlobal(len);
                st = NtQuerySystemInformation(cls, buf, len, out ret);
                if (st == unchecked((int)0xC0000004)) {           // INFO_LENGTH_MISMATCH
                    Marshal.FreeHGlobal(buf); buf = IntPtr.Zero; len *= 2; continue;
                }
                if (st != 0) throw new Exception("NtQuerySystemInformation 0x" + st.ToString("X8"));
                break;
            }
            long count = Marshal.ReadIntPtr(buf).ToInt64();
            int stride = Marshal.SizeOf(typeof(Entry));
            IntPtr p = IntPtr.Add(buf, IntPtr.Size * 2);
            var rows = new List<Tuple<long,long,long>>();
            for (long i = 0; i < count; i++) {
                Entry e = (Entry)Marshal.PtrToStructure(IntPtr.Add(p, (int)(i * stride)), typeof(Entry));
                rows.Add(Tuple.Create(e.Pid.ToInt64(), e.Handle.ToInt64(), e.Object.ToInt64()));
            }
            return rows;
        } finally { if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf); }
    }
}
'@

function Get-ProcLabel([long]$procId) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
    if (-not $p) { return "pid $procId (gone)" }
    $ppid = $p.ParentProcessId
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue
    $pn = if ($parent) { $parent.Name } else { '?' }
    return "pid $procId  $($p.Name)  (parent $ppid $pn)"
}

# --- 1. locate the hung LSM svchost and the handle it waits on --------------
if (-not $LsmPid -or -not $Handle) {
    $cdb = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter cdb.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -like '*Microsoft.WinDbg*amd64*' } | Select-Object -First 1
    if (-not $cdb) { throw 'cdb.exe not found - winget install Microsoft.WinDbg' }

    $baseWininit = @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)

    if (-not $NoBait) {
        $buildctl = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
        if (-not (Test-Path $buildctl)) { throw "buildctl not found at $buildctl (use -NoBait and start a container yourself)" }
        $nonce = Get-Date -Format 'yyyyMMddHHmmss'
        $baitDir = Join-Path $env:TEMP "lsm-bait-$nonce"
        New-Item -ItemType Directory -Force -Path $baitDir | Out-Null
        # NONCE in the RUN keeps every launch a cache MISS - a cached solve
        # starts no container and there would be nothing to attach to.
        @'
ARG BASE
FROM ${BASE}
ARG NONCE
RUN echo bait-$NONCE > C:bait.txt
'@ | Set-Content (Join-Path $baitDir 'Dockerfile') -Encoding ascii
        $bait = Start-Process -FilePath $buildctl -PassThru -WindowStyle Hidden -ArgumentList @(
            '--addr', 'npipe:////./pipe/buildkitd', 'build', '--frontend', 'dockerfile.v0'
            '--local', "context=$baitDir", '--local', "dockerfile=$baitDir"
            '--opt', 'build-arg:BASE=mcr.microsoft.com/windows/servercore:ltsc2025'
            '--opt', "build-arg:NONCE=$nonce"
            '--opt', 'image-resolve-mode=local'
            '--output', "type=image,name=docker.io/local/kataglyphis:diag-lsmbait-$nonce"
        )
        Write-Host "bait solve started (buildctl pid $($bait.Id)); its container is the one we inspect"
    }

    Write-Host "Waiting for a NEW silo (max $WaitForSiloSec s)..."
    $deadline = (Get-Date).AddSeconds($WaitForSiloSec)
    $newWininit = $null
    while ((Get-Date) -lt $deadline) {
        $newWininit = Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" |
            Where-Object { $_.ProcessId -notin $baseWininit } | Select-Object -First 1
        if ($newWininit) { break }
        Start-Sleep -Seconds 3
    }
    if (-not $newWininit) { throw 'No new silo appeared - start a build/probe and retry.' }

    $siloServices = $null
    foreach ($i in 1..20) {
        $siloServices = Get-CimInstance Win32_Process -Filter "Name='services.exe' AND ParentProcessId=$($newWininit.ProcessId)" | Select-Object -First 1
        if ($siloServices) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $siloServices) { throw 'silo has no services.exe yet' }

    $svchosts = @()
    foreach ($i in 1..20) {
        $svchosts = @(Get-CimInstance Win32_Process -Filter "Name='svchost.exe' AND ParentProcessId=$($siloServices.ProcessId)" | Sort-Object CreationDate)
        if ($svchosts.Count -ge 1) { break }
        Start-Sleep -Seconds 2
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sym = "srv*$OutDir\sym*https://msdl.microsoft.com/download/symbols"
    foreach ($p in $svchosts) {
        $log = Join-Path $OutDir "holder-probe-$($p.ProcessId)-$stamp.txt"
        & $cdb.FullName -pv -p $p.ProcessId -y $sym -c '.reload /f; ~*kb; qd' > $log 2>&1
        $line = Select-String -Path $log -Pattern 'KERNELBASE!WaitForSingleObjectEx' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ((Select-String -Path $log -Pattern 'lsm!CService::Start' -Quiet -ErrorAction SilentlyContinue) -and $line) {
            $LsmPid = $p.ProcessId
            # kb prints "ret : arg1 arg2 arg3 arg4 : Call Site"; the handle rides
            # in the last argument column as a small backtick-split hex value.
            $args4 = ($line.Line -split ':')[1].Trim() -split '\s+'
            $raw = ($args4[-1] -replace '`', '')
            $Handle = [Convert]::ToUInt32($raw, 16)
            Write-Host "LSM host: pid $LsmPid, waited handle 0x$($Handle.ToString('x'))" -ForegroundColor Green
            break
        }
    }
    if (-not $LsmPid) { throw 'No svchost showed lsm!CService::Start - hang window missed, retry on the next container.' }
}

# --- 2. resolve the kernel object and every holder of it -------------------
Write-Host "Enumerating system handles..."
$rows = [HandleScan]::All()
Write-Host "  $($rows.Count) handles system-wide"

# Windows redacts kernel pointers for non-elevated callers: the call still
# succeeds and PIDs/handles are correct, only Object comes back 0 — which would
# match every row against every other. Refuse rather than report nonsense.
if (-not ($rows | Where-Object { $_.Item3 -ne 0 } | Select-Object -First 1)) {
    throw 'All object pointers are 0 - kernel addresses are redacted here. Re-run elevated.'
}

$mine = $rows | Where-Object { $_.Item1 -eq $LsmPid -and $_.Item2 -eq $Handle } | Select-Object -First 1
if (-not $mine) { throw "handle 0x$($Handle.ToString('x')) not found in pid $LsmPid (did the container tear down?)" }
$obj = $mine.Item3
Write-Host ("object: 0x{0:x}" -f $obj) -ForegroundColor Cyan

# @() matters: a single match is a bare Tuple, which has no .Count, and
# StrictMode turns that into "property Count cannot be found".
$holders = @($rows | Where-Object { $_.Item3 -eq $obj })
$report = Join-Path $OutDir "event-holders-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$lines = @(
    "LSM waited handle : pid $LsmPid handle 0x$($Handle.ToString('x'))"
    ("kernel object     : 0x{0:x}" -f $obj)
    "holders           : $($holders.Count)"
    ''
)
foreach ($h in $holders) {
    $tag = if ($h.Item1 -eq $LsmPid) { '  <-- LSM (the waiter)' } else { '  <-- THE OTHER HOLDER' }
    $lines += ("  handle 0x{0:x}  {1}{2}" -f $h.Item2, (Get-ProcLabel $h.Item1), $tag)
}
$lines | Tee-Object -FilePath $report
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $OutDir /grant "${me}:(OI)(CI)R" /T | Out-Null
Write-Host "`nSaved: $report" -ForegroundColor Green
