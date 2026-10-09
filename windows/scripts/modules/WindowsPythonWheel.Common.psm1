#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The free-threaded twin of a Cython wheel for Invoke-CiPackaging.ps1; see docs/python-ci.md § Two wheels: GIL and free-threaded

Set-StrictMode -Version Latest

# A file the Linux lane reads too: the checkout's copy, else the one image mounts put one level above modules\; with neither, the checkout path so the error names it.
function Resolve-SharedLinuxScriptFile {
    param([Parameter(Mandatory)][string]$RepoPath)
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\..\$RepoPath"))
    foreach ($candidate in @($repo, [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\$(Split-Path $RepoPath -Leaf)")))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $repo
}

# ci_packaging.sh runs the same helper, so the declaration and the proof exist once.
$script:FreeThreadedHelper = Resolve-SharedLinuxScriptFile -RepoPath 'linux\scripts\02-toolchain\python\free-threaded-wheel.py'
# ft_wheel_table reads the same twin table, so the two lanes hold one verdict per distribution.
$script:FreeThreadedTwinTable = Resolve-SharedLinuxScriptFile -RepoPath 'linux\scripts\03-media\free-threaded-twins.txt'

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
    return (Split-PythonWheelName -Name $Name)[-2]
}

# A wheel file name's dash-separated fields, the last three being its python, ABI and platform tags; throws for any other name.
function Split-PythonWheelName {
    param([Parameter(Mandatory)][string]$Name)
    $parts = [IO.Path]::GetFileNameWithoutExtension($Name).Split('-')
    if (-not $Name.EndsWith('.whl') -or $parts.Count -lt 5) { throw "$Name is not a wheel file name" }
    return $parts
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

# Runs the shared helper (-Helper, else this checkout's or image's copy) with -Python; returns its exit code and output.
function Invoke-FreeThreadedHelper {
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string[]]$Arguments, [string]$Helper = '')
    if (-not $Helper) { $Helper = $script:FreeThreadedHelper }
    $text = @(& $Python -I $Helper @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
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
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$Distribution, [string]$Helper = '')
    $verdict = Invoke-FreeThreadedHelper -Python $Python -Arguments @('prove', $Distribution) -Helper $Helper
    if ($verdict.Code -ne 0) { throw "free-threaded proof failed for ${Distribution}: $($verdict.Text)" }
    return $verdict.Text
}

function Invoke-FreeThreadedWheelVenvProof {
    <#
    .SYNOPSIS
        Installs -Wheel alone, offline, into a fresh uv venv of -Interpreter and proves -Distribution there; returns the verdict.
    .DESCRIPTION
        The venv's sitecustomize registers -DllDirectory and the wheel's own DLL directories, which the package's __init__
        would load before the compiled modules the proof creates bare. The venv is removed either way.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Interpreter,
        [Parameter(Mandatory)][string]$Wheel,
        [Parameter(Mandatory)][string]$Distribution,
        [string[]]$DllDirectory = @(),
        [string]$Helper = '',
        [string]$VenvDir = (Join-Path ([IO.Path]::GetTempPath()) "ft-proof-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
    )
    try {
        & uv venv --clear --no-cache --quiet --python $Interpreter $VenvDir 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "free-threaded proof: uv venv --python $Interpreter failed (exit $LASTEXITCODE)" }
        $python = Join-Path $VenvDir 'Scripts\python.exe'
        & uv pip install --no-cache --quiet --no-deps --no-index --python $python $Wheel 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "free-threaded proof: $([IO.Path]::GetFileName($Wheel)) does not install into a fresh $Interpreter venv" }
        $site = Join-Path $VenvDir 'Lib\site-packages'
        $own = @(Get-ChildItem -LiteralPath $site -Recurse -Filter '*.dll' -File | ForEach-Object DirectoryName | Sort-Object -Unique)
        $dirs = @(@($DllDirectory) + $own | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
        $shim = @('# Written by Invoke-FreeThreadedWheelVenvProof for this proof venv only.', 'import os', 'for _d in (') +
            @($dirs | ForEach-Object { "    r'$_'," }) + @('):', '    os.add_dll_directory(_d)')
        Set-Content -LiteralPath (Join-Path $site 'sitecustomize.py') -Encoding ascii -Value $shim
        return Invoke-FreeThreadedWheelProof -Python $python -Distribution $Distribution -Helper $Helper
    } finally {
        Remove-Item -LiteralPath $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-FreeThreadedTwinTable {
    <#
    .SYNOPSIS
        The image's wheels and whether each gets a cp3XYt twin (twin), stays GIL-only (gil) or needs none (none); twin:<KNOB> is a Linux-only switch, no twin here.
    .DESCRIPTION
        The rows of linux/scripts/03-media/free-threaded-twins.txt, which the Linux lane's ft_wheel_table reads too. Pin is the
        versions.env key=value the evidence was read at; PythonWheel.FreeThreadedTwin.Tests.ps1 fails when it moves.
        See docs/windows-builds.md#the-free-threaded-wheels
    .PARAMETER Path
        The table file; empty takes the checkout's copy, else the one an image mounts or bakes one level above modules\.
    #>
    param([string]$Path = '')
    if (-not $Path) { $Path = $script:FreeThreadedTwinTable }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "free-threaded: the twin table $Path is missing; mount or copy linux/scripts/03-media/free-threaded-twins.txt one level above modules\"
    }
    foreach ($row in @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch '^\s*(#|$)' })) {
        $dist, $verdict, $pin, $evidence = $row -split '\|', 4
        [pscustomobject]@{ Distribution = $dist; Verdict = $verdict; Pin = $pin; Evidence = $evidence }
    }
}

