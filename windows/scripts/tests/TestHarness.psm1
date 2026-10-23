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

# Suite-scoped fixtures keep their diagnostic prefix and clean up in AfterAll.
function Remove-TestDir {
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-TestDir {
    param([string]$Prefix = 'wbt-', [Collections.IDictionary]$Files)
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop
    try {
        if ($null -ne $Files) { Write-TestFileTree -Root $d -Files $Files }
        return $d
    } catch {
        Remove-TestDir -Path $d
        throw
    }
}

# Zeroes $LASTEXITCODE so cases that inspect native exit codes are isolated from earlier runs.
function Invoke-InTestDir {
    param([Parameter(Mandatory)][scriptblock]$Body, [Collections.IDictionary]$Files, [Alias('Prefix')][string]$DirectoryPrefix = 'wbt-')
    $global:LASTEXITCODE = 0
    $d = New-TestDir -Prefix $DirectoryPrefix -Files $Files
    try {
        & $Body $d
    }
    finally { Remove-TestDir -Path $d }
}

# A location fixture must unwind even when an assertion fails; it leaves the native exit code observable.
function Invoke-InTestLocation {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Body)
    Push-Location -LiteralPath $Path -ErrorAction Stop
    try { & $Body }
    finally { Pop-Location }
}

Export-ModuleMember -Function Invoke-InTestLocation

function Invoke-DirectoryCleanupProbe {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $record = [pscustomobject]@{ Path = ''; Exit = -1 }
    $savedExit = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    try { & $Body $record }
    finally {
        if ($savedExit) { $global:LASTEXITCODE = $savedExit.Value } else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        Remove-TestDir -Path $record.Path
    }
}

Export-ModuleMember -Function Invoke-DirectoryCleanupProbe

function Get-TestFileTreeEntry {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][Collections.IDictionary]$Files)
    foreach ($entry in $Files.GetEnumerator()) {
        [pscustomobject]@{ Path = Join-Path $Root ([string]$entry.Key); Text = [string]$entry.Value }
    }
}

function Write-TestFileTree {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][System.Collections.IDictionary]$Files)
    foreach ($entry in (Get-TestFileTreeEntry -Root $Root -Files $Files)) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($entry.Path))
        [IO.File]::WriteAllText($entry.Path, $entry.Text)
    }
}

function Get-TestJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-TestDockerfileStages {
    param([Parameter(Mandatory)][string]$Text, [switch]$JoinContinuations, [switch]$IgnoreComments,
        [switch]$TrimLines, [switch]$StrictFromHeader)
    if ($JoinContinuations) { $Text = $Text -replace '[ \t]*`\r?\n\s*', ' ' }
    $lines = @($Text -split '\r?\n')
    $stages = [System.Collections.Generic.List[object]]::new()
    $global = [System.Collections.Generic.List[string]]::new()
    $current = $null
    $byName = @{}
    $fromPattern = if ($StrictFromHeader) { '^FROM\s+(?<from>\S+)(?:\s+AS\s+(?<name>\S+))?\s*$' } else { '^FROM\s+(?<from>\S+)(\s+AS\s+(?<name>\S+))?' }
    foreach ($line in $lines) {
        if ($IgnoreComments -and (-not $line.Trim() -or $line -match '^\s*#')) { continue }
        if ($line -match $fromPattern) {
            $current = [pscustomobject]@{ From = $Matches.from; Name = "$($Matches['name'])"; Lines = [System.Collections.Generic.List[string]]::new() }
            $stages.Add($current)
            if ($current.Name) { $byName[$current.Name] = $current }
        } else {
            $instruction = if ($TrimLines) { $line.Trim() } else { $line }
            if ($null -eq $current) { $global.Add($instruction) }
            else { $current.Lines.Add($instruction) }
        }
    }
    return [pscustomobject]@{ Global = @($global); Stages = @($stages); ByName = $byName }
}

function Invoke-InTestScriptDir {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][scriptblock]$Body)
    $source = Get-TestScriptAst -ScriptPath $ScriptPath
    $callback = $Body
    Invoke-InTestDir -Body { param($dir) & $callback $dir $source.Extent.File }.GetNewClosure()
}

