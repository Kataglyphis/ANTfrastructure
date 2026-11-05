#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# A fake zip with the SDK's layout exercises the staged and the fetched branch; the fetch is a scriptblock the tests hand in.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking

Describe 'Resolve-QnnSdk' {

    BeforeAll {
        $script:tmp = New-TestDir -Prefix 'wbt-qnn-'
        $script:drop = Join-Path $script:tmp 'drop'
        $script:extract = Join-Path $script:tmp 'extract'
        New-Item -Path $script:drop -ItemType Directory -Force | Out-Null
        # Build the fake SDK tree, zip it.
        $sdk = Join-Path $script:tmp 'sdk\qairt\2.34.0'
        Write-TestFileTree -Root $sdk -Files @{
            'include/QNN/QnnInterface.h' = '// fake'; 'lib/aarch64-windows-msvc/QnnCpu.dll' = 'fake'
            'lib/aarch64-windows-msvc/QnnHtp.dll' = 'fake'; 'lib/hexagon-v73/unsigned/libQnnHtpV73Skel.so' = 'fake'
        }
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $sdk 'lib/x86_64-windows-msvc')
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:zip = Join-Path $script:drop 'v2.34.0.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $script:tmp 'sdk'), $script:zip)
        $script:sha = (Get-FileHash -Algorithm SHA256 -Path $script:zip).Hash
        # The fetched branch, parameterised: an empty drop dir and a cache dir per case, the pin and a fetch the case hands in.
        function script:New-FetchCase {
            param([string]$Name)
            $drop = Join-Path $script:tmp "empty-$Name"; New-Item $drop -ItemType Directory -Force | Out-Null
            @{ Drop = $drop; Cache = (Join-Path $script:tmp "cache-$Name") }
        }
        function script:Resolve-FetchedFixture {
            param([hashtable]$Case, [string]$Source, [scriptblock]$Fetch, [string]$Sha = $script:sha)
            Resolve-QnnSdk -DropDir $Case.Drop -ExpectedSha256 $Sha -ExtractDir $script:extract -Arch 'arm64' -Community @{ Version = '2.34.0'; CacheDir = $Case.Cache; Source = $Source; Fetch = $Fetch }
        }
    }
    AfterAll { Remove-TestDir -Path $script:tmp }

    It 'returns $null when no zip is staged (the default state)' {
        $empty = Join-Path $script:tmp 'empty'; New-Item $empty -ItemType Directory -Force | Out-Null
        Assert-True ($null -eq (Resolve-QnnSdk -DropDir $empty -ExtractDir $script:extract -Arch 'arm64')) 'no zip -> $null, no throw'
    }

    It 'resolves the SDK root, the target backend dir and the two cmake switches (arm64)' {
        $r = Resolve-QnnSdk -DropDir $script:drop -ExpectedSha256 $script:sha -ExtractDir $script:extract -Arch 'arm64'
        Assert-True ($r.Home -like '*\qairt\2.34.0') "home is the version dir (got $($r.Home))"
        Assert-True ($r.LibDir -like '*\lib\aarch64-windows-msvc') 'target backend dir'
        Assert-True ($r.CmakeArgs -contains '-Donnxruntime_USE_QNN=ON') 'USE_QNN switch'
        Assert-True (($r.CmakeArgs | Where-Object { $_ -like '-Donnxruntime_QNN_HOME=*/qairt/2.34.0' }) -ne $null) 'QNN_HOME with forward slashes'
    }

    It 'throws on a SHA mismatch and on a missing backend set for the target' {
        Assert-Throws { Resolve-QnnSdk -DropDir $script:drop -ExpectedSha256 ('0' * 64) -ExtractDir $script:extract -Arch 'arm64' | Out-Null } 'hash mismatch must throw' -MessagePattern 'SHA256 mismatch'
        Assert-Throws { Resolve-QnnSdk -DropDir $script:drop -ExpectedSha256 $script:sha -ExtractDir $script:extract -Arch 'amd64' | Out-Null } 'the fake SDK has no x86_64 QnnCpu.dll -> amd64 must throw' -MessagePattern 'QnnCpu\.dll missing'
    }

    It 'fetches the pinned Community zip into the cache dir when nothing is staged, and reuses a verified one' {
        $c = New-FetchCase 'fetch'
        $script:fetched = @()
        $fetch = { param($Url, $Destination, $Sha) $script:fetched += $Url; Copy-Item $script:zip $Destination }
        $r = Resolve-FetchedFixture -Case $c -Source 'community' -Fetch $fetch
        Assert-True ($r.Home -like '*\qairt\2.34.0') 'the fetched zip resolves like a staged one'
        Assert-True ($script:fetched.Count -eq 1) 'one fetch'
        Assert-True ($script:fetched[0] -eq 'https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.34.0/v2.34.0.zip') 'the software center URL for that version'
        Assert-True (Test-Path (Join-Path $c.Cache 'qairt-2.34.0.zip')) 'the zip stays in the cache dir'
        $null = Resolve-FetchedFixture -Case $c -Source 'community' -Fetch $fetch
        Assert-True ($script:fetched.Count -eq 1) 'a verified cached zip is not fetched again'
        Set-Content (Join-Path $c.Cache 'qairt-2.34.0.zip') 'corrupt'
        $null = Resolve-FetchedFixture -Case $c -Source 'community' -Fetch $fetch
        Assert-True ($script:fetched.Count -eq 2) 'a cached zip that fails its sha is fetched again'
    }

    It 'fetches nothing without a pin or under QNN_SDK_SOURCE=drop, and refuses a version without its sha' {
        $c = New-FetchCase 'nofetch'
        $fetch = { throw 'must not fetch' }
        Assert-True ($null -eq (Resolve-QnnSdk -DropDir $c.Drop -ExtractDir $script:extract -Arch 'arm64' -Community @{ Version = ''; CacheDir = $c.Cache; Fetch = $fetch })) 'no pin -> QNN off'
        Assert-True ($null -eq (Resolve-FetchedFixture -Case $c -Source 'drop' -Fetch $fetch)) 'drop keeps the staged-only contract'
        Assert-Throws { Resolve-FetchedFixture -Case $c -Source 'community' -Fetch $fetch -Sha '' | Out-Null } 'a version without its sha must throw' -MessagePattern 'without QNN_SDK_ZIP_SHA256'
    }

    It 'throws on two staged zips and on a zip that is not an SDK' {
        $two = Join-Path $script:tmp 'two'; New-Item $two -ItemType Directory -Force | Out-Null
        Copy-Item $script:zip (Join-Path $two 'a.zip'); Copy-Item $script:zip (Join-Path $two 'b.zip')
        Assert-Throws { Resolve-QnnSdk -DropDir $two -ExtractDir $script:extract -Arch 'arm64' | Out-Null } 'two zips must throw'
        $junk = Join-Path $script:tmp 'junk'; New-Item (Join-Path $junk 'src') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $junk 'src\readme.txt') 'not an sdk'
        [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $junk 'src'), (Join-Path $junk 'notsdk.zip'))
        Assert-Throws { Resolve-QnnSdk -DropDir $junk -ExtractDir $script:extract -Arch 'arm64' | Out-Null } 'a zip without include\QNN\QnnInterface.h must throw' -MessagePattern 'QnnInterface\.h not found'
    }
}
