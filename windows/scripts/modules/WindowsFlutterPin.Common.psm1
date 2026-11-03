#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The Windows twin of 05-frameworks/flutter/flutter-pin.sh; a git checkout fits both Windows arches, so the commit is its pin, not the Linux tarball's sha.

Set-StrictMode -Version Latest

# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') }

<#
.SYNOPSIS
    Resolves the Flutter version and its release commit from the hub's pins.
.DESCRIPTION
    A caller's FLUTTER_VERSION wins as a named one-off with no commit, the flutter_resolve_pin rule.
#>
function Resolve-FlutterPin {
    param([string]$CoreDir = (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core'))
    $version = Get-ANTfrastructurePin -Name FLUTTER_VERSION -VersionsEnvPath (Join-Path $CoreDir 'versions.env')
    $commit = Get-ANTfrastructurePin -Name FLUTTER_COMMIT -VersionsEnvPath (Join-Path $CoreDir 'tool-pins.env')
    if ($env:FLUTTER_VERSION) {
        Write-Warning "FLUTTER_VERSION=$version overrides the pin; its commit is not checked."
        $commit = ''
    }
    return [pscustomobject]@{ Version = $version; Commit = $commit }
}

<#
.SYNOPSIS
    Clones the pinned Flutter tag and refuses a checkout that is not the pinned commit.
.OUTPUTS
    [string] The SDK's bin directory.
#>
function Install-PinnedFlutterSdk {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string]$RepositoryUrl = 'https://github.com/flutter/flutter.git',
        [string]$CoreDir = (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core')
    )
    $pin = Resolve-FlutterPin -CoreDir $CoreDir
    & git -c advice.detachedHead=false clone --depth 1 --branch $pin.Version -- $RepositoryUrl $Destination | Out-Host
    if ($LASTEXITCODE) { throw "cloning Flutter $($pin.Version) failed (exit $LASTEXITCODE)" }
    $head = (& git -C $Destination rev-parse HEAD)
    if ($LASTEXITCODE) { throw "reading the Flutter checkout's commit failed (exit $LASTEXITCODE)" }
    if ($pin.Commit -and $head -ne $pin.Commit) {
        throw "Flutter tag $($pin.Version) is $head, not the pinned FLUTTER_COMMIT $($pin.Commit)"
    }
    return (Join-Path $Destination 'bin')
}

Export-ModuleMember -Function Resolve-FlutterPin, Install-PinnedFlutterSdk
