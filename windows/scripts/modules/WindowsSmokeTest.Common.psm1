#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Assertion harness for smoke-test-container.ps1.
#
# Extracted 2026-08-08. The script had grown past 1 570 lines, of which ~210
# were this harness and the rest 22 test SECTIONS. Only the harness is reusable
# and unit-testable; the sections stay in the script, because they are a linear
# script of probes against a built image and gain nothing from being modules.
#
# Ships in the final image without any Dockerfile change: windows/Dockerfile
# already COPYs the whole windows\scripts\modules directory to
# C:\temp\scripts\modules, and that COPY sits in the final (cheapest) layer.
#
# ONE behavioural subtlety made this an extraction rather than a cut-and-paste:
# Assert-Test used to read $ExitOnFirstFailure, a PARAMETER of the calling
# script, through PowerShell's dynamic scoping. A module has its own session
# state and would never see it -- Assert-Test would have silently stopped
# honouring -ExitOnFirstFailure, with no error anywhere. It is module state now,
# set through Initialize-SmokeTestRun, and covered by a regression test.
#
# The counters live here too, so the caller reads them via Get-SmokeTestSummary
# rather than touching $script:passed across a module boundary (which would
# resolve to the CALLER's scope and always read zero).

Set-StrictMode -Version Latest

# -ExitOnFirstFailure state, owned by the module (see the header).
$script:exitOnFirstFailure = $false

function Initialize-SmokeTestRun {
    <#
    .SYNOPSIS
        Reset counters and record run-level switches. Call once, before the
        first assertion.
    #>
    param([switch]$ExitOnFirstFailure)
    $script:passed = 0
    $script:failed = 0
    $script:skipped = 0
    $script:failureDetails = @()
    $script:abortRun = $false
    $script:exitOnFirstFailure = [bool]$ExitOnFirstFailure
    $script:sectionCounts = [ordered]@{}
    $script:currentSection = ''
    $script:sectionStartPassed = 0
}

function Get-SmokeTestSummary {
    <#
    .SYNOPSIS
        Counters for the caller's SUMMARY block. Exists because $script:passed
        read from the calling script would resolve to the CALLER's scope -- a
        different variable that is always zero.
    #>
    [OutputType([pscustomobject])]
    param()
    Complete-SmokeSection
    [pscustomobject]@{
        Passed         = $script:passed
        Failed         = $script:failed
        Skipped        = $script:skipped
        Total          = $script:passed + $script:failed + $script:skipped
        Aborted        = $script:abortRun
        FailureDetails = @($script:failureDetails)
        # Per-section PASSED counts, keyed by the leading number of the
        # Write-TestHeader title (2026-08-21 coverage-floor work: 34 points
        # of anonymous slack against MinPassed meant whole subsystems could
        # vanish green — per-section floors name the hole).
        SectionPassed  = $script:sectionCounts
    }
}

function Complete-SmokeSection {
    # Internal: record the passed-delta of the section in flight.
    if ($script:currentSection) {
        $script:sectionCounts[$script:currentSection] = $script:passed - $script:sectionStartPassed
    }
    $script:currentSection = ''
}

$script:passed = 0
$script:failed = 0
$script:skipped = 0
$script:failureDetails = @()
$script:sectionCounts = [ordered]@{}
$script:currentSection = ''
$script:sectionStartPassed = 0
# -ExitOnFirstFailure no longer throws (a throw here used to blow straight past the
# SUMMARY / FAILURE DETAILS dump at the bottom). Instead the first failure sets this
# flag and every later assert/skip short-circuits, so the run still ends with the
# full summary and a non-zero exit.
$script:abortRun = $false

function Skip-Test {
    # One-liner for the repeated [SKIP]-print + counter idiom (was hand-rolled at 15 sites,
    # where forgetting $script:skipped++ silently under-counted skips).
    param([Parameter(Mandatory)][string]$Reason)
    if ($script:abortRun) { return }
    Write-Host "  [SKIP] $Reason" -ForegroundColor Yellow
    $script:skipped++
}

