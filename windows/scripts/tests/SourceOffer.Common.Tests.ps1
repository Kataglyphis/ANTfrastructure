#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: an MSI (WiX) or MSIX package and a real image; a ZIP of a fake bundle stands in, read by the real Python verifier.
'WindowsSourceOffer.Build', 'WindowsSourceOffer.Common' | ForEach-Object {
    Import-Module (Join-Path (Get-RepoRoot) "windows/scripts/modules/$_.psm1") -Force -DisableNameChecking
}
Import-Module (Join-Path $PSScriptRoot 'WindowsSourceOffer.Fixture.psm1') -Force -DisableNameChecking

# Linux runners name the interpreter python3.
$script:offerPython = @(Get-Command python, python3 -CommandType Application -ErrorAction SilentlyContinue)[0].Source

# An image prefix with a published offer, and a bundle under -Dir whose cv2\bin holds -Binary.
function New-OfferBundleCase {
    param([Parameter(Mandatory)][string]$Dir, [string]$Binary = 'avcodec-63.dll', [switch]$Unpublished)
    $offer = New-SourceOfferFixture -Dir (Join-Path $Dir 'image')
    if (-not $Unpublished) { $null = Publish-NativeSourceOffer @offer }
    $bundle = Join-Path $Dir 'stage\app-1.0'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'runtime\Lib\site-packages\cv2\bin')
    Set-Content -LiteralPath (Join-Path $bundle "runtime\Lib\site-packages\cv2\bin\$Binary") -Value 'MZ copy'
    return @{ Gate = @{ Root = $offer.Root; Owner = 'ffmpeg'; Bundle = $bundle; Indicator = 'avcodec-*.dll' }; Stage = (Join-Path $Dir 'stage') }
}

function New-OfferZip {
    param([Parameter(Mandatory)][hashtable]$Case, [Parameter(Mandatory)][string]$Name)
    $zip = Join-Path (Split-Path $Case.Stage -Parent) $Name
    [IO.Compression.ZipFile]::CreateFromDirectory($Case.Stage, $zip)
    return $zip
}

Describe 'Copy-NativeSourceOffer and Assert-PackageSourceOffer: FFmpeg ships with its texts' {
    It 'copies the texts and the offer for the carried DLLs and proves them in the package' {
        Invoke-InTestDir { param($dir)
            $case = New-OfferBundleCase -Dir $dir
            $copy = $case.Gate
            $targets = @(Copy-NativeSourceOffer @copy)
            $want = 'licenses\ffmpeg\COPYING.GPLv3', 'licenses\x264\COPYING.GPLv3', 'licenses\ffmpeg-source\sources.json', 'licenses\ffmpeg-source\SOURCE-OFFER.txt'
            Assert-Equal 0 @(Compare-Object -ReferenceObject $want -DifferenceObject $targets).Count 'every text and the offer land under licenses'
            $zip = New-OfferZip -Case $case -Name 'good.zip'
            Assert-PackageSourceOffer -Offer $copy -Path $zip -ArchivePrefix 'app-1.0' -PythonPath $script:offerPython *> $null

            Set-Content -LiteralPath (Join-Path $copy.Bundle 'licenses\x264\COPYING.GPLv3') -Value 'edited after the copy'
            $edited = New-OfferZip -Case $case -Name 'edited.zip'
            Assert-Throws { Assert-PackageSourceOffer -Offer $copy -Path $edited -ArchivePrefix 'app-1.0' -PythonPath $script:offerPython *> $null } -MessagePattern 'verification failed'
            Remove-Item -LiteralPath (Join-Path $copy.Bundle 'licenses\ffmpeg-source\SOURCE-OFFER.txt')
            Assert-Throws { Assert-PackageSourceOffer -Offer $copy -Path $zip -ArchivePrefix 'app-1.0' -PythonPath $script:offerPython } -MessagePattern 'lacks licenses\\ffmpeg-source\\SOURCE-OFFER\.txt'
        }
    }

    It 'owes nothing without the DLLs, warns for an image that predates the offer, and refuses changed image texts' {
        Invoke-InTestDir { param($dir)
            $none = (New-OfferBundleCase -Dir (Join-Path $dir 'none') -Binary 'opencv_world.dll').Gate
            Assert-Equal 0 @(Copy-NativeSourceOffer @none).Count 'a bundle without FFmpeg owes no text'
            Assert-PackageSourceOffer -Offer $none -Path (Join-Path $dir 'unused.zip')

            $old = (New-OfferBundleCase -Dir (Join-Path $dir 'old') -Unpublished).Gate
            $copied = @(Copy-NativeSourceOffer @old -WarningVariable copyWarning -WarningAction SilentlyContinue)
            Assert-Equal 0 $copied.Count 'nothing to copy from an image without the offer'
            Assert-Match 'predates it' ($copyWarning -join ' ')
            Assert-PackageSourceOffer -Offer $old -Path (Join-Path $dir 'unused.zip') -WarningVariable gateWarning -WarningAction SilentlyContinue
            Assert-Match 'until the image is rebuilt' ($gateWarning -join ' ')

            $tampered = (New-OfferBundleCase -Dir (Join-Path $dir 'tampered')).Gate
            Set-Content -LiteralPath (Join-Path $tampered.Root 'licenses\x264\COPYING.GPLv3') -Value 'not the shipped text'
            Assert-Throws { Copy-NativeSourceOffer @tampered } -MessagePattern 'fails:'
            Assert-Throws { Assert-PackageSourceOffer -Offer $tampered -Path (Join-Path $dir 'unused.zip') -Format msi } -MessagePattern 'lacks|needs -WixPath'
        }
    }
}
