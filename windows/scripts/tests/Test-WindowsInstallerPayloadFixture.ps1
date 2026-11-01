#requires -Version 7.0
# A tiny Windows Installer database checks the real MSI file-size reader without installing an app.
param([string]$AdditionalReader = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parent = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath
$scratch = Join-Path $parent "gpu-msi-size-fixture-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $msi = Join-Path $scratch 'fixture.msi'
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($msi, 3)
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
    $reader = Join-Path $PSScriptRoot '../diagnostics/Get-MsiPayloadSize.ps1'
    $size = & $reader -MsiPath $msi
    if ($size -ne 595) { throw "Expected 595 fixture bytes, got $size." }
    if ($AdditionalReader -and (& $AdditionalReader -MsiPath $msi) -ne 595) {
        throw 'The consumer MSI size wrapper returned a different result.'
    }
    $failed = $false
    try { & $reader -MsiPath $msi -MaxBytes 594 | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'MSI size limit did not reject an oversized payload.' }
    Write-Host 'Windows MSI size fixture passed without installing an app.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
    $prefix = $parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture path: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}
