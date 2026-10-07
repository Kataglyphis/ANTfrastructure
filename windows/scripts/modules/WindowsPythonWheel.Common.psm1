#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The free-threaded twin of a Cython wheel for Invoke-CiPackaging.ps1; see docs/python-ci.md § Two wheels: GIL and free-threaded

Set-StrictMode -Version Latest

# ci_packaging.sh runs the same helper, so the declaration and the proof exist once.
$script:FreeThreadedHelper = Join-Path $PSScriptRoot '..\..\..\linux\scripts\02-toolchain\python\free-threaded-wheel.py'

function Resolve-FreeThreadedWheelMode {
    <#
    .SYNOPSIS
        -Value, else PYTHON_FREE_THREADED_WHEEL, else auto; anything but auto, on or off throws.
    #>
    [OutputType([string])]
    param([string]$Value = '')
    $mode = if ($Value) { $Value } elseif ($env:PYTHON_FREE_THREADED_WHEEL) { $env:PYTHON_FREE_THREADED_WHEEL } else { 'auto' }
    if ($mode -cnotin @('auto', 'on', 'off')) { throw "PYTHON_FREE_THREADED_WHEEL must be auto, on or off, not '$mode'" }
    return $mode
}

function Get-FreeThreadedTarget {
    <#
    .SYNOPSIS
        The free-threaded twin of -PythonVersion as a uv request and a wheel ABI tag: 3.14 and 3.14.4 give 3.14t and cp314t.
    #>
    param([Parameter(Mandatory)][string]$PythonVersion)
    if ($PythonVersion -notmatch '^(\d+)\.(\d+)') { throw "$PythonVersion is not an X.Y[.Z] Python version" }
    return [pscustomobject]@{ Version = "$($Matches[1]).$($Matches[2])t"; AbiTag = "cp$($Matches[1])$($Matches[2])t" }
}

function Get-PythonWheelAbiTag {
    <#
    .SYNOPSIS
        The ABI field of a wheel file name: cp314t, cp314, abi3 or none.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $parts = [IO.Path]::GetFileNameWithoutExtension($Name).Split('-')
    if (-not $Name.EndsWith('.whl') -or $parts.Count -lt 5) { throw "$Name is not a wheel file name" }
    return $parts[-2]
}

function Find-UvPython {
    <#
    .SYNOPSIS
        The interpreter uv finds for -Request, without downloading one; throws with -Hint when there is none.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Request, [string]$Hint = '')
    $found = @(& uv python find $Request 2>$null)
    if ($LASTEXITCODE -ne 0 -or $found.Count -eq 0) { throw "uv finds no $Request interpreter$(if ($Hint) { "; $Hint" })" }
    return "$($found[-1])".Trim()
}

# Runs the shared helper with -Python and returns its exit code and its output as one string.
function Invoke-FreeThreadedHelper {
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string[]]$Arguments)
    $text = @(& $Python -I $script:FreeThreadedHelper @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text.Trim() }
}

function Get-FreeThreadedWheelPlan {
    <#
    .SYNOPSIS
        Whether this run builds the free-threaded wheel, and the one log line saying why.
    .PARAMETER Python
        Any 3.11+ interpreter, which reads -PyprojectPath for the Free Threading classifier; unused for a cross arch or off.
    #>
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$PyprojectPath,
        [string]$Python = '',
        [string]$CrossArch = ''
    )
    $skip = { param([string]$Why) [pscustomobject]@{ Build = $false; Reason = "free-threaded wheel skipped: $Why" } }
    if ($CrossArch) { return & $skip "the $CrossArch cross build has no free-threaded target interpreter" }
    if ($Mode -ceq 'off') { return & $skip 'PYTHON_FREE_THREADED_WHEEL=off' }
    if (-not $Python) { throw 'Get-FreeThreadedWheelPlan needs -Python to read the classifiers' }
    $verdict = Invoke-FreeThreadedHelper -Python $Python -Arguments @('declares', $PyprojectPath)
    if ($verdict.Code -eq 0) { return [pscustomobject]@{ Build = $true; Reason = "free-threaded wheel: the project declares '$($verdict.Text)'" } }
    if ($verdict.Code -ne 1) { throw "cannot tell whether the project declares free-threading support: $($verdict.Text)" }
    if ($Mode -ceq 'on') { return [pscustomobject]@{ Build = $true; Reason = "free-threaded wheel: PYTHON_FREE_THREADED_WHEEL=on, although $($verdict.Text)" } }
    return & $skip "the project does not declare support ($($verdict.Text))"
}

function Select-FreeThreadedWheel {
    <#
    .SYNOPSIS
        The one wheel a free-threaded build left: its -AbiTag binary, or $null when it is pure; anything else throws.
    #>
    param([IO.FileInfo[]]$Wheels = @(), [Parameter(Mandatory)][string]$AbiTag)
    if ($Wheels.Count -ne 1) { throw "the free-threaded build left $($Wheels.Count) wheels, not one" }
    $abi = Get-PythonWheelAbiTag -Name $Wheels[0].Name
    if ($abi -ceq $AbiTag) { return $Wheels[0] }
    if ($abi -ceq 'none') { return $null }
    throw "the free-threaded build produced $($Wheels[0].Name), not a $AbiTag wheel"
}

function Add-PythonLibPath {
    <#
    .SYNOPSIS
        Puts -PythonDir on LIB when an in-tree CPython keeps python3XY.lib beside python.exe, where setuptools never looks (LNK1104).
    #>
    param([Parameter(Mandatory)][string]$PythonDir)
    if (Get-ChildItem -LiteralPath $PythonDir -Filter 'python3*.lib' -File) { $env:LIB = "$PythonDir;$env:LIB" }
}

function Invoke-FreeThreadedWheelProof {
    <#
    .SYNOPSIS
        Loads every compiled module of -Distribution in -Python's venv and returns the verdict; throws unless the GIL stays off.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$Distribution)
    $verdict = Invoke-FreeThreadedHelper -Python $Python -Arguments @('prove', $Distribution)
    if ($verdict.Code -ne 0) { throw "free-threaded proof failed for ${Distribution}: $($verdict.Text)" }
    return $verdict.Text
}

Export-ModuleMember -Function Resolve-FreeThreadedWheelMode, Get-FreeThreadedTarget, Get-PythonWheelAbiTag, Find-UvPython,
    Get-FreeThreadedWheelPlan, Select-FreeThreadedWheel, Add-PythonLibPath, Invoke-FreeThreadedWheelProof