Export-ModuleMember -Function Invoke-InTestScriptDir

Export-ModuleMember -Function Get-TestFileTreeEntry, Write-TestFileTree, Get-TestJsonFile, Get-TestDockerfileStages

function New-TestBatchTool {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Name,
        [string[]]$Line = @(), [int]$ExitCode = 0)
    $path = Join-Path $Directory $Name
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $text = (@('@echo off') + $Line + @("exit /b $ExitCode")) -join "`r`n"
    [IO.File]::WriteAllText($path, $text + "`r`n", [Text.Encoding]::ASCII)
    return $path
}

function New-TestBatchToolSetup {
    param([Parameter(Mandatory)][string]$Name, [string[]]$Line = @(), [int]$ExitCode = 0)
    $writer = Get-Command New-TestBatchTool -CommandType Function
    $content = @($Line)
    return { param($dir) & $writer -Directory $dir -Name $Name -Line $content -ExitCode $ExitCode }.GetNewClosure()
}

Export-ModuleMember -Function New-TestBatchTool, New-TestBatchToolSetup

function Assert-TestBatchFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    Assert-Equal ([Convert]::ToHexString([Text.Encoding]::ASCII.GetBytes($Expected))) ([Convert]::ToHexString([IO.File]::ReadAllBytes($Path)))
}

function New-TestBatchFixture {
    param([Parameter(Mandatory)][string]$Directory)
    $path = New-TestBatchTool -Directory (Join-Path $Directory 'missing parent') -Name 'fixture tool.cmd' -Line 'echo ARG1=[%~1] ARG2=[%~2]' -ExitCode 7
    Assert-TestBatchFile -Path $path -Expected "@echo off`r`necho ARG1=[%~1] ARG2=[%~2]`r`nexit /b 7`r`n"
    return $path
}