function Write-TestHeader {
    param([string]$Title)
    Complete-SmokeSection
    # Section key = the leading number of the title ('8. ONNX Runtime' -> '8');
    # a numberless title keys on its full text.
    $script:currentSection = if ($Title -match '^\s*(\d+)') { $Matches[1] } else { $Title }
    $script:sectionStartPassed = $script:passed
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$Condition,
        [string]$FailMessage = 'Assertion failed'
    )

    if ($script:abortRun) { return }
    try {
        $result = & $Condition
        if ($result) {
            Write-Host "  [PASS] $Name" -ForegroundColor Green
            $script:passed++
        } else {
            Write-Host "  [FAIL] $Name : $FailMessage" -ForegroundColor Red
            $script:failed++
            $script:failureDetails += "[FAIL] $Name : $FailMessage"
            if ($script:exitOnFirstFailure) { Request-SmokeAbort }
        }
    } catch {
        Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
        $script:failureDetails += "[FAIL] $Name : $($_.Exception.Message)"
        if ($script:exitOnFirstFailure) { Request-SmokeAbort }
    }
}

function Initialize-SmokeScratch {
    <#
    .SYNOPSIS
        Scrub-then-create for a smoke scratch dir. A previous section's throw
        can leak its scratch (3 of 10 sites had no try/finally, D6), and a
        bare New-Item -Force then hands the NEXT run a dirty tree — stale
        artifacts masquerading as fresh compile outputs. The trailing
        Remove-Item in each section stays best-effort; THIS is the guarantee.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

function Assert-PythonSnippet {
    <#
    .SYNOPSIS
        The one-line python assertion the smoke test repeated 14 times: run
        `python -c $Code`, require exit 0 AND every -ExpectMatch regex in the
        combined output. Sites with setup/teardown around the interpreter
        call (temp model files etc.) stay hand-written with Assert-Test.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string[]]$ExpectMatch,
        [Parameter(Mandatory)][string]$FailMessage
    )
    Assert-Test -Name $Name -FailMessage $FailMessage -Condition {
        $out = & python -c $Code 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return $false }
        foreach ($m in $ExpectMatch) { if ($out -notmatch $m) { return $false } }
        return $true
    }.GetNewClosure()
}

function Request-SmokeAbort {
    Write-Host '  [ABORT] -ExitOnFirstFailure: short-circuiting all remaining tests (summary follows)' -ForegroundColor Red
    $script:abortRun = $true
}

function Assert-CommandExists {
    param([string]$Name)
    # GetNewClosure: the scriptblock is invoked inside Assert-Test, whose own $Name
    # parameter shadows this one under PowerShell's dynamic scoping — without the
    # closure this evaluated Get-Command "Command 'git' on PATH" and always failed.
    $commandName = $Name
    Assert-Test -Name "Command '$Name' on PATH" -Condition { $null -ne (Get-Command $commandName -ErrorAction SilentlyContinue) }.GetNewClosure() -FailMessage "$Name not found on PATH"
}

function Assert-FileExists {
    param([string]$Path, [string]$Description = $Path)
    Assert-Test -Name $Description -Condition { Test-Path $Path -PathType Leaf } -FailMessage "File not found: $Path"
}

function Assert-DirectoryExists {
    param([string]$Path, [string]$Description = $Path)
    Assert-Test -Name $Description -Condition { Test-Path $Path -PathType Container } -FailMessage "Directory not found: $Path"
}

function Assert-ArtifactPresent {
    # Assert >=1 file matching $Filter exists under $Root (optionally a $Subdir),
    # recursively. Collapses the "Get-ChildItem -Recurse then Assert-Test count>0"
    # idiom repeated across the native-library sections (ONNX/GenAI/OpenCV/LiteRT/
    # LiteRT-LM/TVM). With -Informational a miss is a [SKIP] (yellow) not a [FAIL]
    # -- for optional artifacts like LiteRT's DLLs (it builds static by default).
    param(
        [string]$Root,
        [string]$Filter,
        [string]$Description,
        [string]$Subdir = '',
        [switch]$Informational
    )
    $searchRoot = if ($Subdir) { Join-Path $Root $Subdir } else { $Root }
    $count = @(Get-ChildItem -Path $searchRoot -Filter $Filter -Recurse -ErrorAction SilentlyContinue).Count
    if ($Informational) {
        if ($count -gt 0) {
            Write-Host "  [PASS] $Description ($count found)" -ForegroundColor Green
            $script:passed++
        } else {
            Skip-Test "$Description (none found -- optional)"
        }
        return
    }
    # GetNewClosure: $count is function-local, so Assert-Test's scope can't see it
    # via dynamic scoping (unlike the script-scope vars used in inline conditions).
    Assert-Test -Name $Description -Condition { $count -gt 0 }.GetNewClosure() -FailMessage "No file matching '$Filter' found under $searchRoot"
}

