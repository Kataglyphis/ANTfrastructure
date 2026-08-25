#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Resolve-QnnSdk (backlog #121): the host never held the real, login-gated
# SDK, so this fixture is the ONLY exercise of the SDK-present branch until a
# zip is staged. A fake zip with the documented layout (qairt\<ver>\include\QNN\
# QnnInterface.h + lib\<arch>\QnnCpu.dll) drives every branch: found, no zip,
# two zips, SHA mismatch, non-SDK zip, missing backend set for the target.

Describe 'Resolve-QnnSdk' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
        $script:savedArch = $env:WINDOWS_TARGET_ARCH
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-qnn-' + [guid]::NewGuid().ToString('N'))
        $script:drop = Join-Path $script:tmp 'drop'
        $script:extract = Join-Path $script:tmp 'extract'
        New-Item -Path $script:drop -ItemType Directory -Force | Out-Null
        # Build the fake SDK tree, zip it.
        $sdk = Join-Path $script:tmp 'sdk\qairt\2.34.0'
        foreach ($d in 'include\QNN', 'lib\aarch64-windows-msvc', 'lib\x86_64-windows-msvc', 'lib\hexagon-v73\unsigned') { New-Item -Path (Join-Path $sdk $d) -ItemType Directory -Force | Out-Null }
        Set-Content (Join-Path $sdk 'include\QNN\QnnInterface.h') '// fake'
        Set-Content (Join-Path $sdk 'lib\aarch64-windows-msvc\QnnCpu.dll') 'fake'
        Set-Content (Join-Path $sdk 'lib\aarch64-windows-msvc\QnnHtp.dll') 'fake'
        Set-Content (Join-Path $sdk 'lib\hexagon-v73\unsigned\libQnnHtpV73Skel.so') 'fake'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:zip = Join-Path $script:drop 'v2.34.0.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $script:tmp 'sdk'), $script:zip)
        $script:sha = (Get-FileHash -Algorithm SHA256 -Path $script:zip).Hash
    }
    AfterAll { $env:WINDOWS_TARGET_ARCH = $script:savedArch; Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

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
        $threw = $false
        try { Resolve-QnnSdk -DropDir $script:drop -ExpectedSha256 ('0' * 64) -ExtractDir $script:extract -Arch 'arm64' | Out-Null } catch { $threw = $true; Assert-True ($_.Exception.Message -match 'SHA256 mismatch') 'names the hash' }
        Assert-True $threw 'hash mismatch must throw'
        $threw = $false
        try { Resolve-QnnSdk -DropDir $script:drop -ExpectedSha256 $script:sha -ExtractDir $script:extract -Arch 'amd64' | Out-Null } catch { $threw = $true; Assert-True ($_.Exception.Message -match 'QnnCpu\.dll missing') 'names the missing backend' }
        Assert-True $threw 'the fake SDK has no x86_64 QnnCpu.dll -> amd64 must throw'
    }

    It 'throws on two staged zips and on a zip that is not an SDK' {
        $two = Join-Path $script:tmp 'two'; New-Item $two -ItemType Directory -Force | Out-Null
        Copy-Item $script:zip (Join-Path $two 'a.zip'); Copy-Item $script:zip (Join-Path $two 'b.zip')
        $threw = $false
        try { Resolve-QnnSdk -DropDir $two -ExtractDir $script:extract -Arch 'arm64' | Out-Null } catch { $threw = $true }
        Assert-True $threw 'two zips must throw'
        $junk = Join-Path $script:tmp 'junk'; New-Item (Join-Path $junk 'src') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $junk 'src\readme.txt') 'not an sdk'
        [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $junk 'src'), (Join-Path $junk 'notsdk.zip'))
        $threw = $false
        try { Resolve-QnnSdk -DropDir $junk -ExtractDir $script:extract -Arch 'arm64' | Out-Null } catch { $threw = $true; Assert-True ($_.Exception.Message -match 'QnnInterface\.h not found') 'names the anchor' }
        Assert-True $threw 'a zip without include\QNN\QnnInterface.h must throw'
    }
}