function Invoke-TestBatchToolMutationCases {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$DroppedLineExpected = 'Assert-Equal')
    $batchAssertion = $Body
    foreach ($fault in @(
            @{ Name = 'detects a batch writer that ignores the requested final exit'; Find = '"exit /b $ExitCode"'; Replace = '"exit /b 0"'; Expected = 'Assert-Equal' },
            @{ Name = 'detects a batch writer that drops caller behavior'; Find = ' + $Line + '; Replace = ' + '; Expected = $DroppedLineExpected }
        )) {
        It $fault.Name {
            Invoke-TestFunctionMutations -ModuleArguments @{ ScriptPath = 'windows/scripts/tests/TestHarness.psm1'; FunctionName = @('New-TestBatchTool'); BodyArgumentList = @($batchAssertion) } `
                -Case $fault -Body {
                    param($assertion)
                    Invoke-InTestDir { param($dir)
                        $path = New-MutTestBatchTool -Directory $dir -Name fail.cmd -Line 'echo caller-marker' -ExitCode 7
                        & $assertion $path
                    }
                }
        }
    }
}

Export-ModuleMember -Function Assert-TestBatchFile, New-TestBatchFixture, Invoke-TestBatchToolMutationCases

function Assert-TestScriptContains {
    # Literal presence cannot establish AST structure, uniqueness or runtime behavior.
    param([Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Literal,
        [string]$ReasonPrefix = 'required script literal')
    if ($null -eq $Literal -or $Literal.Count -eq 0) { throw 'Literal must contain at least one nonempty string' }
    foreach ($needle in $Literal) {
        if ([string]::IsNullOrEmpty($needle)) { throw 'Literal must contain only nonempty strings' }
    }
    $path = if ([IO.Path]::IsPathRooted($ScriptPath)) { $ScriptPath } else { Join-Path (Get-RepoRoot) $ScriptPath }
    $text = [IO.File]::ReadAllText($path)
    foreach ($needle in $Literal) { Assert-True $text.Contains($needle) ("${ReasonPrefix}: $needle") }
}

Export-ModuleMember -Function Assert-TestScriptContains

function Invoke-WithTestFunction {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Definition,
        [Parameter(Mandatory)][scriptblock]$Body, [object[]]$BodyArgumentList = @(), [object]$FixtureState)
    if ($PSBoundParameters.ContainsKey('FixtureState')) {
        if ($BodyArgumentList.Count) { throw 'FixtureState cannot be combined with BodyArgumentList' }
        $State = $FixtureState
        $Definition = $Definition.GetNewClosure()
        $BodyArgumentList = ,$State
    }
    $path = "Function:global:$Name"
    $previous = Get-Item -LiteralPath "Function:$Name" -ErrorAction SilentlyContinue
    $previousDefinition = if ($previous) { $previous.ScriptBlock }
    Set-Item -LiteralPath $path -Value $Definition
    try { & $Body @BodyArgumentList } finally {
        if ($previous) { Set-Item -LiteralPath $path -Value $previousDefinition }
        else { Remove-Item -LiteralPath "Function:$Name" -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Invoke-WithTestFunction

function Invoke-WithTestNativeCommand {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object]$FixtureState,
        [Parameter(Mandatory)][scriptblock]$Implementation, [Parameter(Mandatory)][scriptblock]$Body)
    $State = $FixtureState
    $definition = {
        $State.Calls.Add(@($args))
        & $Implementation $State $args
        $global:LASTEXITCODE = $State.Code
    }.GetNewClosure()
    $previous = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousValue = if ($previous) { $previous.Value }
    try {
        Invoke-WithTestFunction -Name $Name -Definition $definition -Body $Body -BodyArgumentList (,$FixtureState)
    } finally {
        if ($previous) { $global:LASTEXITCODE = $previousValue }
        else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Invoke-WithTestNativeCommand

# The callback adds caller policy after recording the attempted fetch, before an archive can appear.
function Get-TestDownloadPrelude {
    @'
function Invoke-DownloadWithRetry {
    param($Url, $DestinationPath, $Description, $ExpectedSha256, $ExpectSignature)
    $record = @{ Url = $Url; Destination = $DestinationPath; Description = $Description; Sha = $ExpectedSha256; Signature = $ExpectSignature }
    $State.Calls.Add($record)
    if ($State.PSObject.Properties['Download']) { & $State.Download $record $State }
    $content = if ($State.PSObject.Properties['DownloadContent']) { $State.DownloadContent } else { 'archive' }
    [IO.File]::WriteAllText($DestinationPath, $content)
}
'@
}

Export-ModuleMember -Function Get-TestDownloadPrelude

function New-TestCallState {
    param([System.Collections.IDictionary]$Properties = @{})
    $state = [ordered]@{ Calls = [Collections.Generic.List[object]]::new() }
    foreach ($key in $Properties.Keys) {
        if ($key -eq 'Calls') { throw 'Calls is reserved for the fixture call collection' }
        $state[$key] = $Properties[$key]
    }
    return [pscustomobject]$state
}

Export-ModuleMember -Function New-TestCallState

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
    $Path = $Path -replace '\\', '/'
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
    $Path = $Path -replace '\\', '/'
    $tree = "$Path.tree"
    $null = New-Item -ItemType Directory -Force -Path $tree, (Split-Path $Path -Parent)
    foreach ($m in $Member.GetEnumerator()) {
        $file = Join-Path $tree ($m.Key -replace '\\', '/')
        if ($m.Value -is [hashtable]) { New-OrtTestPe -Path $file -Machine $m.Value.Machine -Import @($m.Value.Import); continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent)
        [IO.File]::WriteAllText($file, $m.Value)
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($tree, $Path)
    Remove-Item -LiteralPath $tree -Recurse -Force
    return $Path
}

# <Tool>.cmd per -Tool in -Dir: logs "<Tool> %*" to %FAKE_LOG%, then runs fake-<Tool>.ps1; pwsh -File would split --x=a:b at its colon.
function New-FakeToolShim {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string[]]$Tool)
    foreach ($name in $Tool) {
        Set-Content -LiteralPath (Join-Path $Dir "$name.cmd") -Encoding ascii -Value @(
            '@echo off', ">>`"%FAKE_LOG%`" echo $name %*", "pwsh -NoProfile -File `"%~dp0fake-$name.ps1`" %*")
    }
}

function Get-TestResult { return $script:Results }

