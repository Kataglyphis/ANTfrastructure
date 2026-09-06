#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Zero-dependency test harness for the Windows build scripts. Deliberately NOT Pester:
# the container runs Windows PowerShell 5.1 (ships Pester 3.4, quirky) and the host runs
# PowerShell 7.x, while Pester 5 needs a PSGallery install that isn't available offline.
# These ~5 primitives (Describe/It/Assert-*) run identically on 5.1 and 7.x with nothing
# installed, so `Invoke-Tests.ps1` is a hard pre-flight gate before any multi-hour build.

Set-StrictMode -Version Latest

$script:Results = New-Object System.Collections.ArrayList
$script:CurrentGroup = ''

function Reset-TestState {
    $script:Results = New-Object System.Collections.ArrayList
    $script:CurrentGroup = ''
}

function Describe {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    $script:CurrentGroup = $Name
    Write-Host ''
    Write-Host $Name -ForegroundColor Cyan
    & $Body
}

function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        & $Body
        [void]$script:Results.Add([pscustomobject]@{ Group = $script:CurrentGroup; Name = $Name; Ok = $true; Err = $null; Stack = $null })
        Write-Host "  [ ok ] $Name" -ForegroundColor DarkGreen
    } catch {
        # ScriptStackTrace pinpoints the failing Assert-* call site (file:line);
        # the exception message alone only says WHAT failed, not WHERE.
        $stack = $_.ScriptStackTrace
        [void]$script:Results.Add([pscustomobject]@{ Group = $script:CurrentGroup; Name = $Name; Ok = $false; Err = $_.Exception.Message; Stack = $stack })
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
        foreach ($frame in @($stack -split "`r?`n")) {
            if ($frame) { Write-Host "         $frame" -ForegroundColor DarkGray }
        }
    }
}

function Assert-Equal {
    # Two can't-fail shapes, both MEASURED by running them (2026-08-26 audit),
    # in the primitive under every assertion in this suite:
    #   Assert-Equal @() 'completely-different'  -> PASSED. `-ne` against a
    #     collection returns the FILTERED collection, and an empty result is
    #     falsy, so any comparison whose expected side is an array silently
    #     succeeded. Callers must join first: Assert-Equal 'a,b' ($x -join ',').
    #   Assert-Equal 'tvm_ffi' 'TVM_FFI'         -> PASSED. `-ne` is
    #     case-INSENSITIVE, and this repo compares case-sensitive facts for a
    #     living (EXT_SUFFIX tags, CMake's Python_ vs PYTHON_, PE names).
    # Type coercion (0 vs '0') is deliberately still tolerated: counts arrive
    # as int and are written as int, and tightening it produced only noise.
    param($Expected, $Actual, [string]$Message = '')
    foreach ($side in @(@{ n = 'Expected'; v = $Expected }, @{ n = 'Actual'; v = $Actual })) {
        if ($null -ne $side.v -and $side.v -isnot [string] -and $side.v -is [System.Collections.IEnumerable]) {
            throw "Assert-Equal: $($side.n) is a collection ($($side.v.GetType().Name)) -- join it first, e.g. (`$x -join ','), or the comparison cannot fail. $Message"
        }
    }
    $differs = if ($Expected -is [string] -and $Actual -is [string]) {
        [string]::CompareOrdinal($Expected, $Actual) -ne 0
    } else { $Expected -ne $Actual }
    if ($differs) { throw "Assert-Equal: expected [$Expected] but got [$Actual]. $Message" }
}
function Assert-True {
    param($Condition, [string]$Message = '')
    if (-not $Condition) { throw "Assert-True failed. $Message" }
}
function Assert-False {
    param($Condition, [string]$Message = '')
    if ($Condition) { throw "Assert-False failed. $Message" }
}
function Assert-Null {
    param($Value, [string]$Message = '')
    if ($null -ne $Value) { throw "Assert-Null: expected null but got [$Value]. $Message" }
}
function Assert-NotNull {
    param($Value, [string]$Message = '')
    if ($null -eq $Value) { throw "Assert-NotNull: value was null. $Message" }
}
function Assert-Match {
    param([string]$Pattern, $Actual, [string]$Message = '')
    if ("$Actual" -notmatch $Pattern) { throw "Assert-Match: [$Actual] does not match /$Pattern/. $Message" }
}
function Assert-Throws {
    # -MessagePattern (optional): the thrown exception's message must ALSO match
    # this regex — pins WHICH failure fired, not just that something threw.
    # Absent, the behavior is unchanged (any exception passes).
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Message = '',
        [string]$MessagePattern = ''
    )
    $threw = $false
    $caught = $null
    try { & $Body } catch { $threw = $true; $caught = $_.Exception.Message }
    if (-not $threw) { throw "Assert-Throws: expected an exception but none was thrown. $Message" }
    if ($MessagePattern -and ("$caught" -notmatch $MessagePattern)) {
        throw "Assert-Throws: exception message [$caught] does not match /$MessagePattern/. $Message"
    }
}

