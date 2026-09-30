#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Test-Container.ps1's assertion harness; run state is module state, as $script: never crosses the caller boundary.

Set-StrictMode -Version Latest

$script:exitOnFirstFailure = $false

function Initialize-SmokeTestRun {
    <#
    .SYNOPSIS
        Reset counters and record run-level switches. Call once, before the first assertion.
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
        Counters for the caller's SUMMARY; its own $script:passed is a different, always-zero variable.
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
        # Per-section counts: a single MinPassed floor let whole subsystems vanish green.
        SectionPassed  = $script:sectionCounts
    }
}

function Complete-SmokeSection {
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
# -ExitOnFirstFailure short-circuits rather than throws, which would skip the SUMMARY dump.
$script:abortRun = $false

function Skip-Test {
    # One home, so a skip can never be printed without being counted.
    param([Parameter(Mandatory)][string]$Reason)
    if ($script:abortRun) { return }
    Write-Host "  [SKIP] $Reason" -ForegroundColor Yellow
    $script:skipped++
}

function Write-TestHeader {
    param([string]$Title)
    Complete-SmokeSection
    # Keyed by the title's leading number ('8. ONNX Runtime' -> '8'), else the full title.
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
        Scrub-then-create a scratch dir, so a previous section's leaked scratch cannot pose as fresh output.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

function Assert-PythonSnippet {
    <#
    .SYNOPSIS
        Run `python -c $Code`; require exit 0 and every -ExpectMatch regex in the combined output.
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
    # Captured under another name: Assert-Test's own $Name shadows this one under dynamic scoping.
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
    # At least one $Filter match under $Root; with -Informational a miss is a SKIP, for optional artifacts.
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
    # GetNewClosure: Assert-Test's scope cannot see the function-local $count.
    Assert-Test -Name $Description -Condition { $count -gt 0 }.GetNewClosure() -FailMessage "No file matching '$Filter' found under $searchRoot"
}

function Test-TensorRtTreeStaged {
    # Set AND non-empty, like Resolve-TensorRtRoot: the optional C:\tensorrt exists empty on the zip-less lane.
    param([string]$Root = $env:TENSORRT_ROOT)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    return @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue).Count -gt 0
}

function Assert-NativeLinkRun {
    # Compile, link and run a tiny TU: existence checks miss dependent DLLs, CRT mismatches and ABI breaks.
    param(
        [string]$Name,
        [string]$WorkName,        # unique temp-dir suffix
        [string]$Source,          # C++ source text
        [string[]]$IncludeDirs,
        [string]$LibDir,
        [string]$LibName,
        [string]$DllDir,          # prepended to PATH so the DLL resolves at run
        [string]$ExpectMatch,     # regex the program's stdout must match
        [string]$FailMessage,
        # Cross lane: assert the exe's PE machine instead of running it, as an aarch64 exe cannot run here.
        [switch]$CrossLinkOnly
    )
    $work = $WorkName; $body = $Source; $incs = $IncludeDirs
    $ldir = $LibDir; $lname = $LibName; $ddir = $DllDir; $expect = $ExpectMatch
    $cross = $CrossLinkOnly.IsPresent
    $targetFlag = if ($cross) { "/clang:--target=$(Get-ClangTargetTriple)" } else { $null }
    $expectMachine = if ($cross) { Get-PeMachineType } else { 0 }
    Assert-Test -Name $Name -Condition {
        $d = Join-Path $env:TEMP "kataglyphis-smoke-$work"
        New-Item -Path $d -ItemType Directory -Force | Out-Null
        $src = Join-Path $d 'main.cpp'
        Set-Content -Path $src -Value $body -Encoding ASCII
        $exe = Join-Path $d 'main.exe'
        $clangArgs = @($src, '/std:c++17', '/EHsc', '/nologo')
        if ($targetFlag) { $clangArgs += $targetFlag }
        foreach ($i in $incs) { $clangArgs += "/I$i" }
        $clangArgs += @("/Fe$exe", '/link', "/LIBPATH:$ldir", $lname)
        & clang-cl @clangArgs 2>&1 | Out-Null
        $ok = $false
        if (($LASTEXITCODE -eq 0) -and (Test-Path $exe)) {
            if ($cross) {
                try { $ok = ((Get-PeFileMachine -Path $exe) -eq $expectMachine) } catch { $ok = $false }
            } else {
                $prev = $env:PATH
                $env:PATH = "$ddir;$env:PATH"
                try { $out = (& $exe 2>&1 | Out-String); $code = $LASTEXITCODE } finally { $env:PATH = $prev }
                $ok = ($code -eq 0) -and ($out -match $expect)
            }
        }
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        return $ok
    }.GetNewClosure() -FailMessage $FailMessage
}

# One superset definition: an Add-Type type is session-global, so the first definition loaded would win.
function Initialize-KataNativeProbe {
    if ('KataNativeProbe' -as [type]) { return }
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

function Assert-DllLoads {
    # LoadLibrary proves the whole dependent-DLL chain resolves, for libs whose headers are awkward to compile against.
    param(
        [string]$Name,
        [string]$DllPath,
        [string[]]$DependencyDirs = @(),
        [string]$Export = '',
        [string]$FailMessage
    )
    $dllPath = $DllPath; $depDirs = $DependencyDirs; $export = $Export
    # Outside the closure: GetNewClosure's dynamic module cannot see this module's private functions.
    Initialize-KataNativeProbe
    Assert-Test -Name $Name -Condition {
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
    # Renamed captures: Assert-Test's own $Name shadows this one under dynamic scoping.
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
    # Every shipped DLL, not a sample: only a load test catches a broken dependency chain; -Allow lists by-design failures.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root,
        [string[]]$DependencyDirs = @(),
        [string[]]$Allow = @(),
        [int]$MinimumChecked = 1
    )
    # Probed here, not in the condition: -FailMessage is evaluated at call time and would miss the results.
    Initialize-KataNativeProbe
    $problems = @()
    $checked = 0
    if (-not (Test-Path $Root)) {
        $problems += "root not found: $Root"
    } else {
        $dlls = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.dll' -File -ErrorAction SilentlyContinue)
        # Rot guard, counted after -Allow, so an empty or fully allow-listed root cannot pass vacuously.
        $candidates = @($dlls | Where-Object { $Allow -notcontains $_.Name })
        if ($candidates.Count -lt $MinimumChecked) {
            $problems += "only $($candidates.Count) non-allow-listed DLL(s) under $Root (of $($dlls.Count) found), expected at least $MinimumChecked - wrong root, or over-broad -Allow?"
        } else {
            $prev = $env:PATH
            try {
                foreach ($d in $dlls) {
                    if ($Allow -contains $d.Name) { continue }
                    $checked++
                    # Each DLL's own dir leads: a full-path LoadLibraryW does not search it for dependents.
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
    'Test-TensorRtTreeStaged'
    'Assert-NativeLinkRun'
    'Assert-DllLoads'
    'Assert-EnvVarSet'
)