function Assert-NativeLinkRun {
    # Compile + link + RUN a tiny C++ TU against a native library to prove its
    # header + import lib + DLL actually work together at runtime. Existence checks
    # are blind to missing dependent DLLs, CRT mismatches, and ABI breaks -- the
    # exact 'links clean but is dead' class the litert_lm abseil-ODR bug taught us.
    # Only meaningful in the final image, where clang-cl and the libs coexist.
    param(
        [string]$Name,
        [string]$WorkName,        # unique temp-dir suffix
        [string]$Source,          # C++ source text
        [string[]]$IncludeDirs,
        [string]$LibDir,
        [string]$LibName,
        [string]$DllDir,          # prepended to PATH so the DLL resolves at run
        [string]$ExpectMatch,     # regex the program's stdout must match
        [string]$FailMessage
    )
    $work = $WorkName; $body = $Source; $incs = $IncludeDirs
    $ldir = $LibDir; $lname = $LibName; $ddir = $DllDir; $expect = $ExpectMatch
    Assert-Test -Name $Name -Condition {
        $d = Join-Path $env:TEMP "kataglyphis-smoke-$work"
        New-Item -Path $d -ItemType Directory -Force | Out-Null
        $src = Join-Path $d 'main.cpp'
        Set-Content -Path $src -Value $body -Encoding ASCII
        $exe = Join-Path $d 'main.exe'
        $clangArgs = @($src, '/std:c++17', '/EHsc', '/nologo')
        foreach ($i in $incs) { $clangArgs += "/I$i" }
        $clangArgs += @("/Fe$exe", '/link', "/LIBPATH:$ldir", $lname)
        & clang-cl @clangArgs 2>&1 | Out-Null
        $ok = $false
        if (($LASTEXITCODE -eq 0) -and (Test-Path $exe)) {
            $prev = $env:PATH
            $env:PATH = "$ddir;$env:PATH"
            try { $out = (& $exe 2>&1 | Out-String); $code = $LASTEXITCODE } finally { $env:PATH = $prev }
            $ok = ($code -eq 0) -and ($out -match $expect)
        }
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        return $ok
    }.GetNewClosure() -FailMessage $FailMessage
}

