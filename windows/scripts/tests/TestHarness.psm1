#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Not Pester: Pester 5 needs a PSGallery install the offline container cannot do, and these need nothing installed.

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
        # The message says what failed; ScriptStackTrace says where.
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
    # `-ne` filters a collection (empty passes) and ignores case, so collections are refused and strings compare ordinally.
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
    # -MessagePattern pins which failure fired, not just that something threw.
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

# [NullString]: a PowerShell $null reaches .NET as '', which would leave the var set but empty.
function Invoke-WithEnv {
    param([Parameter(Mandatory)][hashtable]$Vars, [Parameter(Mandatory)][scriptblock]$Body)
    $asEnv = { param($v) if ($null -eq $v) { [NullString]::Value } else { [string]$v } }
    $saved = @{}
    foreach ($k in $Vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, (& $asEnv $Vars[$k]))
    }
    try { & $Body }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, (& $asEnv $saved[$k])) }
    }
}

# Exported for external consumers; in-repo suites use Invoke-InTestDir, which also cleans up.
function New-TestDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("wbt-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# Zeroes $LASTEXITCODE so cases that inspect native exit codes are isolated from earlier runs.
function Invoke-InTestDir {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $d = New-TestDir
    $global:LASTEXITCODE = 0
    try { & $Body $d }
    finally { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# The smallest file Get-PeFileMachine accepts (MZ, e_lfanew, 'PE', machine), plus a tag so no two fixtures share bytes.
function New-TestPeFile {
    param([Parameter(Mandatory)][string]$Path, [uint16]$Machine = 0x8664, [string]$Tag = 'x')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
    [System.IO.File]::WriteAllBytes($Path, [byte[]](@(0x4D, 0x5A) + @(0) * 0x3A + @(0x40, 0, 0, 0, 0x50, 0x45, 0, 0) +
            [BitConverter]::GetBytes($Machine) + [System.Text.Encoding]::ASCII.GetBytes($Tag)))
}

# IMAGE_EXPORT_DIRECTORY at -Rva with its tables and names; -Forward points every function into it (a forwarder).
function New-OrtTestExportTable {
    param([uint32]$Rva, [string[]]$Name, [switch]$Forward)
    $n = $Name.Count
    $strAt = 40 + 10 * $n
    $strs = [System.Collections.Generic.List[byte]]::new()
    $nameRva = foreach ($x in $Name) { $Rva + $strAt + $strs.Count; $strs.AddRange([System.Text.Encoding]::ASCII.GetBytes("$x`0")) }
    $fwdRva = $Rva + $strAt + $strs.Count
    $strs.AddRange([System.Text.Encoding]::ASCII.GetBytes("onnxruntime.OrtGetApiBase`0"))
    $out = [byte[]]::new($strAt)
    foreach ($f in @(@(20, $n), @(24, $n), @(28, ($Rva + 40)), @(32, ($Rva + 40 + 4 * $n)), @(36, ($Rva + 40 + 8 * $n)))) {
        [BitConverter]::GetBytes([uint32]$f[1]).CopyTo($out, $f[0])
    }
    for ($i = 0; $i -lt $n; $i++) {
        [BitConverter]::GetBytes([uint32]$(if ($Forward) { $fwdRva } else { 0x1000 })).CopyTo($out, 40 + 4 * $i)
        [BitConverter]::GetBytes([uint32]@($nameRva)[$i]).CopyTo($out, 40 + 4 * $n + 4 * $i)
        [BitConverter]::GetBytes([uint16]$i).CopyTo($out, 40 + 8 * $n + 2 * $i)
    }
    return , [byte[]]($out + $strs.ToArray())
}

# A one-section PE32+ carrying import, delay-load, string and export tables for PE-walking suites.
function New-OrtTestPe {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Import = @(), [string[]]$Text = @(), [string[]]$Export = @(), [switch]$Forward,
        [uint16]$Machine = 0x8664, [string[]]$DelayImport = @())
    $rva = 0x1000
    $descSize = 20 * ($Import.Count + 1)
    $names = [System.Collections.Generic.List[byte]]::new()
    $body = [System.Collections.Generic.List[byte]]::new()
    $nameAt = foreach ($i in $Import) { $descSize + $names.Count; $names.AddRange([System.Text.Encoding]::ASCII.GetBytes("$i`0")) }
    foreach ($at in @($nameAt)) { $d = [byte[]]::new(20); [BitConverter]::GetBytes([uint32]($rva + $at)).CopyTo($d, 12); $body.AddRange($d) }
    $body.AddRange([byte[]]::new(20))
    $body.AddRange($names)
    # IMAGE_DELAYLOAD_DESCRIPTORs: 32 bytes, the DLL-name RVA at +4, a zero descriptor last, then the names.
    $delayAt = $body.Count
    $delayNamesAt = $delayAt + 32 * ($DelayImport.Count + 1)
    $delayNames = [System.Collections.Generic.List[byte]]::new()
    foreach ($x in $DelayImport) {
        $d = [byte[]]::new(32)
        [BitConverter]::GetBytes([uint32]($rva + $delayNamesAt + $delayNames.Count)).CopyTo($d, 4)
        $body.AddRange($d)
        $delayNames.AddRange([System.Text.Encoding]::ASCII.GetBytes("$x`0"))
    }
    if ($DelayImport.Count -gt 0) { $body.AddRange([byte[]]::new(32)); $body.AddRange($delayNames) }
    foreach ($t in $Text) { $body.Add(0); $body.AddRange([System.Text.Encoding]::ASCII.GetBytes($t)); $body.Add(0) }
    $expAt = $body.Count
    if ($Export.Count -gt 0) { $body.AddRange((New-OrtTestExportTable -Rva ($rva + $expAt) -Name $Export -Forward:$Forward)) }
    $raw = $body.ToArray()
    $h = [byte[]]::new(0x200)
    $h[0] = 0x4D; $h[1] = 0x5A; $h[0x40] = 0x50; $h[0x41] = 0x45
    [BitConverter]::GetBytes([uint32]0x40).CopyTo($h, 0x3C)
    [BitConverter]::GetBytes($Machine).CopyTo($h, 0x44)
    [BitConverter]::GetBytes([uint16]1).CopyTo($h, 0x46)
    [BitConverter]::GetBytes([uint16]0xF0).CopyTo($h, 0x54)
    [BitConverter]::GetBytes([uint16]0x20B).CopyTo($h, 0x58)
    [BitConverter]::GetBytes([uint32]16).CopyTo($h, 0x58 + 108)
    [BitConverter]::GetBytes([uint32]$rva).CopyTo($h, 0x58 + 120)
    [BitConverter]::GetBytes([uint32]$descSize).CopyTo($h, 0x58 + 124)
    if ($Export.Count -gt 0) {
        [BitConverter]::GetBytes([uint32]($rva + $expAt)).CopyTo($h, 0x58 + 112)
        [BitConverter]::GetBytes([uint32]($raw.Length - $expAt)).CopyTo($h, 0x58 + 116)
    }
    # DataDirectory[13], the delay-load table.
    if ($DelayImport.Count -gt 0) { [BitConverter]::GetBytes([uint32]($rva + $delayAt)).CopyTo($h, 0x58 + 216) }
    [System.Text.Encoding]::ASCII.GetBytes('.rdata').CopyTo($h, 0x148)
    [BitConverter]::GetBytes([uint32]$raw.Length).CopyTo($h, 0x148 + 8)
    [BitConverter]::GetBytes([uint32]$rva).CopyTo($h, 0x148 + 12)
    [BitConverter]::GetBytes([uint32]$raw.Length).CopyTo($h, 0x148 + 16)
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($h, 0x148 + 20)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
    [System.IO.File]::WriteAllBytes($Path, [byte[]]($h + $raw + [byte[]]::new([Math]::Max(0, 2048 - $h.Length - $raw.Length))))
}

# A wheel at -Path from -Member: each value is a file's text, or @{ Machine; Import } for a synthetic PE (New-OrtTestPe).
function New-TestWheel {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Member = @{})
    $tree = "$Path.tree"
    $null = New-Item -ItemType Directory -Force -Path $tree, (Split-Path $Path -Parent)
    foreach ($m in $Member.GetEnumerator()) {
        $file = Join-Path $tree $m.Key
        if ($m.Value -is [hashtable]) { New-OrtTestPe -Path $file -Machine $m.Value.Machine -Import @($m.Value.Import); continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent)
        [IO.File]::WriteAllText($file, $m.Value)
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($tree, $Path)
    Remove-Item -LiteralPath $tree -Recurse -Force
    return $Path
}

function Get-TestResult { return $script:Results }

# Anchored on this module's location, so it does not depend on how the calling suite was loaded.
function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

# The seeds plus their transitive sibling imports, i.e. what a RUN must mount; a seed with no file stays so the mount check names it.
function Get-ModuleImportClosure {
    param([string[]]$Seed = @(), [string]$ModuleDir = (Join-Path (Get-RepoRoot) 'windows' 'scripts' 'modules'))
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($s in @($Seed)) { $queue.Enqueue($s) }
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue()
        if (-not $seen.Add($n)) { continue }
        $p = Join-Path $ModuleDir "$n.psm1"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($p), "(?i)PSScriptRoot\s+'([A-Za-z0-9._]+)\.psm1'")) { $queue.Enqueue($m.Groups[1].Value) }
    }
    return @(@($seen) | Sort-Object)
}

