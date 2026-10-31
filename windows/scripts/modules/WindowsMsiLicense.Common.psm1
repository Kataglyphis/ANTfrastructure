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
    $resolved = if ($Mode -eq 0) { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath } else { $Path }
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        $database = $installer.OpenDatabase($resolved, $Mode)
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

function Get-MsiInstalledPathTables {
    param($Database)
    $files = @(Invoke-MsiLicenseQuery -Database $Database -Sql 'SELECT `File`, `FileName`, `Component_` FROM `File`' -ReadRecord {
        param($record) [pscustomobject]@{ Id = $record.StringData(1); Name = $record.StringData(2); Component = $record.StringData(3) }
    })
    $components = @(Invoke-MsiLicenseQuery -Database $Database -Sql 'SELECT `Component`, `Directory_` FROM `Component`' -ReadRecord {
        param($record) [pscustomobject]@{ Id = $record.StringData(1); Directory = $record.StringData(2) }
    })
    $directories = @(Invoke-MsiLicenseQuery -Database $Database -Sql 'SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`' -ReadRecord {
        param($record) [pscustomobject]@{ Id = $record.StringData(1); Parent = $record.StringData(2); Name = $record.StringData(3) }
    })
    return @{ Files = $files; Components = $components; Directories = $directories }
}

function Get-MsiTargetLongName {
    param([Parameter(Mandatory)][string]$Name)
    $target = ($Name -split ':', 2)[0]
    $parts = @($target -split '\|', 2)
    $name = $parts[-1]
    if (-not $name -or $name -match '[\\/:*?\[\]<>"|\x00-\x1f]' -or $name -eq '..' -or
        ($name -ne '.' -and $name -match '[ .]$')) { throw "unsafe MSI target name: $Name" }
    return $name
}

function Get-MsiRowsById {
    param([object[]]$Rows, [string]$Kind, [switch]$DirectoryOnly)
    $byId = @{}
    foreach ($row in $Rows) {
        if (-not $row.Id -or $byId.ContainsKey($row.Id)) { throw "duplicate or empty MSI $Kind identifier" }
        $byId[$row.Id] = if ($DirectoryOnly) { [string]$row.Directory } else { $row }
    }
    return $byId
}