function Assert-DllLoads {
    # LoadLibrary a native DLL (with its own dir + any dependency dirs on PATH) and optionally
    # GetProcAddress a known export. Proves the DLL AND its full dependent-DLL chain actually
    # resolve at load time -- the header-agnostic complement to Assert-NativeLinkRun, for libs
    # whose headers churn across releases (TVM) or whose C API is awkward to compile (GenAI).
    # A successful LoadLibrary is the real signal (it catches a missing dependent DLL, the same
    # 0xC0000135 class as the OpenCV/OpenGL defect); the export check is a bonus.
    param(
        [string]$Name,
        [string]$DllPath,
        [string[]]$DependencyDirs = @(),
        [string]$Export = '',
        [string]$FailMessage
    )
    $dllPath = $DllPath; $depDirs = $DependencyDirs; $export = $Export
    Assert-Test -Name $Name -Condition {
        if (-not ('KataNativeProbe' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KataNativeProbe {
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibraryW(string p);
    [DllImport("kernel32", SetLastError=true)] public static extern bool FreeLibrary(IntPtr h);
    [DllImport("kernel32", SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
}
'@
        }
        if (-not (Test-Path $dllPath)) { return $false }
        $prev = $env:PATH
        $env:PATH = ((@((Split-Path $dllPath)) + $depDirs) -join ';') + ';' + $env:PATH
        try {
            $h = [KataNativeProbe]::LoadLibraryW($dllPath)
            if ($h -eq [IntPtr]::Zero) { return $false }
            $ok = $true
            if ($export) { $ok = ([KataNativeProbe]::GetProcAddress($h, $export) -ne [IntPtr]::Zero) }
            [void][KataNativeProbe]::FreeLibrary($h)
            return $ok
        } finally { $env:PATH = $prev }
    }.GetNewClosure() -FailMessage $FailMessage
}

function Assert-EnvVarSet {
    param([string]$Name, [string]$ExpectedPrefix = '')
    # GetNewClosure + renamed captures: Assert-Test's $Name parameter shadows this
    # one at invocation time (dynamic scoping), so the env var that was actually
    # queried used to be the test title — always failing.
    $envName = $Name
    $envPrefix = $ExpectedPrefix
    Assert-Test -Name "Env var $Name" -Condition {
        $val = [Environment]::GetEnvironmentVariable($envName)
        if ([string]::IsNullOrWhiteSpace($val)) { return $false }
        if ($envPrefix) { return $val -like "$envPrefix*" }
        return $true
    }.GetNewClosure() -FailMessage "$Name is not set or doesn't match expected prefix"
}

function Assert-AllDllsLoad {
    # Backlog #57: LoadLibrary EVERY shipped DLL under a root, not a hand-picked
    # sample. The named Assert-DllLoads call sites cover ~10 hardcoded libraries;
    # OpenCV alone ships ~25-30 modules with BUILD_opencv_world=OFF, of which
    # exactly ONE (opencv_core) was load-tested — the rest were existence checks.
    #
    # That is the OPENGL32 defect verbatim: OpenCV built with WITH_OPENGL=ON
    # linked fine and failed 0xC0000135 at LOAD on Server Core, and only a load
    # test caught it. Existence proves a file was produced; it says nothing about
    # whether its dependency chain resolves on THIS image.
    #
    # Not every DLL is legitimately loadable standalone (plugins expecting a host
    # to have initialised first, delay-load stubs), so unloadable-by-design names
    # go in -Allow with a reason at the call site — an explicit, reviewable list
    # rather than a silent sample.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root,
        [string[]]$DependencyDirs = @(),
        [string[]]$Allow = @(),
        [int]$MinimumChecked = 1
    )
    # The probing happens HERE, not inside the Assert-Test condition: -FailMessage
    # is a plain string evaluated at CALL time, so a message referring to results
    # computed inside the condition would always be empty. Do the work first,
    # then assert on a value that already exists.
    if (-not ('KataNativeProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KataNativeProbe {
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibraryW(string p);
    [DllImport("kernel32", SetLastError=true)] public static extern bool FreeLibrary(IntPtr h);
}
'@
    }
    $problems = @()
    $checked = 0
    if (-not (Test-Path $Root)) {
        $problems += "root not found: $Root"
    } else {
        $dlls = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.dll' -File -ErrorAction SilentlyContinue)
        # Rot guard: an empty or moved root would otherwise pass vacuously —
        # the exact shape this test exists to eliminate. Counted AFTER the
        # -Allow filter (see below), not on the raw find: a root that is 100 %
        # allow-listed would otherwise satisfy the guard while checking nothing.
        $candidates = @($dlls | Where-Object { $Allow -notcontains $_.Name })
        if ($candidates.Count -lt $MinimumChecked) {
            $problems += "only $($candidates.Count) non-allow-listed DLL(s) under $Root (of $($dlls.Count) found), expected at least $MinimumChecked - wrong root, or over-broad -Allow?"
        } else {
            $prev = $env:PATH
            try {
                foreach ($d in $dlls) {
                    if ($Allow -contains $d.Name) { continue }
                    $checked++
                    # The DLL's OWN directory must lead, per DLL. LoadLibraryW with
                    # a full path does NOT add that directory to the dependency
                    # search order, so a DLL in a SUBdirectory whose dependents sit
                    # beside it would report a fabricated Win32 126. Assert-DllLoads
                    # already does this correctly; putting only $Root on PATH (the
                    # first version here) happened to work for OpenCV's flat bin\
                    # and would have invented failures at the next call site.
                    $env:PATH = ((@((Split-Path $d.FullName)) + @($Root) + $DependencyDirs) -join ';') + ';' + $prev
                    $h = [KataNativeProbe]::LoadLibraryW($d.FullName)
                    if ($h -eq [IntPtr]::Zero) {
                        $problems += ("{0} (Win32 {1})" -f $d.Name, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
                    } else {
                        [void][KataNativeProbe]::FreeLibrary($h)
                    }
                }
            } finally { $env:PATH = $prev }
        }
    }
    $ok = ($problems.Count -eq 0)
    if ($ok) { Write-Host "    ($checked DLLs loaded under $Root)" -ForegroundColor DarkGray }
    Assert-Test -Name $Name -Condition { $ok }.GetNewClosure() `
        -FailMessage ("DLL load failures under {0}: {1}" -f $Root, (($problems | Select-Object -First 12) -join '; '))
}

Export-ModuleMember -Function @(
    'Assert-AllDllsLoad'
    'Initialize-SmokeTestRun'
    'Get-SmokeTestSummary'
    'Skip-Test'
    'Write-TestHeader'
    'Assert-Test'
    'Assert-PythonSnippet'
    'Initialize-SmokeScratch'
    'Request-SmokeAbort'
    'Assert-CommandExists'
    'Assert-FileExists'
    'Assert-DirectoryExists'
    'Assert-ArtifactPresent'
    'Assert-NativeLinkRun'
    'Assert-DllLoads'
    'Assert-EnvVarSet'
)
