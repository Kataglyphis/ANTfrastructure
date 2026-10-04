# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Guarded, no -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

function Resolve-ContainerImageValue {
    param(
        [AllowEmptyString()]
        [string]$Value = '',
        [string]$EnvironmentVariable = '',
        [AllowEmptyString()]
        [string]$DefaultValue = '',
        # Strip a leading 'v' from the resolved value, so every version gate trims tags the same way.
        [switch]$TrimVPrefix
    )

    $resolved = $DefaultValue

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $resolved = $Value
    } elseif (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
        $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
            $resolved = $environmentValue
        }
    }

    if ($TrimVPrefix -and $null -ne $resolved) {
        $resolved = ([string]$resolved).TrimStart('v')
    }

    return $resolved
}

# One probe for Install-Vs.ps1 and the smoke test, so they cannot disagree on the Program Files roots.
function Resolve-VsBuildToolsRoot {
    param(
        [string]$VsMajor = ''
    )

    if ([string]::IsNullOrWhiteSpace($VsMajor)) {
        $VsMajor = if ($env:VISUAL_STUDIO_VERSION) { $env:VISUAL_STUDIO_VERSION } else { '18' }
    }

    foreach ($programFiles in @('C:\Program Files', 'C:\Program Files (x86)')) {
        $candidate = Join-Path $programFiles ("Microsoft Visual Studio\{0}\BuildTools" -f $VsMajor)
        if (Test-Path (Join-Path $candidate 'Common7\Tools\VsDevCmd.bat')) {
            return $candidate
        }
    }

    return $null
}

function Initialize-ContainerImageTempDirectory {
    param(
        [string]$TempDir = 'C:\temp'
    )

    return (Resolve-DirectoryPath -Path $TempDir)
}

function Clear-PendingFileHandle {
    # Flushes installer-held handles before a layer commit; best-effort, since a spawn flake must never fail a build.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    try {
        & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c 'ver > nul' 2>&1 | Out-Null
    } catch {
        Write-Warning "Clear-PendingFileHandle: no-op child spawn failed ($($_.Exception.Message)) — continuing (best-effort flush)"
    }
    $global:LASTEXITCODE = 0
}

function Sync-ContainerProcessPath {
    param(
        [string[]]$AdditionalPaths = @()
    )

    $entries = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $addPathEntries = {
        param(
            [AllowEmptyString()]
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        foreach ($entry in $Value -split ';') {
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }

            $expandedEntry = [Environment]::ExpandEnvironmentVariables($entry.Trim())
            if ([string]::IsNullOrWhiteSpace($expandedEntry)) {
                continue
            }

            $normalizedEntry = $expandedEntry.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if ($seen.Add($normalizedEntry)) {
                $entries.Add($expandedEntry)
            }
        }
    }

    & $addPathEntries $env:PATH

    foreach ($scope in @([EnvironmentVariableTarget]::Machine, [EnvironmentVariableTarget]::User)) {
        & $addPathEntries ([Environment]::GetEnvironmentVariable('Path', $scope))
    }

    foreach ($path in $AdditionalPaths) {
        & $addPathEntries $path
    }

    $resolvedPath = $entries.ToArray() -join ';'
    [Environment]::SetEnvironmentVariable('Path', $resolvedPath, 'Process')
    $env:PATH = $resolvedPath

    return $resolvedPath
}

function Assert-ContainerCommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command not found on PATH: $Name"
    }

    return $command.Source
}

<#
.SYNOPSIS
    The family CI container image reference, composed from ANTfrastructure's versions.env.
.DESCRIPTION
    Twin of linux/scripts/ci-image-ref.sh. No -RepoRoot: the answer comes from the ANTfrastructure the caller imported.
    A missing key throws, as an empty ref fails far from the cause in `docker run`.
.PARAMETER Windows
    Compose the Windows image reference instead of the Linux one.
.PARAMETER TargetArch
    With -Windows, arm64 composes the arm64 cross bundle; refused without -Windows.
.PARAMETER VersionsEnvPath
    Override the versions.env location. For tests; leave unset in production.
.OUTPUTS
    [string] '<IMAGE_REGISTRY_PREFIX>:<tag>'; no sample here, as verify_ci_image_refs.py reads comments too.
