# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Names the other holder of the unsignalled event the silo's LSM waits on during the container boot hang.
.DESCRIPTION
    Reads the waited handle off the LSM svchost's stack (non-invasive cdb), then matches its kernel object across all handles.
    Run elevated; findings go to out/lsm-attach/.
.EXAMPLE
    pwsh -File windows\scripts\diagnostics\Find-LsmEventHolder.ps1 -Handle 0x338 -LsmPid 37236
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [int]$WaitForSiloSec = 900,
    # Skip discovery and inspect a known process/handle pair.
    [int]$LsmPid = 0,
    [uint32]$Handle = 0,
    # By default it starts its own container, since a watcher misses an external build's hang window.
    [switch]$NoBait
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only the setup is shared with the other LSM probes; the R10 read and handle scan stay here.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSiloProbe.Common.psm1') -Force -DisableNameChecking

$OutDir = Initialize-LsmProbeOutDir -OutDir $OutDir

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

# 1. Locate the hung LSM svchost and the handle it waits on
if (-not $LsmPid -or -not $Handle) {
    $cdb = Get-CdbPath

    $baseWininit = @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)

    if (-not $NoBait) {
        $bait = Start-SiloBaitContainer -Tag 'lsmbait' -PassThru
        Write-Host "bait solve started (buildctl pid $($bait.Id)); its container is the one we inspect"
    }

    Write-Host "Waiting for a NEW silo (max $WaitForSiloSec s)..."
    $newWininit = Wait-ForNewSilo -BaselinePid $baseWininit -TimeoutSec $WaitForSiloSec -PollSec 3
    if (-not $newWininit) { throw 'No new silo appeared - start a build/probe and retry.' }

    $svchosts = @(Get-SiloSvchost -ServicesParentPid $newWininit.ProcessId)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sym = "srv*$OutDir\sym*https://msdl.microsoft.com/download/symbols"
    foreach ($p in $svchosts) {
        $log = Join-Path $OutDir "holder-probe-$($p.ProcessId)-$stamp.txt"
        # Two passes: .printf swallows the semicolons after it, so a combined command prints no stack.
        & $cdb -pv -p $p.ProcessId -y $sym -c '.reload /f; ~*kb; qd' > $log 2>&1
        if (-not (Select-String -Path $log -Pattern 'lsm!CService::Start' -Quiet -ErrorAction SilentlyContinue)) { continue }

        # Bind the frame to its thread: the process's first wait is the SCM dispatcher's idle loop.
        $idx = $null; $cur = $null
        foreach ($ln in (Get-Content $log)) {
            if ($ln -match '^[.#]?\s*(\d+)\s+Id:\s') { $cur = $Matches[1]; continue }
            if ($ln -match 'lsm!CService::Start' -and $null -ne $cur) { $idx = $cur; break }
        }
        if ($null -eq $idx) { Write-Warning "pid $($p.ProcessId) shows LSM but no thread could be bound to it"; continue }

        # The syscall stub does mov r10,rcx, so R10 holds the handle; kb's args-to-child columns are unreliable.
        $rlog = Join-Path $OutDir "holder-r10-$($p.ProcessId)-$stamp.txt"
        & $cdb -pv -p $p.ProcessId -y $sym -c ".reload /f; ~$($idx)s; r r10; qd" > $rlog 2>&1
        $rm = Select-String -Path $rlog -Pattern 'r10=([0-9a-f`]+)' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $rm) { Write-Warning "pid $($p.ProcessId): thread $idx is LSM but R10 was unreadable (see $rlog)"; continue }
        $Handle = [uint32][Convert]::ToUInt64(($rm.Matches[0].Groups[1].Value -replace '`', ''), 16)
        $LsmPid = $p.ProcessId
        Write-Host "LSM host: pid $LsmPid, thread $idx, waited handle 0x$($Handle.ToString('x')) (R10)" -ForegroundColor Green
        break
    }
    if (-not $LsmPid) { throw 'No svchost showed lsm!CService::Start - hang window missed, retry on the next container.' }
}

# 2. Resolve the kernel object and every holder of it
Write-Host "Enumerating system handles..."
$rows = [HandleScan]::All()
Write-Host "  $($rows.Count) handles system-wide"

# Non-elevated callers get zeroed object pointers, which would match every row.
if (-not ($rows | Where-Object { $_.Item3 -ne 0 } | Select-Object -First 1)) {
    throw 'All object pointers are 0 - kernel addresses are redacted here. Re-run elevated.'
}

$mine = $rows | Where-Object { $_.Item1 -eq $LsmPid -and $_.Item2 -eq $Handle } | Select-Object -First 1
if (-not $mine) { throw "handle 0x$($Handle.ToString('x')) not found in pid $LsmPid (did the container tear down?)" }
$obj = $mine.Item3
Write-Host ("object: 0x{0:x}" -f $obj) -ForegroundColor Cyan

# @(): a single match is a bare Tuple, which has no .Count under StrictMode.
$holders = @($rows | Where-Object { $_.Item3 -eq $obj })

# HandleCount from the same run as the holder list, so both describe one container.
$detail = ''
if ($cdb -and (Get-Process -Id $LsmPid -ErrorAction SilentlyContinue)) {
    $hlog = Join-Path $OutDir "handle-detail-$LsmPid-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    & $cdb -pv -p $LsmPid -y $sym -c ".reload /f; !handle $($Handle.ToString('x')) f; qd" > $hlog 2>&1
    $detail = (Get-Content $hlog | Select-String -Pattern 'HandleCount|PointerCount|Event Type|Event is|Type ' | ForEach-Object { '    ' + $_.Line.Trim() }) -join "`n"
}
$report = Join-Path $OutDir "event-holders-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$lines = @(
    "LSM waited handle : pid $LsmPid handle 0x$($Handle.ToString('x'))"
    ("kernel object     : 0x{0:x}" -f $obj)
    "holders           : $($holders.Count)"
    ''
)
if ($detail) { $lines += @('object detail (same run):', $detail, '') }
foreach ($h in $holders) {
    $tag = if ($h.Item1 -eq $LsmPid) { '  <-- LSM (the waiter)' } else { '  <-- THE OTHER HOLDER' }
    $lines += ("  handle 0x{0:x}  {1}{2}" -f $h.Item2, (Get-ProcLabel $h.Item1), $tag)
}
$lines | Tee-Object -FilePath $report
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $OutDir /grant "${me}:(OI)(CI)R" /T | Out-Null
Write-Host "`nSaved: $report" -ForegroundColor Green
