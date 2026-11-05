#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Harness-style and path-portable, so the Linux mutation shards can prove the fetch: Get-QnnCommunityZip alone; Resolve-QnnSdk's Windows paths stay in SourceBuild.Qnn.Tests.ps1.

$script:QnnZipFunctions = @('Get-QnnCommunityZip', 'Get-QnnCommunityZipUrl', 'Test-FileSha256')

# Invoke-QnnZipCase <body>: the three functions from the module under the Mut prefix, a pinned fake zip, a cache dir and a recording fetch.
function Invoke-QnnZipCase {
    param([Parameter(Mandatory)][scriptblock]$Body)
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsSourceBuild.Common.psm1' -FunctionName $script:QnnZipFunctions -BodyArgumentList @($Body) -Body {
        param($Case)
        $root = New-TestDir -Prefix 'wbt-qnnzip-'
        try {
            $zip = Join-Path $root 'v2.34.0.zip'
            New-TestZipFile -Path $zip -Member ([ordered]@{ 'qairt/2.34.0/include/QNN/QnnInterface.h' = '// fake' })
            $script:QnnFetched = @()
            $state = @{
                Zip   = $zip
                Sha   = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash
                Cache = (Join-Path $root 'cache')
                Fetch = { param($Url, $Destination, $Sha) $script:QnnFetched += $Url; Copy-Item $zip $Destination }.GetNewClosure()
            }
            & $Case $state
        } finally { Remove-TestDir -Path $root }
    }
}

Describe 'Get-QnnCommunityZip' {
    It 'fetches the pinned zip into the cache dir, reuses a verified one and refetches a corrupt one' {
        Invoke-QnnZipCase {
            param($s)
            $got = Get-MutQnnCommunityZip -Version '2.34.0' -ExpectedSha256 $s.Sha -CacheDir $s.Cache -Source 'community' -Fetch $s.Fetch
            Assert-Equal (Join-Path $s.Cache 'qairt-2.34.0.zip') $got 'the zip lands in the cache dir under its version'
            Assert-Equal 1 $script:QnnFetched.Count 'one fetch'
            Assert-Equal 'https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.34.0/v2.34.0.zip' $script:QnnFetched[0] 'the software center URL for that version'
            $null = Get-MutQnnCommunityZip -Version '2.34.0' -ExpectedSha256 $s.Sha -CacheDir $s.Cache -Source 'community' -Fetch $s.Fetch
            Assert-Equal 1 $script:QnnFetched.Count 'a verified cached zip is not fetched again'
            Set-Content -LiteralPath $got -Value 'corrupt'
            $null = Get-MutQnnCommunityZip -Version '2.34.0' -ExpectedSha256 $s.Sha -CacheDir $s.Cache -Source 'community' -Fetch $s.Fetch
            Assert-Equal 2 $script:QnnFetched.Count 'a cached zip that fails its sha is fetched again'
        }
    }

    It 'fetches nothing without a pin or under QNN_SDK_SOURCE=drop, and refuses a version without its sha' {
        Invoke-QnnZipCase {
            param($s)
            $never = { throw 'must not fetch' }
            Assert-Null (Get-MutQnnCommunityZip -Version '' -ExpectedSha256 $s.Sha -CacheDir $s.Cache -Fetch $never) 'no pin -> nothing'
            Assert-Null (Get-MutQnnCommunityZip -Version '2.34.0' -ExpectedSha256 $s.Sha -CacheDir $s.Cache -Source 'drop' -Fetch $never) 'drop keeps the staged-only contract'
            Assert-Throws { Get-MutQnnCommunityZip -Version '2.34.0' -ExpectedSha256 '' -CacheDir $s.Cache -Fetch $never | Out-Null } 'a version without its sha must throw' -MessagePattern 'without QNN_SDK_ZIP_SHA256'
        }
    }
}