#>
function Get-CiImageReference {
    param(
        [switch]$Windows,
        [ValidateSet('amd64', 'arm64')][string]$TargetArch = 'amd64',
        [string]$VersionsEnvPath = ''
    )
    if ($TargetArch -eq 'arm64' -and -not $Windows) { throw '-TargetArch arm64 needs -Windows: only Windows has an arm64 cross bundle' }

    if ([string]::IsNullOrWhiteSpace($VersionsEnvPath)) {
        $hubRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
        $VersionsEnvPath = Join-Path $hubRoot 'linux/scripts/01-core/versions.env'
    }

    if (-not (Test-Path -LiteralPath $VersionsEnvPath -PathType Leaf)) {
        throw ("ANTfrastructure versions.env not found at $VersionsEnvPath. " +
            'If the whole directory is missing, the submodule is not checked out: ' +
            'git submodule update --init --recursive third_party/ANTfrastructure')
    }

    $versions = ConvertFrom-VersionsEnv -Path $VersionsEnvPath
    $tagKey = if (-not $Windows) { 'CI_IMAGE_LINUX_TAG' } elseif ($TargetArch -eq 'arm64') { 'CI_IMAGE_WINDOWS_ARM64_TAG' } else { 'CI_IMAGE_WINDOWS_TAG' }

    foreach ($key in @('IMAGE_REGISTRY_PREFIX', $tagKey)) {
        if (-not $versions.Contains($key) -or [string]::IsNullOrWhiteSpace($versions[$key])) {
            throw ("$key is not set in $VersionsEnvPath. That file is the fleet-wide owner " +
                'of the CI image tags; a missing key means the ANTfrastructure pin predates ' +
                'the convention.')
        }
    }

    return ('{0}:{1}' -f $versions['IMAGE_REGISTRY_PREFIX'], $versions[$tagKey])
}

<#
.SYNOPSIS
    Extracts named files from LunarG's Runtime Components zip, flat, under a per-arch prefix.
.DESCRIPTION
    The x64 zip nests its binaries under x64\ beside an x86\ pair; the arm64 one keeps them at the
    component root. Each wanted name must match exactly one entry, or the caller gets a throw.
#>
function Expand-VulkanRuntimeComponents {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        # '' for the arm64 zip's component root; 'x64/' for the x64 zip's nested pair (never x86/).
        [AllowEmptyString()][string]$BinPrefix = '',
        [string[]]$BinNames = @('vulkan-1.dll')
    )
    $wanted = [ordered]@{}
    foreach ($name in $BinNames) { $wanted[$name] = ('(^|/)' + $BinPrefix + [regex]::Escape($name) + '$') }
    # The licence sits at the component root on both arches, never under the bin prefix.
    $wanted['VulkanRT-License.txt'] = '(^|/)VulkanRT-License\.txt$'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $plan = @(foreach ($name in $wanted.Keys) {
                $hits = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -match $wanted[$name] })
                if ($hits.Count -ne 1) {
                    throw "Expand-VulkanRuntimeComponents: $ZipPath holds $($hits.Count) entries matching $($wanted[$name]), expected exactly 1"
                }
                @{ Entry = $hits[0]; Name = $name }
            })
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        foreach ($p in $plan) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($p.Entry, (Join-Path $Destination $p.Name), $true)
        }
    } finally { $zip.Dispose() }
}

<#
.SYNOPSIS
    The mmozeiko/build-mesa release asset for an arch.
#>
function Get-LavapipeWindowsUrl {
    param([AllowEmptyString()][string]$Version, [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch)
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Get-LavapipeWindowsUrl: LAVAPIPE_VERSION must be an x.y.z release like 26.2.3; got '$Version'"
    }
    $suffix = if ($Arch -eq 'amd64') { 'x64' } else { 'arm64' }
    return "https://github.com/mmozeiko/build-mesa/releases/download/$Version/mesa-lavapipe-$suffix-$Version.7z"
}

<#
.SYNOPSIS
    LunarG's Runtime Components zip for an arch: x64 under `windows`, arm64 under `warm`.
#>
function Get-VulkanRuntimeComponentsUrl {
    param([AllowEmptyString()][string]$Version, [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch)
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Get-VulkanRuntimeComponentsUrl: VULKAN_VERSION must be a four-part LunarG SDK version like 1.4.357.0; got '$Version'"
    }
    if ($Arch -eq 'amd64') { return "https://sdk.lunarg.com/sdk/download/$Version/windows/VulkanRT-X64-$Version-Components.zip" }
    return "https://sdk.lunarg.com/sdk/download/$Version/warm/VulkanRT-ARM64-$Version-Components.zip"
}

