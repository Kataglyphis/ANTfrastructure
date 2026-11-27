#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Carries an image build's source offer into a package and proves it there; see docs/consumer-image-contract.md § The FFmpeg source offer

Set-StrictMode -Version Latest
foreach ($sibling in 'WindowsNativeProvenance.Common', 'WindowsMsiLicense.Common') {
    Import-Module (Join-Path $PSScriptRoot "$sibling.psm1") -DisableNameChecking -ErrorAction Stop
}

# Where a notice lands in the bundle: licences keep their licenses\<component> path, the offer files go to licenses\<owner>-source.
function Get-SourceOfferTarget {
    param([string]$Notice, [string]$Owner)
    $parts = @($Notice -split '[\\/]')
    if ($parts[0] -ieq 'licenses') { return ($parts -join '\') }
    return "licenses\$Owner-source\$($parts[-1])"
}

<#
.SYNOPSIS
    The notices a bundle owes for the owner's binaries it carries, as bundle-relative target -> image path.
.OUTPUTS
    $null when the image predates the offer (no manifest); an empty table when the bundle carries none of the binaries.
#>
function Get-NativeSourceOfferPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][string]$Bundle)
    $manifest = Join-Path $Root "provenance\$Owner.json"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $null }
    $carried = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Get-ChildItem -LiteralPath $Bundle -Recurse -File | ForEach-Object { [void]$carried.Add($_.Name) }
    $plan = [ordered]@{}
    $entries = @((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).entries)
    foreach ($entry in @($entries | Where-Object { $carried.Contains((Split-Path -Leaf $_.file)) })) {
        foreach ($notice in @($entry.notices.path)) { $plan[(Get-SourceOfferTarget -Notice $notice -Owner $Owner)] = Join-Path $Root $notice }
    }
    return $plan
}

# The plan a bundle owes, or $null after a warning when the image predates the offer: the one rule both entry points share.
function Get-OwedSourceOffer {
    param([string]$Root, [string]$Owner, [string]$Bundle, [string]$Indicator)
    $plan = Get-NativeSourceOfferPlan -Root $Root -Owner $Owner -Bundle $Bundle
    if ($null -ne $plan) { return $plan }
    if (@(Get-ChildItem -LiteralPath $Bundle -Recurse -File -Filter $Indicator -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Warning "the bundle carries $Indicator, but the image has no $Owner source offer under $Root (it predates it): this package ships $Owner without its licence texts until the image is rebuilt"
    }
    return $null
}

<#
.SYNOPSIS
    Copies into -Bundle the licence texts and offer the image ships for the owner's binaries the bundle carries; returns the targets.
.PARAMETER Indicator
    A file pattern that marks the owner's binaries when the image predates the offer, which is then a warning, not a failure.
#>
function Copy-NativeSourceOffer {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)][string]$Indicator)
    $plan = Get-OwedSourceOffer -Root $Root -Owner $Owner -Bundle $Bundle -Indicator $Indicator
    # An empty table is truthy, so the count decides.
    if ($null -eq $plan -or $plan.Count -eq 0) { return [string[]]@() }
    # The image's texts are copied only once their manifest still holds them.
    Assert-NativeProvenanceManifest -Path (Join-Path $Root "provenance\$Owner.json") -Root $Root
    return [string[]]@(foreach ($target in $plan.Keys) {
            $destination = Join-Path $Bundle $target
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination)
            Copy-Item -LiteralPath $plan[$target] -Destination $destination -Force
            $target
        })
}

<#
.SYNOPSIS
    Fails a finished package built from -Bundle that carries the owner's binaries without every text and offer file byte-equal to the image's.
.PARAMETER Offer
    Copy-NativeSourceOffer's arguments as one table: Root, Owner, Bundle and Indicator.
.PARAMETER Format
    archive (ZIP or MSIX, members under -ArchivePrefix) or msi (each member mapped through -WixPath).
#>
function Assert-PackageSourceOffer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Offer, [ValidateSet('archive', 'msi')][string]$Format = 'archive',
        [string]$ArchivePrefix = '', [string]$WixPath = '', [string]$PythonPath = 'python')
    $Owner = $Offer.Owner; $Bundle = $Offer.Bundle
    $owed = Get-OwedSourceOffer -Root $Offer.Root -Owner $Owner -Bundle $Bundle -Indicator $Offer.Indicator
    if (-not ($owed -and $owed.Count)) { return }
    $plan = $owed
    $absent = [Collections.Generic.List[string]]::new()
    foreach ($target in $plan.Keys) { if (-not [IO.File]::Exists((Join-Path $Bundle $target))) { $absent.Add($target) } }
    if ($absent.Count) { throw "the bundle carries $Owner but lacks $([string]::Join(', ', $absent)); run Copy-NativeSourceOffer before packaging" }
    if ($Format -eq 'msi' -and -not $WixPath) { throw 'an MSI source offer check needs -WixPath' }
    $members = @(foreach ($target in $plan.Keys) {
            if ($Format -eq 'msi') { Get-WixSourceFileId -WixPath $WixPath -SourcePath (Join-Path $Bundle $target) }
            else { (@($ArchivePrefix.Trim('/')) + @($target -split '\\') | Where-Object { $_ }) -join '/' }
        })
    Assert-PackageLicenses -Path $Path -Pattern $members -LicensePath @($plan.Values) -PythonPath $PythonPath
}

<#
.SYNOPSIS
    Copies the exact sources, build scripts and patches the -Offer bundle owes into -Destination for the release; returns their names.
.DESCRIPTION
    Each copy is checked against the SHA-256 its offer records. <owner>-sources.json goes beside them, so the release
    collector can prove the set complete (collect-release-assets.sh, check-source-offer.py).
#>
function Export-NativeSourceArchive {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Offer, [Parameter(Mandatory)][string]$Destination)
    # The copy and the package check already warned for an image that predates the offer.
    $plan = Get-NativeSourceOfferPlan -Root $Offer.Root -Owner $Offer.Owner -Bundle $Offer.Bundle
    if (-not $plan -or -not $plan.Count) { return [string[]]@() }
    $listing = Join-Path $Offer.Root "share\sources\$($Offer.Owner)\sources.json"
    $record = Get-Content -LiteralPath $listing -Raw | ConvertFrom-Json
    $null = New-Item -ItemType Directory -Force -Path $Destination
    $names = [Collections.Generic.List[string]]::new()
    foreach ($row in @($record.sources) + @($record.build)) {
        $leaf = Split-Path -Leaf $row.file
        $copy = Join-Path $Destination $leaf
        Copy-Item -LiteralPath (Join-Path $Offer.Root $row.file) -Destination $copy -Force
        if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ine $row.sha256) { throw "$leaf is not the $($Offer.Owner) source its offer records" }
        $names.Add($leaf)
    }
    $index = "$($Offer.Owner)-sources.json"
    Copy-Item -LiteralPath $listing -Destination (Join-Path $Destination $index) -Force
    $names.Add($index)
    return [string[]]$names
}

Export-ModuleMember -Function Get-NativeSourceOfferPlan, Copy-NativeSourceOffer, Assert-PackageSourceOffer, Export-NativeSourceArchive
