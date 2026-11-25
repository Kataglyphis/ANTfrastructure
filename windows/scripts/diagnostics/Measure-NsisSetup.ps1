#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    CON302 phase 0: measures the image's makensis on a real bundle; it reports facts and proves no shipped installer.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadZip,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$IconPng = (Join-Path $PSScriptRoot '..\..\..\images\logo.png'),
    [string[]]$Compressor = @('zlib', '/SOLID lzma'),
    # makensis 3.13 is not long-path aware, so deep bundle trees need a short root.
    [string]$WorkRoot = (Join-Path $env:SystemDrive 'np')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-NsisProbeScript {
    param([string]$OutFile, [string]$Compressor, [string]$PayloadDir = '', [string]$Icon = '', [switch]$Shortcut)
    $smLink = '$SMPROGRAMS\NsisProbe\NsisProbe.lnk'
    $header = @('Unicode true', "SetCompressor $Compressor", "OutFile `"$OutFile`"", 'RequestExecutionLevel admin',
        'Name "NsisProbe"', 'Function .onInit', '  SetShellVarContext all', 'FunctionEnd', 'InstallDir "$PROGRAMFILES64\NsisProbe"') + @(if ($Icon) { "Icon `"$Icon`"" })
    $body = @('Section', '  SetOutPath "$INSTDIR"') + @(if ($PayloadDir) { "  File /r `"$PayloadDir\*`"" })
    $install = @(if ($Shortcut) { '  WriteUninstaller "$INSTDIR\uninstall.exe"', '  CreateDirectory "$SMPROGRAMS\NsisProbe"',
            "  CreateShortcut `"$smLink`" `"`$INSTDIR\uninstall.exe`"" }) + @('SectionEnd')
    $uninstall = @(if ($Shortcut) { 'Function un.onInit', '  SetShellVarContext all', 'FunctionEnd', 'Section "Uninstall"', "  Delete `"$smLink`"", '  RMDir "$SMPROGRAMS\NsisProbe"',
            '  Delete "$INSTDIR\uninstall.exe"', '  RMDir "$INSTDIR"', 'SectionEnd' })
    return (($header + $body + $install + $uninstall) -join "`r`n") + "`r`n"
}

function ConvertFrom-SevenZipListing {
    param([string[]]$Line)
    $facts = [ordered]@{}
    $hits = $Line | Select-String -Pattern '^(Type|SubType|Method|Solid|Physical Size) = (.*)$'
    foreach ($group in @($hits | ForEach-Object { , $_.Matches[0].Groups })) {
        if (-not $facts.Contains($group[1].Value)) { $facts[$group[1].Value] = $group[2].Value.Trim() }
    }
    return $facts
}

function Resolve-ScoopShimTarget {
    param([string]$Path)
    $shim = [IO.Path]::ChangeExtension($Path, '.shim')
    if (-not (Test-Path -LiteralPath $shim)) { return $Path }
    $hit = Select-String -LiteralPath $shim -Pattern '^\s*path\s*=\s*"?([^"]+?)"?\s*$' | Select-Object -First 1
    if ($null -eq $hit) { throw "$shim names no target path" }
    return $hit.Matches[0].Groups[1].Value
}

function Invoke-NsisBuild {
    param([string]$Makensis, [string]$Script, [string]$OutFile)
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    $log = "$Script.log"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Makensis -ArgumentList @('/V2', "`"$Script`"") -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $peak = 0L
    while (-not $process.HasExited) { $process.Refresh(); $peak = [Math]::Max($peak, $process.PeakWorkingSet64); Start-Sleep -Milliseconds 200 }
    $process.WaitForExit()
    $clock.Stop()
    $size = if (Test-Path -LiteralPath $OutFile) { (Get-Item -LiteralPath $OutFile).Length } else { 0 }
    return [ordered]@{ ExitCode = $process.ExitCode; Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        PeakWorkingSetMB = [Math]::Round($peak / 1MB); SetupBytes = $size; LogTail = @(Get-Content -LiteralPath $log, "$log.err" -Tail 5) }
}

function Get-SevenZipFacts {
    param([string]$Setup)
    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if (-not $sevenZip) { return [ordered]@{ Error = '7z.exe is not on PATH' } }
    return ConvertFrom-SevenZipListing -Line @(& $sevenZip.Source l -slt $Setup 2>&1 | ForEach-Object { "$_" })
}

function New-NsisProbeSetup {
    param([string]$Makensis, [string]$Work, [string]$Tag, [hashtable]$Option)
    $setup = Join-Path $Work "probe-$Tag.exe"
    $nsi = Join-Path $Work "probe-$Tag.nsi"
    [IO.File]::WriteAllText($nsi, (New-NsisProbeScript -OutFile $setup @Option))
    $build = Invoke-NsisBuild -Makensis $Makensis -Script $nsi -OutFile $setup
    $build.Setup = $setup
    return $build
}

function Measure-NsisCompressor {
    param([string]$Makensis, [string]$Work, [string]$Payload, [string]$Name)
    $result = New-NsisProbeSetup -Makensis $Makensis -Work $Work -Tag ($Name -replace '[^a-z]', '') -Option @{ Compressor = $Name; PayloadDir = $Payload }
    $result.Compressor = $Name
    if ($result.ExitCode -eq 0) { $result.SevenZip = Get-SevenZipFacts -Setup $result.Setup; Remove-Item -LiteralPath $result.Setup -Force }
    return $result
}

function Test-NsisPngIcon {
    param([string]$Makensis, [string]$Work, [string]$Png)
    try {
        Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsIcon.Common.psm1') -DisableNameChecking -ErrorAction Stop
        $icon = ConvertTo-PythonAppIcon -PngPath $Png -Destination (Join-Path $Work 'probe.ico')
    } catch { return [ordered]@{ Accepted = $false; Error = "icon not built: $($_.Exception.Message)" } }
    $build = New-NsisProbeSetup -Makensis $Makensis -Work $Work -Tag 'icon' -Option @{ Compressor = 'zlib'; Icon = $icon }
    return [ordered]@{ Accepted = ($build.ExitCode -eq 0); ExitCode = $build.ExitCode; LogTail = $build.LogTail }
}

function Test-NsisStartMenuShortcut {
    param([string]$Makensis, [string]$Work)
    $build = New-NsisProbeSetup -Makensis $Makensis -Work $Work -Tag 'shortcut' -Option @{ Compressor = 'zlib'; Shortcut = $true }
    if ($build.ExitCode -ne 0) { return [ordered]@{ Created = $false; Error = 'shortcut probe did not compile'; LogTail = $build.LogTail } }
    $install = Start-Process -FilePath $build.Setup -ArgumentList '/S' -Wait -PassThru
    $link = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'NsisProbe\NsisProbe.lnk'
    $created = Test-Path -LiteralPath $link
    $uninstaller = Join-Path $env:ProgramFiles 'NsisProbe\uninstall.exe'
    $removed = $null
    if (Test-Path -LiteralPath $uninstaller) {
        $null = Start-Process -FilePath $uninstaller -ArgumentList "/S _?=$(Split-Path $uninstaller)" -Wait -PassThru
        $removed = -not (Test-Path -LiteralPath $link)
    }
    return [ordered]@{ InstallExit = $install.ExitCode; Created = $created; Link = $link; RemovedByUninstaller = $removed }
}

function Invoke-NsisProbe {
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $work = Join-Path $WorkRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $payload = Join-Path $work 'payload'
    $null = New-Item -ItemType Directory -Force -Path $payload
    # A Scoop shim would report its own working set, not the compiler's.
    $makensis = Resolve-ScoopShimTarget -Path (Get-Command makensis.exe -ErrorAction Stop).Source
    $report = [ordered]@{ Makensis = $makensis; Version = "$(& $makensis /VERSION)".Trim(); PayloadZip = $PayloadZip }
    Expand-Archive -LiteralPath $PayloadZip -DestinationPath $payload
    $files = @(Get-ChildItem -LiteralPath $payload -Recurse -File)
    $report.PayloadBytes = ($files | Measure-Object Length -Sum).Sum
    $report.PayloadLongestPath = ($files | ForEach-Object { $_.FullName.Length } | Measure-Object -Maximum).Maximum
    $report.Compressors = @($Compressor | ForEach-Object { Measure-NsisCompressor -Makensis $makensis -Work $work -Payload $payload -Name $_ })
    $report.PngIcon = Test-NsisPngIcon -Makensis $makensis -Work $work -Png $IconPng
    $report.StartMenuShortcut = Test-NsisStartMenuShortcut -Makensis $makensis -Work $work
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'nsis-probe.json') -Encoding utf8
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $failed = @($report.Compressors | Where-Object { $_.ExitCode -ne 0 }).Count
    Write-Host "makensis $($report.Version); $($report.Compressors.Count) compressor(s), $failed failed; report $OutDir\nsis-probe.json"
    if ($failed) { exit 1 }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-NsisProbe }