<#
.SYNOPSIS
    Returns the named functions of a build script as one scriptblock for a suite to dot-source.
.DESCRIPTION
    It does not dot-source itself: `.` inside a module function defines into the module's scope.
    Throws naming the script and function when the parse fails or a function is gone.
.PARAMETER ScriptPath
    Repo-relative path, resolved against Get-RepoRoot.
.PARAMETER FunctionName
    Function names; their order is kept in the scriptblock.
.EXAMPLE
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -FunctionName 'log')
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

<#
.SYNOPSIS
    Imports source text, or only its -FunctionName functions, as a module after one optional literal edit.
.DESCRIPTION
    For an in-suite mutant (-Find/-Replace) or a driver lifted over fakes (-Prelude defines what it reads).
    Imported -Global under -Prefix, so the copies never shadow the originals.
#>
function Import-FunctionModule {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Dir,
        [string[]]$FunctionName = @(),
        [string]$Find = '',
        [AllowEmptyString()][string]$Replace = '',
        [string]$Prelude = '',
        [string]$Prefix = 'Mut',
        [object[]]$ArgumentList = @()
    )
    $stem = Join-Path $Dir ('Lifted-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $body = $Text
    if ($FunctionName.Count -gt 0) {
        [IO.File]::WriteAllText("$stem.ps1", $Text)
        $body = (Get-ScriptFunctionDefinition -ScriptPath "$stem.ps1" -FunctionName $FunctionName).ToString()
    }
    if ($Find) {
        if (-not $body.Contains($Find)) { throw "Import-FunctionModule: find text is gone: $Find" }
        $body = $body.Replace($Find, $Replace)
    }
    [IO.File]::WriteAllText("$stem.psm1", $Prelude + "`n" + $body + "`n")
    Import-Module "$stem.psm1" -Global -Prefix $Prefix -Force -PassThru -DisableNameChecking -ArgumentList $ArgumentList
}

