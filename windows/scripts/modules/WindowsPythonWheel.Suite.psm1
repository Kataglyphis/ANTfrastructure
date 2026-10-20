#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The tests a project runs on its installed cp3XYt wheel, on Windows x64 and on the arm64 device; see docs/python-ci.md#the-suite-on-the-installed-wheel

Set-StrictMode -Version Latest

# The Linux twin runs the same helper, so the table and the GIL check exist once.
$script:SuiteHelper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\linux\scripts\02-toolchain\python\free-threaded-wheel-tests.py'))

function Get-FreeThreadedWheelSuiteHelper {
    <#
    .SYNOPSIS
        The shared free-threaded-wheel-tests.py: its table reader and the pytest runner that fails when the GIL is on afterwards.
    #>
    [OutputType([string])]
    param()
    return $script:SuiteHelper
}

function Get-FreeThreadedWheelSuite {
    <#
    .SYNOPSIS
        -PyprojectPath's [tool.antfrastructure.free-threaded-wheel-tests] as Extra, Copy, Env, Isolated and PytestArgs; $null without one, and an invalid one throws.
    .PARAMETER Python
        Any 3.11+ interpreter, which runs the shared helper.
    #>
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$PyprojectPath, [string]$Helper = $script:SuiteHelper)
    # The exit code is the verdict, so a refusal keeps the helper's reason instead of throwing it away.
    $PSNativeCommandUseErrorActionPreference = $false
    $text = (@(& $Python -I $Helper table $PyprojectPath 2>&1 | ForEach-Object { "$_" }) -join "`n").Trim()
    $code = $LASTEXITCODE
    if ($code -eq 1) { return $null }
    if ($code -ne 0) { throw "free-threaded wheel tests: $text" }
    $table = $text | ConvertFrom-Json -AsHashtable
    return [pscustomobject]@{
        Extra      = [string]$table['extra']
        Copy       = [string[]]@($table['copy'])
        Env        = [hashtable]$table['env']
        Isolated   = [bool]$table['isolated']
        PytestArgs = [string[]]@($table['pytest-args'])
    }
}

function Copy-FreeThreadedWheelTestFile {
    <#
    .SYNOPSIS
        Copies each of -Suite's paths from -RepoRoot to the same relative path under -Destination, where no package source can shadow the wheel.
    #>
    param([Parameter(Mandatory)][pscustomobject]$Suite, [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Destination)
    foreach ($rel in $Suite.Copy) {
        $source = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $source)) { throw "free-threaded wheel tests: copy '$rel': no such file or directory in $RepoRoot" }
        $target = Join-Path $Destination $rel
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
}

function New-FreeThreadedWheelTestStage {
    <#
    .SYNOPSIS
        Stages -Suite for a device that runs no uv: its paths in -StageDir\<Name>\ and <Name>.cmd, which runs them there; returns the tests.json entry.
    .PARAMETER Python
        The free-threaded interpreter, relative to -StageDir, whose site-packages hold the lock's set and the wheel unless -Site does.
    .PARAMETER Site
        Site directories, relative to -StageDir: --site puts them ahead of the interpreter's own, since -I ignores PYTHONPATH.
    .PARAMETER Wheel
        The wheel's file name, for the cmd's closing line.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Suite,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$Wheel,
        [string[]]$Site = @(),
        [string]$Helper = $script:SuiteHelper
    )
    # Inside cmd's double quotes only " and % are not literal.
    $values = @($Suite.Env.Keys) + @($Suite.Env.Values) + @($Suite.PytestArgs) + @($Site)
    $bad = @($values | Where-Object { "$_" -match '["%]' })
    if ($bad.Count -gt 0) { throw "free-threaded wheel tests: a device cmd cannot carry "" or %: $($bad -join ' ')" }
    Copy-FreeThreadedWheelTestFile -Suite $Suite -RepoRoot $RepoRoot -Destination (Join-Path $StageDir $Name)
    Copy-Item -LiteralPath $Helper -Destination (Join-Path $StageDir 'free-threaded-wheel-tests.py') -Force
    $command = @("""%~dp0$Python""") + @(if ($Suite.Isolated) { '-I' }) + @('"%~dp0free-threaded-wheel-tests.py"', 'run') +
        @($Site | ForEach-Object { '--site', """%~dp0$_""" }) + @('--') + @($Suite.PytestArgs | ForEach-Object { """$_""" })
    # PYTHONPATH too, for the tests' own child interpreters, which --site does not reach.
    $path = @(if ($Site.Count -gt 0) { "set ""PYTHONPATH=$(@($Site | ForEach-Object { "%~dp0$_" }) -join ';')""" })
    $lines = @('@echo off', "cd /d ""%~dp0$Name""") + $path + @($Suite.Env.Keys | Sort-Object | ForEach-Object { "set ""$_=$($Suite.Env[$_])""" }) +
        @(($command -join ' '), 'if errorlevel 1 exit /b %errorlevel%', "echo free-threaded wheel tests passed: $Wheel")
    Set-Content -LiteralPath (Join-Path $StageDir "$Name.cmd") -Value $lines -Encoding ascii
    return [ordered]@{ exe = "$Name.cmd"; args = @(); kind = 'pytest' }
}

Export-ModuleMember -Function Get-FreeThreadedWheelSuiteHelper, Get-FreeThreadedWheelSuite, Copy-FreeThreadedWheelTestFile, New-FreeThreadedWheelTestStage
