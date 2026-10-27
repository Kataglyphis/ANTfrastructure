#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Maps a unique MSI File-table name to its cabinet identifier; it does not discover dependency obligations.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') -DisableNameChecking -ErrorAction Stop

function Clear-MsiLicenseComReference {
    param($Object)
    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object)
    }
}

function Invoke-WithMsiLicenseDatabase {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$Mode, [Parameter(Mandatory)][scriptblock]$Body,
        [object[]]$ArgumentList = @())
    $installer = $null; $database = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        $database = $installer.OpenDatabase($Path, $Mode)
        & $Body $database @ArgumentList
    } finally {
        try { Clear-MsiLicenseComReference $database }
        finally { Clear-MsiLicenseComReference $installer }
    }
}

function Invoke-MsiLicenseQuery {
    param($Database, [string]$Sql, [scriptblock]$ReadRecord)
    $view = $null; $record = $null
    try {
        $view = $Database.OpenView($Sql)
        $null = $view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            try { & $ReadRecord $record }
            finally { Clear-MsiLicenseComReference $record; $record = $null }
        }
    } finally {
        try { if ($null -ne $view) { $null = $view.Close() } }
        finally { try { Clear-MsiLicenseComReference $record } finally { Clear-MsiLicenseComReference $view } }
    }
}

function Get-MsiFileTable {
    param($Database, [string]$FileId = '')
    $sql = 'SELECT `File`, `FileName`, `Sequence` FROM `File`'
    if ($FileId) { $sql += ' WHERE `File` = ''{0}''' -f $FileId }
    Invoke-MsiLicenseQuery -Database $Database -Sql $sql -ReadRecord {
        param($record) [pscustomobject]@{ Id = $record.StringData(1); FileName = $record.StringData(2); Sequence = $record.IntegerData(3) }
    }
}

function Get-MsiLicenseFileRows {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-WithMsiLicenseDatabase -Path $Path -Mode 0 -Body {
        param($database)
        Get-MsiFileTable -Database $database
    }
}

function Assert-MsiLicenseFileId {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[A-Za-z_][A-Za-z0-9_.]*$') { throw "invalid MSI file identifier: $Id" }
}

function Resolve-MsiLicenseFileId {
    param([Parameter(Mandatory)][string]$FileName, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    if ($FileName -match '[\\/]' -or $FileName -in @('.', '..')) { throw "MSI file name must be a basename: $FileName" }
    $matchingRows = @($Rows | Where-Object {
        $names = @([string]$_.FileName -split '\|', 2)
        @($names | Where-Object { [string]::Equals($_, $FileName, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    })
    if ($matchingRows.Count -ne 1) { throw "MSI file name '$FileName' matched $($matchingRows.Count) rows; expected exactly one" }
    $id = [string]$matchingRows[0].Id
    Assert-MsiLicenseFileId -Id $id
    return $id
}

function Get-MsiLicenseFileId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FileName)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "MSI is not a file: $resolved" }
    return Resolve-MsiLicenseFileId -FileName $FileName -Rows @(Get-MsiLicenseFileRows -Path $resolved)
}

function Resolve-MsiCabinetPattern {
    param([Parameter(Mandatory)][string]$FileId, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Media)
    Assert-MsiLicenseFileId -Id $FileId
    $file = @($Files | Where-Object { $_.Id -ceq $FileId })
    if ($file.Count -ne 1 -or [int]$file[0].Sequence -le 0) { throw "MSI file id '$FileId' has no unique positive sequence" }
    $previousDisk = 0; $previousSequence = -1
    foreach ($row in @($Media | Sort-Object DiskId)) {
        if ([int]$row.DiskId -le $previousDisk -or [int]$row.LastSequence -le $previousSequence) { throw 'MSI media boundaries are ambiguous or unordered' }
        $previousDisk = [int]$row.DiskId; $previousSequence = [int]$row.LastSequence
    }
    $eligible = @($Media | Where-Object { [int]$_.LastSequence -ge [int]$file[0].Sequence } | Sort-Object DiskId)
    if ($eligible.Count -eq 0) { throw "MSI file id '$FileId' has no matching media" }
    $last = [int]$eligible[0].LastSequence
    $winner = @($eligible | Where-Object { [int]$_.LastSequence -eq $last })
    if ($winner.Count -ne 1) { throw "MSI file id '$FileId' has ambiguous media" }
    $cabinet = [string]$winner[0].Cabinet
    if ($cabinet -notmatch '^#[^\\/:*?\[\]\x00-\x1f]+\.cab$') { throw "MSI media is not a safe embedded cabinet: $cabinet" }
    return "$($cabinet.Substring(1))::$FileId"
}

function Get-MsiCabinetTables {
    param($Database, [string]$FileId)
    $files = @(Get-MsiFileTable -Database $Database -FileId $FileId)
    $media = @(Invoke-MsiLicenseQuery -Database $Database -Sql 'SELECT `DiskId`, `LastSequence`, `Cabinet` FROM `Media`' -ReadRecord {
        param($record) [pscustomobject]@{ DiskId = $record.IntegerData(1); LastSequence = $record.IntegerData(2); Cabinet = $record.StringData(3) }
    })
    return @{ Files = $files; Media = $media }
}

function Get-MsiCabinetPattern {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FileId)
    Assert-MsiLicenseFileId -Id $FileId
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    return Invoke-WithMsiLicenseDatabase -Path $resolved -Mode 0 -ArgumentList @($FileId) -Body {
        param($database, $id)
        $tables = Get-MsiCabinetTables -Database $database -FileId $id
        Resolve-MsiCabinetPattern -FileId $id -Files $tables.Files -Media $tables.Media
    }
}