function Assert-MsiRootDirectory {
    param([hashtable]$Directories, [string]$RootDirectoryId, [string]$RootDirectoryName)
    Assert-MsiLicenseFileId -Id $RootDirectoryId
    if (-not $Directories.ContainsKey($RootDirectoryId)) { throw "missing MSI root directory: $RootDirectoryId" }
    $rootName = Get-MsiTargetLongName -Name $Directories[$RootDirectoryId].Name
    if ($RootDirectoryName -and -not [string]::Equals($rootName, $RootDirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "MSI root directory '$RootDirectoryId' names '$rootName', expected '$RootDirectoryName'"
    }
}

function Get-MsiInstalledPath {
    param([string]$Leaf, [string]$DirectoryId, [hashtable]$Directories, [string]$RootDirectoryId)
    $path = @($Leaf); $visited = @{}; $dir = $DirectoryId; $underRoot = $false
    while ($dir) {
        if ($visited.ContainsKey($dir) -or -not $Directories.ContainsKey($dir)) { throw "cyclic or missing MSI directory: $dir" }
        $visited[$dir] = $true
        $node = $Directories[$dir]
        if ($RootDirectoryId -and [string]::Equals($dir, $RootDirectoryId, [StringComparison]::OrdinalIgnoreCase)) {
            $underRoot = $true
            break
        }
        $name = Get-MsiTargetLongName -Name $node.Name
        if ($name -ne '.') { $path = @($name) + $path }
        $dir = [string]$node.Parent
    }
    if ($RootDirectoryId -and -not $underRoot) { return $null }
    return $path -join '/'
}

function Resolve-MsiInstalledFileId {
    <#
    .SYNOPSIS
        Maps a unique relative installed path to its MSI File-table identifier.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Components, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Directories,
        [string]$RootDirectoryId = '', [string]$RootDirectoryName = '')
    $relative = $RelativePath.Replace('\', '/')
    if ($relative -match '(^/|//|(^|/)\.{1,2}(/|$)|[:*?\[\]<>"|\x00-\x1f]|[ .](/|$))' -or $relative.EndsWith('/')) { throw "unsafe MSI relative path: $RelativePath" }
    $componentById = Get-MsiRowsById -Rows $Components -Kind 'component'
    $directoryById = Get-MsiRowsById -Rows $Directories -Kind 'directory'
    if ($RootDirectoryName -and -not $RootDirectoryId) { throw 'MSI root directory name requires a root directory identifier' }
    if ($RootDirectoryId) {
        Assert-MsiRootDirectory -Directories $directoryById -RootDirectoryId $RootDirectoryId -RootDirectoryName $RootDirectoryName
    }
    $matchedIds = @()
    foreach ($file in $Files) {
        if ($file.Name -match ':') { throw "unsafe MSI file name: $($file.Name)" }
        $leaf = Get-MsiTargetLongName -Name $file.Name
        if (-not [string]::Equals($leaf, ($relative -split '/')[-1], [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $componentById.ContainsKey($file.Component)) { throw "missing MSI component: $($file.Component)" }
        $installed = Get-MsiInstalledPath -Leaf $leaf -DirectoryId ([string]$componentById[$file.Component].Directory) `
            -Directories $directoryById -RootDirectoryId $RootDirectoryId
        if ($null -eq $installed) { continue }
        if ([string]::Equals($installed, $relative, [StringComparison]::OrdinalIgnoreCase) -or (-not $RootDirectoryId -and
            $installed.EndsWith("/$relative", [StringComparison]::OrdinalIgnoreCase))) {
            Assert-MsiLicenseFileId -Id $file.Id
            $matchedIds += $file.Id
        }
    }
    if ($matchedIds.Count -ne 1) { throw "MSI installed path '$RelativePath' matched $($matchedIds.Count) rows; expected exactly one" }
    return $matchedIds[0]
}

function Get-MsiInstalledFileId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RelativePath,
        [string]$RootDirectoryId = '', [string]$RootDirectoryName = '')
    return Invoke-MsiInstalledPathQuery -Path $Path -Target $RelativePath -RootDirectoryId $RootDirectoryId -RootDirectoryName $RootDirectoryName
}

function Resolve-MsiDirectoryFileNames {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Directory = '', [Parameter(Mandatory)][string]$RootDirectoryId,
        [string]$RootDirectoryName = '', [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Components, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Directories)
    if ($Directory -match '(^/|//|(^|/)\.{1,2}(/|$)|[:*?\[\]<>"|\x00-\x1f\\]|[ .](/|$))' -or $Directory.EndsWith('/')) {
        throw "unsafe MSI relative directory: $Directory"
    }
    Assert-MsiLicenseFileId -Id $RootDirectoryId
    $byId = Get-MsiRowsById -Rows $Directories -Kind 'directory'
    Assert-MsiRootDirectory -Directories $byId -RootDirectoryId $RootDirectoryId -RootDirectoryName $RootDirectoryName
    $dir = $RootDirectoryId
    foreach ($segment in @($Directory -split '/' | Where-Object { $_ })) {
        $children = @($Directories | Where-Object {
                $_.Parent -eq $dir -and [string]::Equals((Get-MsiTargetLongName -Name $_.Name), $segment, [StringComparison]::OrdinalIgnoreCase)
            })
        if ($children.Count -ne 1) { throw "MSI directory '$segment' matched $($children.Count) rows under '$dir'; expected one" }
        if ((Get-MsiTargetLongName -Name $children[0].Name) -cne $segment) { throw "MSI directory case differs: $segment" }
        $dir = [string]$children[0].Id
    }
    $componentIds = Get-MsiRowsById -Rows $Components -Kind 'component' -DirectoryOnly
    foreach ($file in $Files) {
        if (-not $componentIds.ContainsKey($file.Component)) { throw "missing MSI component: $($file.Component)" }
        if ($componentIds[$file.Component] -ne $dir) { continue }
        if ($file.Name -match ':') { throw "unsafe MSI file name: $($file.Name)" }
        Get-MsiTargetLongName -Name $file.Name
    }
}

function Get-MsiDirectoryFileNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Directory = '',
        [Parameter(Mandatory)][string]$RootDirectoryId, [string]$RootDirectoryName = '')
    return Invoke-MsiInstalledPathQuery -Path $Path -Target $Directory -RootDirectoryId $RootDirectoryId -RootDirectoryName $RootDirectoryName -DirectoryQuery
}

function Invoke-MsiInstalledPathQuery {
    param([string]$Path, [AllowEmptyString()][string]$Target, [string]$RootDirectoryId, [string]$RootDirectoryName, [switch]$DirectoryQuery)
    return Invoke-WithMsiLicenseDatabase -Path $Path -Mode 0 -ArgumentList @($Target, $RootDirectoryId, $RootDirectoryName, [bool]$DirectoryQuery) -Body {
        param($database, $target, $rootId, $rootName, $isDirectory)
        $tables = Get-MsiInstalledPathTables -Database $database
        if ($isDirectory) {
            Resolve-MsiDirectoryFileNames -Directory $target -RootDirectoryId $rootId -RootDirectoryName $rootName -Files $tables.Files -Components $tables.Components -Directories $tables.Directories
        } else {
            Resolve-MsiInstalledFileId -RelativePath $target -Files $tables.Files -Components $tables.Components -Directories $tables.Directories -RootDirectoryId $rootId -RootDirectoryName $rootName
        }
    }
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
    return Invoke-WithMsiLicenseDatabase -Path $Path -Mode 0 -ArgumentList @($FileId) -Body {
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

function Get-MsiLicenseBatchPatterns {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Names, [switch]$FileNames)
    return Invoke-WithMsiLicenseDatabase -Path $Path -Mode 0 -ArgumentList @($Names, [bool]$FileNames) -Body {
        param($database, $items, $useNames)
        $tables = Get-MsiCabinetTables -Database $database -FileId ''
        foreach ($item in $items) {
            $id = if ($useNames) { Resolve-MsiLicenseFileId -FileName $item -Rows $tables.Files } else { $item }
            Resolve-MsiCabinetPattern -FileId $id -Files $tables.Files -Media $tables.Media
        }
    }
}

function Get-PackageVerifierMembers {
    param([string]$Path, [string[]]$Members, [switch]$Binary, [switch]$MsiFileNames)
    $isMsi = [IO.Path]::GetExtension($Path) -ieq '.msi'
    if ($MsiFileNames -and -not $isMsi) { throw 'MSI file-name mapping requires an MSI package.' }
    if (-not $isMsi) { return $Members }
    if ($Binary) { return @($Members | ForEach-Object { Get-MsiCabinetPattern -Path $Path -FileId $_ }) }
    return Get-MsiLicenseBatchPatterns -Path $Path -Names $Members -FileNames:$MsiFileNames
}

function Invoke-PackageVerifier {
    param([hashtable]$Request, [switch]$Binary, [switch]$MsiFileNames)
    $path = $Request.Path; $members = $Request.Member; $sources = $Request.Source
    $verifier = $Request.VerifierPath
    $kind = if ($Binary) { 'binary' } else { 'license' }
    if ($Binary -and -not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw "package $kind verifier is missing: $verifier" }
    if ($members.Count -eq 0 -or $members.Count -ne $sources.Count) {
        if ($Binary) { throw 'package binary members and sources must have equal, nonzero counts' }
        throw 'Package license patterns and source paths must have equal, nonzero counts.'
    }
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw "package $kind verifier is missing: $verifier" }
    $mapped = @(Get-PackageVerifierMembers -Path $path -Members $members -Binary:$Binary -MsiFileNames:$MsiFileNames)
    $rules = @(for ($i = 0; $i -lt $mapped.Count; $i++) { '--require'; "$($mapped[$i])=$($sources[$i])" })
    $options = @(if ($Binary) { '-I' })
    & $Request.PythonPath @options $verifier $path @rules
    if ($LASTEXITCODE -ne 0) {
        $failure = if ($Binary) { "package binary verification failed for '$($members -join ', ')'" } else { 'package license batch verification failed' }
        throw "$failure (exit $LASTEXITCODE)"
    }
}

function Invoke-PackageLicenseBatch {
    param([string]$Path, [string[]]$Pattern, [string[]]$LicensePath, [string]$PythonPath, [string]$VerifierPath, [switch]$MsiFileNames)
    $request = @{ Path = $Path; Member = $Pattern; Source = $LicensePath; PythonPath = $PythonPath; VerifierPath = $VerifierPath }
    Invoke-PackageVerifier -Request $request -MsiFileNames:$MsiFileNames
}

function Assert-PackageLicenses {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Pattern,
        [Parameter(Mandatory)][string[]]$LicensePath, [string]$PythonPath = 'python',
        [string]$VerifierPath = (Join-Path $PSScriptRoot '../../../linux/scripts/verify_package_license.py'))
    Invoke-PackageLicenseBatch -Path $Path -Pattern $Pattern -LicensePath $LicensePath -PythonPath $PythonPath -VerifierPath $VerifierPath
}

function Assert-MsiPackageLicenses {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$FileName,
        [Parameter(Mandatory)][string[]]$LicensePath, [string]$PythonPath = 'python',
        [string]$VerifierPath = (Join-Path $PSScriptRoot '../../../linux/scripts/verify_package_license.py'))
    Invoke-PackageLicenseBatch -Path $Path -Pattern $FileName -LicensePath $LicensePath -PythonPath $PythonPath -VerifierPath $VerifierPath -MsiFileNames
}

Export-ModuleMember -Function Resolve-MsiLicenseFileId, Get-MsiLicenseFileId, Resolve-MsiInstalledFileId, Get-MsiInstalledFileId, Resolve-MsiDirectoryFileNames, Get-MsiDirectoryFileNames, Resolve-MsiCabinetPattern, Get-MsiCabinetPattern, Get-WixSourceFileId, Assert-PackageLicense, Assert-MsiPackageLicense, Assert-PackageLicenses, Assert-MsiPackageLicenses, Invoke-PackageVerifier