<#
.SYNOPSIS
    The versions.env key holding a download's SHA256 for an arch.
#>
function Get-LavapipePinName {
    param([Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch, [Parameter(Mandatory)][ValidateSet('mesa', 'loader')][string]$Kind)
    if ($Kind -eq 'mesa') {
        # X64, not AMD64: the pin follows the release asset's spelling (mesa-lavapipe-x64-...).
        $suffix = if ($Arch -eq 'amd64') { 'X64' } else { 'ARM64' }
        return "LAVAPIPE_WINDOWS_${suffix}_SHA256"
    }
    if ($Arch -eq 'amd64') { return 'VULKAN_RT_WINDOWS_ZIP_SHA256' }
    return 'VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256'
}

<#
.SYNOPSIS
    Validates the lavapipe and loader pins and derives their URLs, ICD name and bin prefix for an arch.
#>
function Resolve-LavapipeAssets {
    param(
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MesaVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$VulkanVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MesaSha256,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LoaderSha256
    )
    foreach ($value in @($MesaVersion, $VulkanVersion, $MesaSha256, $LoaderSha256)) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'Resolve-LavapipeAssets: a pin is unset -- versions.env was not loaded' }
    }
    if ($MesaSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $LoaderSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Resolve-LavapipeAssets: the SHA256 pins must be 64 hex (see versions.env)'
    }
    return @{
        MesaUrl   = Get-LavapipeWindowsUrl -Version $MesaVersion -Arch $Arch
        LoaderUrl = Get-VulkanRuntimeComponentsUrl -Version $VulkanVersion -Arch $Arch
        IcdName   = if ($Arch -eq 'amd64') { 'lvp_icd.x86_64.json' } else { 'lvp_icd.aarch64.json' }
        BinPrefix = if ($Arch -eq 'amd64') { 'x64/' } else { '' }
    }
}

<#
.SYNOPSIS
    Unpacks a lavapipe 7z with the 7-Zip on PATH or in Program Files.
#>
function Expand-LavapipeArchive {
    param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$Destination)
    $sevenZip = @((Get-Command 7z -ErrorAction SilentlyContinue | ForEach-Object Source), "$env:ProgramFiles\7-Zip\7z.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $sevenZip) { throw 'Expand-LavapipeArchive: 7-Zip is needed to unpack lavapipe, and neither 7z on PATH nor Program Files\7-Zip has it' }
    & $sevenZip x -y "-o$Destination" $ArchivePath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Expand-LavapipeArchive: 7-Zip exited $LASTEXITCODE unpacking $ArchivePath" }
}

<#
.SYNOPSIS
    Reads the four lavapipe pins through a caller-supplied lookup (env vars in the image, versions.env on a host).
#>
function Get-LavapipePinValues {
    param(
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch,
        [Parameter(Mandatory)][scriptblock]$Lookup
    )
    $read = { param([string]$name) "$(& $Lookup $name)".Trim() }
    return @{
        MesaVersion   = & $read 'LAVAPIPE_VERSION'
        VulkanVersion = & $read 'VULKAN_VERSION'
        MesaSha256    = & $read (Get-LavapipePinName -Arch $Arch -Kind 'mesa')
        LoaderSha256  = & $read (Get-LavapipePinName -Arch $Arch -Kind 'loader')
    }
}

Export-ModuleMember -Function @(
    'Resolve-ContainerImageValue',
    'Resolve-VsBuildToolsRoot',
    'Initialize-ContainerImageTempDirectory',
    'Clear-PendingFileHandle',
    'Sync-ContainerProcessPath',
    'Assert-ContainerCommandAvailable',
    'Get-CiImageReference',
    'Expand-VulkanRuntimeComponents',
    'Get-LavapipeWindowsUrl',
    'Get-VulkanRuntimeComponentsUrl',
    'Get-LavapipePinName',
    'Resolve-LavapipeAssets',
    'Expand-LavapipeArchive',
    'Get-LavapipePinValues',
    # Re-exported from WindowsScripts.Shared, so one Import-Module suffices.
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    'ConvertFrom-VersionsEnv',
    'Expand-ArchiveSubdirectory'
)