# Runs $Body with Import-FunctionModule's *-Mut* copy imported from a fresh test directory, then removes it.
function Invoke-WithFunctionModule {
    param([Parameter(Mandatory)][string]$Text, [string[]]$FunctionName = @(), [string]$Find = '',
        [AllowEmptyString()][string]$Replace = '', [Parameter(Mandatory)][scriptblock]$Body)
    # Renamed: inside Invoke-InTestDir, $Body is that function's own parameter.
    $mutantBody = $Body
    Invoke-InTestDir { param($dir)
        $m = Import-FunctionModule -Text $Text -Dir $dir -FunctionName $FunctionName -Find $Find -Replace $Replace
        try { & $mutantBody } finally { Remove-Module $m -Force }
    }
}

Export-ModuleMember -Function Describe, It, Reset-TestState, Get-TestResult, Get-RepoRoot, Get-ModuleImportClosure, Get-ScriptFunctionDefinition, `
    Import-FunctionModule, Invoke-WithFunctionModule, Assert-Equal, Assert-True, Assert-False, Assert-Null, Assert-NotNull, Assert-Match, Assert-Throws, `
    Invoke-WithEnv, New-TestDir, Invoke-InTestDir, New-TestPeFile, New-OrtTestExportTable, New-OrtTestPe, New-TestWheel