# Anchored on this module's location, so it does not depend on how the calling suite was loaded.
function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

# Test-Container.ps1's 63-byte Identity model as lowercase hex, the form a Python probe or the arm64 gate embeds.
function Get-IdentityOnnxHex {
    $tc = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-Container.ps1'))
    $bytes = [regex]::Match($tc, '(?s)\$script:identityOnnxBytes = \[byte\[\]\]@\((.*?)\)').Groups[1].Value
    $hex = -join ([regex]::Matches($bytes, '0x([0-9A-Fa-f]{2})') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
    if ($hex.Length -ne 126) { throw "the identity model in Test-Container.ps1 is $($hex.Length / 2) bytes, not 63" }
    return $hex
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

function Copy-TestModuleClosure {
    param([Parameter(Mandatory)][string[]]$Seed, [Parameter(Mandatory)][string]$Destination,
        [string]$ModuleRoot = (Join-Path (Get-RepoRoot) 'windows/scripts/modules'))
    $paths = @(Get-ModuleImportClosure -Seed $Seed -ModuleDir $ModuleRoot | ForEach-Object { Join-Path $ModuleRoot "$_.psm1" })
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required test module missing: $path" }
    }
    $null = [IO.Directory]::CreateDirectory($Destination)
    foreach ($path in $paths) { Copy-Item -LiteralPath $path -Destination $Destination -ErrorAction Stop }
}

Export-ModuleMember -Function Copy-TestModuleClosure

# Parsing declarations must never execute the build script being inspected.
function Resolve-TestParseResult {
    param($Ast, [object[]]$ParseError, [string]$FailurePrefix)
    if ($ParseError -and $ParseError.Count -gt 0) { throw "${FailurePrefix}: $($ParseError[0].Message)" }
    return $Ast
}

function Get-TestScriptAst {
    param([Parameter(Mandatory)][string]$ScriptPath, [string]$ErrorLabel = 'Get-TestScriptAst')
    $full = if ([IO.Path]::IsPathRooted($ScriptPath)) { $ScriptPath } else { Join-Path (Get-RepoRoot) $ScriptPath }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "${ErrorLabel}: script not found: $full" }
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors)
    Resolve-TestParseResult -Ast $ast -ParseError $parseErrors -FailurePrefix "${ErrorLabel}: parse errors in $full"
}

function Get-TestAstCommands {
    param([System.Management.Automation.Language.Ast]$Ast, [string]$Name)
    $Ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $Name
    }, $true)
}

function Get-TestScriptCommands {
    param([string]$ScriptPath, [string]$Name)
    Get-TestAstCommands -Ast (Get-TestScriptAst -ScriptPath $ScriptPath) -Name $Name
}

# Executable call-site fixtures must reject missing or extra wiring before creating runnable blocks.
function Get-TestScriptCommandBlock {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$Name,
        [int]$ExpectedCount = 1)
    Assert-True ($ExpectedCount -gt 0) 'ExpectedCount must be positive'
    $calls = @(Get-TestScriptCommands -ScriptPath $ScriptPath -Name $Name)
    Assert-Equal $ExpectedCount $calls.Count "Expected $ExpectedCount $Name call(s) in $ScriptPath; found $($calls.Count)"
    foreach ($call in $calls) { [scriptblock]::Create($call.Extent.Text) }
}

Export-ModuleMember -Function Get-TestScriptCommandBlock

function Get-TestCommandArguments {
    param([System.Management.Automation.Language.CommandAst]$Command, [switch]$AsAst)
    $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($Command, $false).BoundParameters
    $arguments = @{}
    foreach ($name in $bound.Keys) { $arguments[$name] = if ($AsAst) { $bound[$name].Value } else { $bound[$name].Value.Extent.Text } }
    return $arguments
}

function ConvertTo-TestScriptParseResult {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$ErrorLabel = 'Get-TestScriptAst')
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    $ast = Resolve-TestParseResult -Ast $ast -ParseError $parseErrors -FailurePrefix "$ErrorLabel snippet failed to parse"
    [pscustomobject]@{ Ast = $ast; Tokens = @($tokens) }
}