# Run $Body with the given env vars set, restoring (or removing) each afterwards.
function Invoke-WithEnv {
    param([Parameter(Mandatory)][hashtable]$Vars, [Parameter(Mandatory)][scriptblock]$Body)
    $saved = @{}
    foreach ($k in $Vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string]$Vars[$k])
    }
    try { & $Body }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# Fresh throwaway directory for filesystem cases; caller removes it (usually in finally).
# No in-repo callers remain (Invoke-InTestDir superseded it) — retained as an exported
# API for external consumers of this harness.
function New-TestDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("wbt-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# Run $Body with a fresh throwaway directory (passed as its first argument),
# guaranteeing cleanup afterwards. Also zeroes $LASTEXITCODE first so cases that
# inspect native exit codes are isolated from whatever ran before. Replaces the
# hand-rolled `$d = New-TestDir; try { ... } finally { Remove-Item ... }` blocks
# (several of which forgot the finally and leaked wbt-* dirs under %TEMP%).
function Invoke-InTestDir {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $d = New-TestDir
    $global:LASTEXITCODE = 0
    try { & $Body $d }
    finally { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-TestResult { return $script:Results }

# One owner for "where is the repo root" (#126): the suites spelled the
# three-parent walk 4 different ways ($PSScriptRoot chains, piped Split-Path,
# unresolved ..\..\.., $PSCommandPath). Anchored on THIS module's location
# (tests -> scripts -> windows -> root), so it is independent of how the
# calling suite was loaded (dot-sourced or invoked).
function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

<#
.SYNOPSIS
    Returns the named functions of a build script as ONE scriptblock, for a
    suite to dot-source (#134).
.DESCRIPTION
    Several helpers live inside build scripts rather than modules, because the
    mounted module set is a single shared closure (see the #134 entry in
    docs/windows-refactor-backlog.md). Their fixture suites therefore lift them
    out of the script's AST instead of running the script -- 9 sites had grown
    the same ~12 lines of Parser::ParseFile boilerplate, each with its own
    spelling of the repo-root walk.

    RETURNS a scriptblock; it does NOT dot-source. `.` inside a module function
    defines into the MODULE's scope, invisible to the caller, so the dot stays
    at the call site:

        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' `
                                        -FunctionName 'log')
    (Write-AssembledWheelDistInfo / Get-PyprojectDependencies were this example
    until they moved into WindowsTvm.Common, 2026-08-31 -- module functions are
    imported normally, not lifted.)

    Throws with the script and function named when a parse fails or a function
    is gone (the "did it move?" signal every suite carried by hand).
.PARAMETER ScriptPath
    Repo-relative path; resolved against Get-RepoRoot.
.PARAMETER FunctionName
    One or more function names. Order is preserved in the emitted scriptblock.
#>
function Get-ScriptFunctionDefinition {
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$FunctionName
    )
    $full = if ([IO.Path]::IsPathRooted($ScriptPath)) { $ScriptPath } else { Join-Path (Get-RepoRoot) $ScriptPath }
    if (-not (Test-Path $full -PathType Leaf)) { throw "Get-ScriptFunctionDefinition: script not found: $full" }
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "Get-ScriptFunctionDefinition: parse errors in ${full}: $($parseErrors[0].Message)" }
    $bodies = foreach ($name in $FunctionName) {
        $fn = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)) | Select-Object -First 1
        if (-not $fn) { throw "Get-ScriptFunctionDefinition: $name not defined in $full (renamed, or moved into a module?)" }
        $fn.Extent.Text
    }
    return [scriptblock]::Create(($bodies -join "`n"))
}

Export-ModuleMember -Function Describe, It, Reset-TestState, Get-TestResult, Get-RepoRoot, Get-ScriptFunctionDefinition, `
    Assert-Equal, Assert-True, Assert-False, Assert-Null, Assert-NotNull, Assert-Match, Assert-Throws, `
    Invoke-WithEnv, New-TestDir, Invoke-InTestDir
