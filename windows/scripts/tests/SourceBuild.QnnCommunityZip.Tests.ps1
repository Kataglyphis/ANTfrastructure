#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Harness-style (no BeforeAll), so the Linux mutation shards can name it: Resolve-QnnSdk's fetched branch with a fetch the case hands in.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking

# New-QnnFetchCase <root>: a fake SDK zip (the harness writes the members), an empty drop dir and a cache dir; the zip's sha is the pin.
function New-QnnFetchCase {
    param([Parameter(Mandatory)][string]$Root)
    $zip = Join-Path $Root 'v2.34.0.zip'
    New-TestZipFile -Path $zip -Member ([ordered]@{
        'qairt/2.34.0/include/QNN/QnnInterface.h' = '// fake'
        'qairt/2.34.0/include/QNN/QnnOpDef.h' = 'QNN_OP_STFT'
        'qairt/2.34.0/lib/aarch64-windows-msvc/QnnCpu.dll' = 'fake'
    })
    $drop = New-Item (Join-Path $Root 'drop') -ItemType Directory -Force
    @{ Zip = $zip; Sha = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash; Drop = $drop.FullName; Cache = (Join-Path $Root 'cache'); Extract = (Join-Path $Root 'extract') }
}

# Resolve-QnnFetched <case> <source> <fetch> [sha] [version]: the resolver on the case's empty drop dir with the pin and the handed-in fetch.
function Resolve-QnnFetched {
    param([hashtable]$Case, [string]$Source, [scriptblock]$Fetch, [string]$Sha = $Case.Sha, [string]$Version = '2.34.0')
    Resolve-QnnSdk -DropDir $Case.Drop -ExpectedSha256 $Sha -ExtractDir $Case.Extract -Arch 'arm64' -Community @{ Version = $Version; CacheDir = $Case.Cache; Source = $Source; Fetch = $Fetch }
}

Describe 'Resolve-QnnSdk fetches the pinned Community zip' {
    It 'fetches into the cache dir when nothing is staged, reuses a verified zip and refetches a corrupt one' {
        $root = New-TestDir -Prefix 'wbt-qnnzip-'
        try {
            $c = New-QnnFetchCase -Root $root
            $script:fetched = @()
            $fetch = { param($Url, $Destination, $Sha) $script:fetched += $Url; Copy-Item $c.Zip $Destination }
            $r = Resolve-QnnFetched -Case $c -Source 'community' -Fetch $fetch
            Assert-True ($r.Home -like '*\qairt\2.34.0') 'the fetched zip resolves like a staged one'
            Assert-True ($script:fetched.Count -eq 1) 'one fetch'
            Assert-True ($script:fetched[0] -eq 'https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.34.0/v2.34.0.zip') 'the software center URL for that version'
            Assert-True (Test-Path (Join-Path $c.Cache 'qairt-2.34.0.zip')) 'the zip stays in the cache dir'
            $null = Resolve-QnnFetched -Case $c -Source 'community' -Fetch $fetch
            Assert-True ($script:fetched.Count -eq 1) 'a verified cached zip is not fetched again'
            Set-Content (Join-Path $c.Cache 'qairt-2.34.0.zip') 'corrupt'
            $null = Resolve-QnnFetched -Case $c -Source 'community' -Fetch $fetch
            Assert-True ($script:fetched.Count -eq 2) 'a cached zip that fails its sha is fetched again'
        } finally { Remove-TestDir -Path $root }
    }

    It 'fetches nothing without a pin or under QNN_SDK_SOURCE=drop, and refuses a version without its sha' {
        $root = New-TestDir -Prefix 'wbt-qnnzip-'
        try {
            $c = New-QnnFetchCase -Root $root
            $fetch = { throw 'must not fetch' }
            Assert-True ($null -eq (Resolve-QnnFetched -Case $c -Source 'community' -Fetch $fetch -Version '')) 'no pin -> QNN off'
            Assert-True ($null -eq (Resolve-QnnFetched -Case $c -Source 'drop' -Fetch $fetch)) 'drop keeps the staged-only contract'
            Assert-Throws { Resolve-QnnFetched -Case $c -Source 'community' -Fetch $fetch -Sha '' | Out-Null } 'a version without its sha must throw' -MessagePattern 'without QNN_SDK_ZIP_SHA256'
        } finally { Remove-TestDir -Path $root }
    }
}
