# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Zero-dependency test harness for the Windows build scripts. Deliberately NOT Pester:
# the container runs Windows PowerShell 5.1 (ships Pester 3.4, quirky) and the host runs
# PowerShell 7.x, while Pester 5 needs a PSGallery install that isn't available offline.
# These ~5 primitives (Describe/It/Assert-*) run identically on 5.1 and 7.x with nothing
# installed, so `Invoke-Tests.ps1` is a hard pre-flight gate before any multi-hour build.

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
        [void]$script:Results.Add([pscustomobject]@{ Group = $script:CurrentGroup; Name = $Name; Ok = $true; Err = $null })
        Write-Host "  [ ok ] $Name" -ForegroundColor DarkGreen
    } catch {
        [void]$script:Results.Add([pscustomobject]@{ Group = $script:CurrentGroup; Name = $Name; Ok = $false; Err = $_.Exception.Message })
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) { throw "Assert-Equal: expected [$Expected] but got [$Actual]. $Message" }
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
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Message = '')
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw "Assert-Throws: expected an exception but none was thrown. $Message" }
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

Export-ModuleMember -Function Describe, It, Reset-TestState, Get-TestResult, `
    Assert-Equal, Assert-True, Assert-False, Assert-Null, Assert-NotNull, Assert-Match, Assert-Throws, `
    Invoke-WithEnv, New-TestDir, Invoke-InTestDir
