#requires -Version 7.0
# Tests the MSI size reader and optionally a text-only administrative extraction.
param([string]$AdditionalReader = '', [switch]$IncludeRoundtrip)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -DisableNameChecking

function New-SizeFixture([string]$Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 3)
    try {
        foreach ($statement in @(
                'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `FileSize` LONG NOT NULL PRIMARY KEY `File`)',
                'INSERT INTO `File` (`File`, `FileSize`) VALUES (''first'', 123)',
                'INSERT INTO `File` (`File`, `FileSize`) VALUES (''second'', 472)'
            )) {
            $view = $database.OpenView($statement)
            try { [void]$view.Execute(); [void]$view.Close() }
            finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
        }
        [void]$database.Commit()
    } finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }
}

function Assert-FixtureSize([string]$Msi, [string]$Additional) {
    $reader = Join-Path $PSScriptRoot '../diagnostics/Get-MsiPayloadSize.ps1'
    $size = & $reader -MsiPath $Msi
    if ($size -ne 595) { throw "Expected 595 fixture bytes, got $size." }
    if ($Additional -and (& $Additional -MsiPath $Msi) -ne 595) { throw 'Consumer size wrapper differs.' }
    $failed = $false
    try { & $reader -MsiPath $Msi -MaxBytes 594 | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'MSI size limit did not reject an oversized payload.' }
}

function Invoke-FixtureRoundtrip([string]$Directory) {
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    Import-Module (Join-Path $repo 'windows/scripts/modules/WindowsPythonApp.Common.psm1') -DisableNameChecking
    $bundle = Join-Path $Directory 'bundle'
    New-Item -ItemType Directory -Path $bundle | Out-Null
    Set-Content -LiteralPath (Join-Path $bundle 'gpu-fixture.txt') -Value 'gpu-fixture' -NoNewline -Encoding ascii
    Set-Content -LiteralPath (Join-Path $bundle 'gpu-fixture.exe') -Value 'fixture' -NoNewline -Encoding ascii
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $env:SystemRoot 'System32/cmd.exe'))
    $stream = [IO.File]::Create((Join-Path $Directory 'fixture.ico'))
    try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose() }
    $app = @{ name = 'GPU fixture'; publisher = 'Fixture'; scripts = @('gpu-fixture'); msi_upgrade_code = '{A2A70CD0-7E6B-4662-8174-324A5A961192}' }
    $wxs = New-PythonAppWxs -Bundle $bundle -App $app -Version '1.0.0' -IconPath (Join-Path $Directory 'fixture.ico') -Destination (Join-Path $Directory 'fixture.wxs')
    $msi = Join-Path $Directory 'payload.msi'
    & wix build -arch x64 -o $msi $wxs
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the text-only MSI fixture.' }
    Invoke-WithEnv -Vars @{ GPU_TEST_MSI = $msi } -Body {
        & python -I (Join-Path $repo 'shared/python/tests/test_windows_installer_payload_real.py')
        if ($LASTEXITCODE -ne 0) { throw 'The real MSI extraction fixture failed.' }
    }
}

Invoke-InTestDir -Prefix 'gpu-msi-fixture-' -Body {
    param($directory)
    $msi = Join-Path $directory 'size.msi'
    New-SizeFixture $msi
    Assert-FixtureSize $msi $AdditionalReader
    if ($IncludeRoundtrip) { Invoke-FixtureRoundtrip $directory }
}
Write-Host 'Windows MSI payload fixture passed without installing an app.'