function ConvertTo-TestScriptAst {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$ErrorLabel = 'Get-TestScriptAst')
    (ConvertTo-TestScriptParseResult -Text $Text -ErrorLabel $ErrorLabel).Ast
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
    $ast = Get-TestScriptAst -ScriptPath $full -ErrorLabel 'Get-ScriptFunctionDefinition'
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
    param([string]$Text, [string[]]$FunctionName = @(), [string]$Find = '',
        [AllowEmptyString()][string]$Replace = '', [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Prelude = '', [string]$Prefix = 'Mut', [object[]]$ArgumentList = @(),
        [object[]]$BodyArgumentList = @(), [object]$FixtureState, [string]$ScriptPath)
    if ($PSBoundParameters.ContainsKey('Text') -eq $PSBoundParameters.ContainsKey('ScriptPath')) { throw 'Provide exactly one of Text or ScriptPath' }
    if ($PSBoundParameters.ContainsKey('ScriptPath')) {
        $fullPath = if ([IO.Path]::IsPathRooted($ScriptPath)) { $ScriptPath } else { Join-Path (Get-RepoRoot) $ScriptPath }
        $Text = [IO.File]::ReadAllText($fullPath)
    }
    if (-not $Text) { throw 'Fixture source text must not be empty' }
    if ($PSBoundParameters.ContainsKey('FixtureState')) {
        if ($ArgumentList.Count -or $BodyArgumentList.Count) { throw 'FixtureState cannot be mixed with explicit fixture arguments' }
        $ArgumentList = ,$FixtureState
        $BodyArgumentList = ,$FixtureState
        $Prelude = "param(`$State)`n" + $Prelude
    }
    # Renamed: inside Invoke-InTestDir, $Body is that function's own parameter.
    $mutantBody = $Body
    Invoke-InTestDir { param($dir)
        $m = Import-FunctionModule -Text $Text -Dir $dir -FunctionName $FunctionName -Find $Find -Replace $Replace -Prelude $Prelude -Prefix $Prefix -ArgumentList $ArgumentList
        try { & $mutantBody @BodyArgumentList } finally { Remove-Module $m -Force }
    }
}

