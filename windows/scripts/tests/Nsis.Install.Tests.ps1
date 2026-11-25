#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: the SourceForge download, makensis itself or a built image; the wiring cases read source text only.
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsContainerImage.Common.psm1') -DisableNameChecking -ErrorAction Stop

Describe 'Install-Nsis: the pinned release zip' {
    foreach ($name in 'Get-NsisZipUrl', 'Get-NsisExtractedRoot', 'Install-Nsis') {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Install-Nsis.ps1' -FunctionName $name)
    }

    It 'builds SourceForge''s URL from a major.minor release and refuses any other shape' {
        Assert-Equal 'https://downloads.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13.zip' (Get-NsisZipUrl -Version '3.13')
        Assert-Equal 'https://mirror.example/nsis/NSIS%203/3.09/nsis-3.09.zip' (Get-NsisZipUrl -Version '3.09' -BaseUrl 'https://mirror.example/nsis/')
        foreach ($bad in '', 'v313', '3.13.1', '3.9') {
            Assert-Throws { Get-NsisZipUrl -Version $bad } -MessagePattern 'NSIS_VERSION must be a major\.minor'
        }
    }

    It 'accepts only the zip''s single nsis-<version> root with makensis, COPYING and the zlib stub' {
        $dir = New-TestDir -Prefix 'nsis-root-'
        try {
            $root = Join-Path $dir 'nsis-3.13'
            foreach ($file in 'Bin\makensis.exe', 'COPYING', 'Stubs\zlib-x86-unicode') {
                $null = New-Item -ItemType File -Force -Path (Join-Path $root $file)
            }
            Assert-Equal $root (Get-NsisExtractedRoot -StagingDir $dir -Version '3.13')
            Assert-Throws { Get-NsisExtractedRoot -StagingDir $dir -Version '3.12' } -MessagePattern "exactly one 'nsis-3\.12' directory"
            Remove-Item -LiteralPath (Join-Path $root 'COPYING')
            Assert-Throws { Get-NsisExtractedRoot -StagingDir $dir -Version '3.13' } -MessagePattern 'lacks COPYING'
            $null = New-Item -ItemType File -Path (Join-Path $root 'COPYING')
            $null = New-Item -ItemType File -Path (Join-Path $dir 'stray.txt')
            Assert-Throws { Get-NsisExtractedRoot -StagingDir $dir -Version '3.13' } -MessagePattern 'exactly one'
        } finally { Remove-TestDir -Path $dir }
    }

    It 'refuses a malformed pin and an existing install directory before any download' {
        $dir = New-TestDir -Prefix 'nsis-install-'
        try {
            Assert-Throws { Install-Nsis -TempDir $dir -NsisVersion '3.13' -ZipSha256 'abc' -InstallDir (Join-Path $dir 'n') } -MessagePattern 'NSIS_WINDOWS_ZIP_SHA256 must be a 64-hex'
            Assert-Throws { Install-Nsis -TempDir $dir -NsisVersion '3.13' -ZipSha256 ('a' * 64) -InstallDir $dir } -MessagePattern 'already exists; refusing'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $dir).Count 'nothing was downloaded or staged'
        } finally { Remove-TestDir -Path $dir }
    }
}

Describe 'Install-Nsis: final-stage wiring' {
    $script:root = Get-RepoRoot
    $script:finalDf = ConvertTo-TestDockerLogicalText -Text (Get-Content -Raw (Join-Path $script:root 'windows/Dockerfile'))

    It 'installs into C:\nsis with the installer and both module companions mounted per file' {
        $run = [regex]::Match($script:finalDf, "(?m)^RUN .*Install-Nsis\.ps1' -TempDir .*$").Value
        foreach ($source in 'windows/scripts/host/Install-Nsis.ps1', 'windows/scripts/modules/WindowsContainerImage.Common.psm1', 'windows/scripts/modules/WindowsScripts.Shared.psm1') {
            Assert-Match ([regex]::Escape("--mount=type=bind,source=$source,")) $run "the NSIS RUN mounts $source"
        }
        Assert-Match "-InstallDir 'C:\\nsis'\s*$" $run
    }

    It 'puts the pinned makensis first on PATH and points NSISDIR at its stubs' {
        Assert-Match '(?m)^ENV NSIS_VERSION=\$\{NSIS_VERSION\} .*NSISDIR=C:\\nsis .*PATH=C:\\nsis\\Bin;\$PATH' $script:finalDf
    }

    It 'receives both pins from the driver''s final stage' {
        $driver = Get-Content -Raw (Join-Path $script:root 'windows/Build-Buildkit.ps1')
        foreach ($key in 'NSIS_VERSION', 'NSIS_WINDOWS_ZIP_SHA256') {
            Assert-MatchCount 1 "$key\s+= Get-Ver '$key'" $driver "the driver forwards $key once"
        }
    }
}
