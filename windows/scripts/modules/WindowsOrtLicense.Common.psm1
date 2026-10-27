#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Copies the matching ORT wheel's texts; it does not inventory other native components.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WindowsOrtProvenance.Common.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsMsiLicense.Common.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsPythonWheel.Common.psm1') -DisableNameChecking -ErrorAction Stop

function Get-OrtWheelEntry {
    param([Parameter(Mandatory)]$Archive, [Parameter(Mandatory)][string]$Name)
    $entries = @($Archive.Entries | Where-Object { $_.FullName -ceq $Name })
    if ($entries.Count -ne 1) { throw "ORT wheel entry '$Name' matched $($entries.Count) entries; expected one" }
    if ($entries[0].Length -le 0) { throw "ORT wheel entry is empty: $Name" }
    return $entries[0]
}

function Get-OrtWheelEntryBytes {
    param([Parameter(Mandatory)]$Entry)
    $stream = $Entry.Open(); $buffer = [IO.MemoryStream]::new()
    try { $stream.CopyTo($buffer); return ,$buffer.ToArray() }
    finally { $buffer.Dispose(); $stream.Dispose() }
}

function Get-OrtWheelLicenseTexts {
    param([Parameter(Mandatory)][string]$OrtDll, [Parameter(Mandatory)][string]$WheelDir)
    $digest = (Get-FileHash -LiteralPath $OrtDll -Algorithm SHA256 -ErrorAction Stop).Hash
    $matchingWheels = [Collections.Generic.List[string]]::new()
    foreach ($wheel in @(Get-OrtChainWheel -WheelDir $WheelDir)) {
        $archive = [IO.Compression.ZipFile]::OpenRead($wheel)
        try {
            $dll = Get-OrtWheelEntry -Archive $archive -Name 'onnxruntime/capi/onnxruntime.dll'
            if ((Get-WheelEntryHash -Entry $dll) -ceq $digest) { $matchingWheels.Add($wheel) }
        } finally { $archive.Dispose() }
    }
    if ($matchingWheels.Count -ne 1) { throw "ORT DLL '$OrtDll' matched $($matchingWheels.Count) wheels in '$WheelDir'; expected one" }
    $texts = @{}
    $archive = [IO.Compression.ZipFile]::OpenRead($matchingWheels[0])
    try {
        foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
            $entry = Get-OrtWheelEntry -Archive $archive -Name "onnxruntime/$name"
            $texts[$name] = Get-OrtWheelEntryBytes -Entry $entry
            if ([string]::IsNullOrWhiteSpace([Text.Encoding]::UTF8.GetString($texts[$name]))) { throw "ORT wheel text is blank: $name" }
        }
    } finally { $archive.Dispose() }
    return $texts
}

function Copy-OrtWheelLicenses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrtDll,
        [Parameter(Mandatory)][string]$WheelDir,
        [Parameter(Mandatory)][string]$Destination
    )
    $texts = Get-OrtWheelLicenseTexts -OrtDll $OrtDll -WheelDir $WheelDir
    $dir = Join-Path $Destination 'licenses/onnxruntime'
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw "ORT license destination is not a directory: $Destination" }
    foreach ($path in @($Destination, (Join-Path $Destination 'licenses'), $dir)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "ORT license destination is a link: $path"
        }
    }
    $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop
    foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
        $target = Join-Path $dir $name
        $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "ORT license destination is a link: $target"
        }
        [IO.File]::WriteAllBytes($target, $texts[$name])
    }
    return $dir
}

function Resolve-PythonOrtLicenses {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Bundle, [AllowEmptyString()][string]$WheelDir = '')
    $dir = Join-Path $Bundle 'runtime/Lib/site-packages/onnxruntime'
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Python ONNX Runtime is not a directory: $dir" }
    if (-not $WheelDir) { $WheelDir = if ($env:ORT_CHAIN_WHEEL_DIR) { $env:ORT_CHAIN_WHEEL_DIR } else { Get-OrtChainWheelStore } }
    $texts = Get-OrtWheelLicenseTexts -OrtDll (Join-Path $dir 'capi/onnxruntime.dll') -WheelDir $WheelDir
    foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
        $path = Join-Path $dir $name
        $actual = [IO.File]::ReadAllBytes($path)
        if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($texts[$name])) { throw "Python ONNX Runtime text differs from matching wheel: $path" }
    }
    return $dir
}

function Get-OrtLicensePackageMember {
    param([string]$Format, [string]$WixPath, [string]$ArchivePrefix, [string]$ArchiveDirectory, [string]$Name, [string]$Source)
    switch ($Format) {
        'msi' {
            if (-not $WixPath) { throw 'WiX source is required for MSI license mapping' }
            return Get-WixSourceFileId -WixPath $WixPath -SourcePath $Source
        }
        'archive' { return (@($ArchivePrefix.Trim('/'), $ArchiveDirectory.Trim('/'), $Name) | Where-Object { $_ }) -join '/' }
        default { throw "unsupported ORT license package format: $Format" }
    }
}

function Assert-OrtWheelLicensesInPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LicenseDirectory,
        [Parameter(Mandatory)][ValidateSet('archive', 'msi')][string]$Format,
        [string]$WixPath = '',
        [string]$ArchivePrefix = '',
        [string]$ArchiveDirectory = 'licenses/onnxruntime'
    )
    foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
        $source = Join-Path $LicenseDirectory $name
        $member = Get-OrtLicensePackageMember -Format $Format -WixPath $WixPath -ArchivePrefix $ArchivePrefix -ArchiveDirectory $ArchiveDirectory -Name $name -Source $source
        Assert-PackageLicense -Path $Path -Pattern $member -LicensePath $source
    }
}

Export-ModuleMember -Function Copy-OrtWheelLicenses, Resolve-PythonOrtLicenses, Assert-OrtWheelLicensesInPackage