function Invoke-TestFunctionMutations {
    param([Collections.IDictionary]$ModuleArguments, [scriptblock]$ModuleArgumentsFactory, [string]$ScriptPath, [string[]]$FunctionName = @(),
        [object[]]$BodyArgumentList = @(), [string]$Find, [AllowEmptyString()][string]$Replace, [string]$Expected, [string]$Throws,
        [AllowNull()][AllowEmptyCollection()][Collections.IDictionary[]]$Case, [switch]$IncludeControl,
        [Parameter(Mandatory)][scriptblock]$Body)
    $ErrorActionPreference = 'Stop'
    if ($PSBoundParameters.ContainsKey('ModuleArgumentsFactory')) {
        foreach ($key in @('ModuleArguments', 'ScriptPath', 'FunctionName', 'BodyArgumentList')) {
            if ($PSBoundParameters.ContainsKey($key)) { throw "ModuleArgumentsFactory cannot be mixed with $key" }
        }
        if ($null -eq $ModuleArgumentsFactory) { throw 'ModuleArgumentsFactory must be a scriptblock' }
        $factory = $ModuleArgumentsFactory
        $executor = $MyInvocation.MyCommand
        $forwardedOptions = [hashtable]$PSBoundParameters
        $null = $forwardedOptions.Remove('ModuleArgumentsFactory')
        Invoke-InTestDir { param($dir)
            $recipe = & $factory $dir
            if ($recipe -isnot [Collections.IDictionary]) { throw 'ModuleArgumentsFactory must return exactly one dictionary' }
            & $executor -ModuleArguments $recipe @forwardedOptions
        }.GetNewClosure()
        return
    }
    if ($ScriptPath) {
        if ($ModuleArguments) { throw 'ScriptPath and ModuleArguments cannot be mixed' }
        $ModuleArguments = @{ ScriptPath = $ScriptPath; FunctionName = $FunctionName; BodyArgumentList = $BodyArgumentList }
    }
    if ($null -eq $ModuleArguments) { throw 'A source path or module arguments are required' }
    if (-not $PSBoundParameters.ContainsKey('Case')) {
        if ($Throws -and -not $Expected) { $Expected = 'expected an exception but none was thrown' }
        $Case = @(@{ Find = $Find; Replace = $Replace; Expected = $Expected })
    } elseif ($PSBoundParameters.ContainsKey('Find') -or $PSBoundParameters.ContainsKey('Replace') -or $PSBoundParameters.ContainsKey('Expected')) {
        throw 'Case and individual mutation fields cannot be mixed'
    }
    if ($null -eq $Case -or $Case.Count -eq 0) { throw 'Case must contain at least one mutation' }
    foreach ($mutation in $Case) {
        foreach ($field in @('Find', 'Replace', 'Expected')) {
            if ($null -eq $mutation -or -not $mutation.Contains($field)) { throw "Mutation case requires $field" }
        }
        if ([string]::IsNullOrEmpty($mutation.Find) -or [string]::IsNullOrEmpty($mutation.Expected)) {
            throw 'Mutation Find and Expected must be nonempty'
        }
    }
    foreach ($key in @('Body', 'Find', 'Replace')) {
        if ($ModuleArguments.Contains($key)) { throw "ModuleArguments cannot supply $key" }
    }
    $assertThrows = Get-Command Assert-Throws
    $originalBody = $Body
    $expectedThrow = $Throws
    $exerciseBody = {
        $forwarded = @($args)
        $callback = $originalBody
        $operation = { & $callback @forwarded }.GetNewClosure()
        if ($expectedThrow) { & $assertThrows -Body $operation -MessagePattern $expectedThrow }
        else { & $operation }
    }.GetNewClosure()
    $arguments = @{}
    foreach ($key in $ModuleArguments.Keys) { $arguments[$key] = $ModuleArguments[$key] }
    if ($IncludeControl) {
        $arguments.Body = $exerciseBody
        Invoke-WithFunctionModule @arguments
    }
    foreach ($mutation in $Case) {
        $expected = [string]$mutation.Expected
        $guardedBody = {
            $forwarded = @($args)
            $runExercise = $exerciseBody
            & $assertThrows -Body { & $runExercise @forwarded }.GetNewClosure() -MessagePattern $expected
        }.GetNewClosure()
        $arguments.Find = [string]$mutation.Find
        $arguments.Replace = [string]$mutation.Replace
        $arguments.Body = $guardedBody
        # Import and parse failures cannot satisfy the assertion expected from the original test body.
        Invoke-WithFunctionModule @arguments
    }
}

Export-ModuleMember -Function Invoke-TestFunctionMutations

function Start-LoopbackListener {
    # A started TcpListener on a free loopback port; after Stop() nothing answers on that port.
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    return $listener
}

Export-ModuleMember -Function Start-LoopbackListener, Describe, It, Reset-TestState, Get-TestResult, Get-RepoRoot, Get-IdentityOnnxHex, Get-ModuleImportClosure, Get-ScriptFunctionDefinition, Get-TestScriptAst, ConvertTo-TestScriptAst, Get-TestAstCommands, Get-TestCommandArguments, Get-TestScriptCommands, `
    Import-FunctionModule, Invoke-WithFunctionModule, Assert-Equal, Assert-True, Assert-False, Assert-Null, Assert-NotNull, Assert-Match, Assert-Throws, `
    Invoke-WithEnv, Remove-TestDir, New-TestDir, Invoke-InTestDir, New-TestPeFile, New-OrtTestExportTable, New-OrtTestPe, New-TestWheel, New-FakeToolShim

