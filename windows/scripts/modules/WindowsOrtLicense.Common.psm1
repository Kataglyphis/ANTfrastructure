#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Copies the matching ORT wheel's texts; it does not inventory other native components.
# PYTHON_ORT_PROVIDER_WHEEL_API=1
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
    param([Parameter(Mandatory)][string]$OrtDll, [Parameter(Mandatory)][string]$WheelDir, [string[]]$ProviderDll = @(),
        [string]$PythonExtension = '', [string]$DirectMl = '')
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
        $providerNames = @{}
        foreach ($path in $ProviderDll) {
            $name = [IO.Path]::GetFileName($path)
            if ($name -notmatch '^onnxruntime_providers_[a-z0-9_]+\.dll$') { throw "Invalid ONNX Runtime provider DLL: $path" }
            if ($providerNames.ContainsKey($name)) { throw "Duplicate ONNX Runtime provider DLL name: $name" }
            $providerNames[$name] = $true
            $file = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($file.PSIsContainer -or $file.Length -le 0) { throw "ONNX Runtime provider DLL is empty or not a file: $path" }
            $entry = Get-OrtWheelEntry -Archive $archive -Name "onnxruntime/capi/$name"
            $providerHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
            if ((Get-WheelEntryHash -Entry $entry) -cne $providerHash) { throw "ORT provider '$path' differs from the matching wheel" }
        }
        if ($PythonExtension) {
            $file = Get-Item -LiteralPath $PythonExtension -ErrorAction Stop
            if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Name -cne 'onnxruntime_pybind11_state.pyd') {
                throw 'Python ONNX Runtime extension is missing, empty or has an unexpected name.'
            }
            $entry = Get-OrtWheelEntry -Archive $archive -Name 'onnxruntime/capi/onnxruntime_pybind11_state.pyd'
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            if ((Get-WheelEntryHash -Entry $entry) -cne $hash) { throw 'Python ONNX Runtime extension differs from the matching wheel.' }
        }
        if ($DirectMl) {
            $file = Get-Item -LiteralPath $DirectMl -ErrorAction Stop
            if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Name -cne 'DirectML.dll') {
                throw 'DirectML runtime is missing, empty or has an unexpected name.'
            }
            $entry = Get-OrtWheelEntry -Archive $archive -Name 'onnxruntime/capi/DirectML.dll'
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            if ((Get-WheelEntryHash -Entry $entry) -cne $hash) { throw 'DirectML runtime differs from the matching wheel.' }
        }
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
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ProviderDll = @(), [AllowEmptyString()][string]$DirectMlDll = ''
    )
    $texts = Get-OrtWheelLicenseTexts -OrtDll $OrtDll -WheelDir $WheelDir -ProviderDll $ProviderDll -DirectMl $DirectMlDll
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
    param([Parameter(Mandatory)][string]$Bundle, [AllowEmptyString()][string]$WheelDir = '', [string[]]$RequiredProvider = @(),
        [switch]$RequirePythonExtension, [switch]$RequireDirectMl)
    $dir = Join-Path $Bundle 'runtime/Lib/site-packages/onnxruntime'
    if (-not (Test-Path -LiteralPath $dir)) {
        if ($RequiredProvider.Count -or $RequirePythonExtension -or $RequireDirectMl) { throw 'Python ONNX Runtime is required when a provider or extension is selected.' }
        return ''
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Python ONNX Runtime is not a directory: $dir" }
    if (-not $WheelDir) { $WheelDir = if ($env:ORT_CHAIN_WHEEL_DIR) { $env:ORT_CHAIN_WHEEL_DIR } else { Get-OrtChainWheelStore } }
    $providers = @($RequiredProvider | ForEach-Object {
            if ($_ -cnotmatch '^[a-z0-9_]+$') { throw "Invalid Python ORT provider name: $_" }
            Join-Path $dir "capi/onnxruntime_providers_$_.dll"
        })
    $extension = if ($RequirePythonExtension) { Join-Path $dir 'capi/onnxruntime_pybind11_state.pyd' } else { '' }
    $directMl = if ($RequireDirectMl) { Join-Path $dir 'capi/DirectML.dll' } else { '' }
    $texts = Get-OrtWheelLicenseTexts -OrtDll (Join-Path $dir 'capi/onnxruntime.dll') -WheelDir $WheelDir -ProviderDll $providers -PythonExtension $extension -DirectMl $directMl
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