function ConvertTo-PythonDistributionName {
    # PEP 503's normal form, which is how the twin table spells every distribution.
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[-_.]+', '-').ToLowerInvariant()
}

function Get-FreeThreadedTwinRow {
    <#
    .SYNOPSIS
        The twin table's row for -Distribution (an ORT flavour reads as onnxruntime, a GenAI one as onnxruntime-genai); $null for none.
    #>
    param([Parameter(Mandatory)][string]$Distribution)
    $want = ConvertTo-PythonDistributionName -Name $Distribution
    if ($want -like 'onnxruntime-genai*') { $want = 'onnxruntime-genai' } elseif ($want -like 'onnxruntime-*') { $want = 'onnxruntime' }
    return Get-FreeThreadedTwinTable | Where-Object Distribution -ceq $want | Select-Object -First 1
}

function Get-FreeThreadedWheelFinding {
    <#
    .SYNOPSIS
        Why -Path is no cp3XYt wheel for -PlatformTag: its name tags, and every version-tagged .pyd inside; none = it passes.
    .DESCRIPTION
        An untagged .pyd passes here because CPython loads it on either ABI; the proof decides about those.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$PlatformTag)
    $name = [IO.Path]::GetFileName($Path)
    try { $py, $abi, $plat = (Split-PythonWheelName -Name $name)[-3..-1] } catch { return $_.Exception.Message }
    if ($py -notmatch '^cp\d+$' -or $abi -cne "${py}t") { "$name is tagged $py-$abi, not a cp3XY-cp3XYt pair" }
    if ($plat -cne $PlatformTag) { "$name is a $plat wheel, not $PlatformTag" }
    $suffix = ".$abi-$PlatformTag.pyd"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $base = $entry.Name
            $tagged = $base -match '\.(abi3|cp\d+t?-[a-z0-9_]+)\.pyd$'
            if ($tagged -and -not $base.EndsWith($suffix)) { "$($entry.FullName) is not a $suffix module" }
        }
    } finally { $zip.Dispose() }
}

function Get-WheelMemberDifference {
    <#
    .SYNOPSIS
        The native members (-Include) of -Candidate whose bytes differ from, or are missing in, -Reference; none = one build.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][string]$Candidate, [string[]]$Include = @('*.dll'))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $digest = {
        param([string]$Wheel)
        $map = @{}
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Wheel)
        try {
            foreach ($e in @($zip.Entries | Where-Object { $n = $_.Name; @($Include | Where-Object { $n -like $_ }).Count -gt 0 })) {
                $s = $e.Open()
                try { $map[$e.FullName] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)) } finally { $s.Dispose() }
            }
        } finally { $zip.Dispose() }
        return $map
    }
    $ref = & $digest $Reference
    $cand = & $digest $Candidate
    if ($cand.Count -eq 0) { return "$([IO.Path]::GetFileName($Candidate)) has no member matching $($Include -join ', ')" }
    foreach ($member in ($cand.Keys | Sort-Object)) {
        if (-not $ref.ContainsKey($member)) { "$member is not in $([IO.Path]::GetFileName($Reference))" }
        elseif ($ref[$member] -cne $cand[$member]) { "$member differs from the one in $([IO.Path]::GetFileName($Reference))" }
    }
}

Export-ModuleMember -Function Resolve-FreeThreadedWheelMode, Get-FreeThreadedTarget, Get-PythonWheelAbiTag, Find-UvPython,
    Get-FreeThreadedWheelPlan, Select-FreeThreadedWheel, Add-PythonLibPath, Invoke-FreeThreadedWheelProof,
    Invoke-FreeThreadedWheelVenvProof, Get-FreeThreadedTwinTable, ConvertTo-PythonDistributionName, Get-FreeThreadedTwinRow, Get-FreeThreadedWheelFinding,
    Get-WheelMemberDifference