function Invoke-SourceFileDiagnosticCase {
    param([string]$InitialText, [scriptblock]$Transform, [string]$ExpectedText, [bool]$Changed)
    Invoke-InTestDir { param($dir)
        $path = Join-Path $dir 'source.txt'
        foreach ($quiet in $false, $true) {
            [IO.File]::WriteAllText($path, $InitialText)
            [IO.File]::SetLastWriteTimeUtc($path, [datetime]'2001-01-01Z')
            $stamp = [IO.File]::GetLastWriteTimeUtc($path)
            $records = @(& { Edit-SourceFile -Path $path -Transform $Transform -WarnMessage 'anchor not found' -Quiet:$quiet } *>&1)
            Assert-Equal $(if ($quiet) { 1 } else { 2 }) $records.Count
            Assert-True ($records[-1] -is [bool])
            Assert-Equal $Changed $records[-1]
            if (-not $quiet) {
                $type = if ($Changed) { [Management.Automation.InformationRecord] } else { [Management.Automation.WarningRecord] }
                Assert-True ($records[0] -is $type)
            }
            Assert-Equal $ExpectedText ([IO.File]::ReadAllText($path))
            if (-not $Changed) { Assert-Equal $stamp ([IO.File]::GetLastWriteTimeUtc($path)) }
            Assert-Throws { Edit-SourceFile -Path $path -Transform { throw 'fixture callback failed' } -Quiet:$quiet } -MessagePattern 'fixture callback failed'
            Assert-Equal $ExpectedText ([IO.File]::ReadAllText($path))
        }
    }
}


Export-ModuleMember -Function Invoke-SourceFileDiagnosticCase

function Invoke-TestPwshProbe {
    param([Parameter(Mandatory)][string]$Source)
    $output = & pwsh -NoProfile -NonInteractive -Command $Source 2>&1 | Out-String
    $code = $LASTEXITCODE
    [pscustomobject]@{ ExitCode = $code; Output = $output.Trim() }
}

function Assert-TestPwshFailure {
    param([Parameter(Mandatory)]$Probe, [Parameter(Mandatory)][string]$Pattern,
        [string]$Reason = 'child PowerShell must fail')
    Assert-False ($Probe.ExitCode -eq 0) ("{0}: {1}" -f $Reason, $Probe.Output)
    Assert-Match $Pattern $Probe.Output
}

Export-ModuleMember -Function Assert-TestPwshFailure

function Test-ColdModuleCommands {
    param([Parameter(Mandatory)][string[]]$ModulePath, [Parameter(Mandatory)][string[]]$CommandName, [switch]$Force)
    $paths = ($ModulePath | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $names = ($CommandName | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $probe = @"
`$ErrorActionPreference = 'Stop'
foreach (`$path in @($paths)) { Import-Module `$path -Force:`$$($Force.IsPresent.ToString().ToLowerInvariant()) -DisableNameChecking }
`$missing = @($names) | Where-Object { -not (Get-Command `$_ -ErrorAction SilentlyContinue) }
if (`$missing) { `$missing -join ','; exit 1 }
exit 0
"@
    Invoke-TestPwshProbe -Source $probe
}

Export-ModuleMember -Function Test-ColdModuleCommands, Invoke-TestPwshProbe

function Get-TestFunctionNames {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
    $Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }
}

Export-ModuleMember -Function Get-TestFunctionNames

function Get-TestAstAncestor {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node,
        [type]$Type = [Management.Automation.Language.Ast],
        [Management.Automation.Language.Ast]$Stop, [switch]$First, [scriptblock]$Predicate)
    for ($parent = $Node.Parent; $parent -and -not [object]::ReferenceEquals($parent, $Stop); $parent = $parent.Parent) {
        if ($parent -is $Type -and (-not $Predicate -or (& $Predicate $parent))) {
            $parent
            if ($First) { return }
        }
    }
}

function Assert-TestAstCommand {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Management.Automation.Language.CommandAst[]]$Command,
        [Parameter(Mandatory)][string]$Text, [string]$Assignment = '')
    Assert-Equal 1 $Command.Count "one call matching $Text"
    Assert-Equal $Text ($Command[0].Extent.Text -replace '\s*`\r?\n\s*', ' ') 'literal command wiring'
    if ($Assignment) {
        $parent = Get-TestAstAncestor -Node $Command[0] -Type ([Management.Automation.Language.AssignmentStatementAst]) -First
        Assert-NotNull $parent 'the call result must be assigned'
        Assert-Equal $Assignment $parent.Left.Extent.Text 'assignment destination'
    }
}

Export-ModuleMember -Function Get-TestAstAncestor, Assert-TestAstCommand, ConvertTo-TestScriptParseResult