function Get-WixSourceFileId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WixPath, [Parameter(Mandatory)][string]$SourcePath)
    $wix = (Resolve-Path -LiteralPath $WixPath -ErrorAction Stop).ProviderPath
    $source = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).ProviderPath)
    $document = Read-SafeXmlDocument -Path $wix -DtdPolicy Prohibit
    $matched = @($document.SelectNodes("//*[local-name()='File' and @Source]") | Where-Object {
        $candidate = $_.GetAttribute('Source')
        [IO.Path]::IsPathFullyQualified($candidate) -and
            [string]::Equals([IO.Path]::GetFullPath($candidate), $source, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matched.Count -ne 1) { throw "WiX source '$source' matched $($matched.Count) files; expected exactly one" }
    $row = [pscustomobject]@{ Id = $matched[0].GetAttribute('Id'); FileName = [IO.Path]::GetFileName($source) }
    return Resolve-MsiLicenseFileId -FileName $row.FileName -Rows @($row)
}

function Assert-PackageLicense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$LicensePath,
        [string]$PythonPath = 'python',
        [string]$VerifierPath = (Join-Path $PSScriptRoot '../../../linux/scripts/verify_package_license.py')
    )
    if (-not (Test-Path -LiteralPath $VerifierPath -PathType Leaf)) { throw "package license verifier is missing: $VerifierPath" }
    if ([IO.Path]::GetExtension($Path) -ieq '.msi') { $Pattern = Get-MsiCabinetPattern -Path $Path -FileId $Pattern }
    & $PythonPath $VerifierPath $Path --require "$Pattern=$LicensePath"
    if ($LASTEXITCODE -ne 0) { throw "package license verification failed for '$Pattern' (exit $LASTEXITCODE)" }
}

function Assert-MsiPackageLicense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$LicensePath,
        [string]$PythonPath = 'python',
        [string]$VerifierPath = (Join-Path $PSScriptRoot '../../../linux/scripts/verify_package_license.py')
    )
    $id = Get-MsiLicenseFileId -Path $Path -FileName $FileName
    Assert-PackageLicense -Path $Path -Pattern $id -LicensePath $LicensePath -PythonPath $PythonPath -VerifierPath $VerifierPath
}

Export-ModuleMember -Function Resolve-MsiLicenseFileId, Get-MsiLicenseFileId, Resolve-MsiCabinetPattern, Get-MsiCabinetPattern, Get-WixSourceFileId, Assert-PackageLicense, Assert-MsiPackageLicense
