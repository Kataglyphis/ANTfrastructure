#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Hub #181: the LiteRT layer exported bazel's output base, checkout and JDK, 25 to 44 min per rebuild.

Describe 'Build-LitertLmBazel: bazel''s trees leave the layer (hub #181)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-LitertLmBazel.ps1' -FunctionName 'Get-TreeGb', 'Remove-LitertLmBuildTree')
    $script:LlmBazelText = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-LitertLmBazel.ps1'))

    # An empty file at $Rel under $Root, its directories made on the way.
    function New-TreeFile([string]$Root, [string]$Rel) { return (New-Item -ItemType File -Force -Path (Join-Path $Root $Rel)).FullName }

    It 'removes each tree and file it names, and a junction inside one never takes its target along (mutation)' {
        Invoke-InTestDir { param($d)
            # A JDK-like tree outside the output base, which bazel links into external\ as a junction.
            $keep = New-TreeFile $d 'outside\keep.txt'
            $null = New-TreeFile $d 'bzl\execroot\a\out.obj'
            $null = New-Item -ItemType Junction -Path (Join-Path $d 'bzl\external_local_jdk') -Target (Split-Path $keep)
            $log = New-TreeFile $d 'bazel-build.log'
            Remove-LitertLmBuildTree -Path @((Join-Path $d 'bzl'), $log, (Join-Path $d 'absent')) -JdkRoot (Join-Path $d 'no-jdk')
            Assert-False (Test-Path -LiteralPath (Join-Path $d 'bzl')) 'the output base is gone'
            Assert-False (Test-Path -LiteralPath $log) 'the log is gone'
            Assert-True (Test-Path -LiteralPath $keep) 'the junction''s target survives'
            Assert-Equal 0 $global:LASTEXITCODE 'no exit code leaks into the chain'
        }
    }

    It 'runs after the install and its contract check, outside the checkout it deletes' {
        Assert-Match '(?s)throw \("LiteRT-LM install does not satisfy.*\} finally \{.*Pop-Location\s*\r?\n\}\s*\r?\nRemove-LitertLmBuildTree\s*\r?\n' $script:LlmBazelText 'after the finally that leaves C:\llm'
        Assert-Match "\[string\[\]\]\`$Path = @\('C:\\bzl', 'C:\\llm', 'C:\\bzl-tools', 'C:\\bazel-build\.log'\)" $script:LlmBazelText 'the four paths the sweep measured'
    }

    It 'streams bazel to the stage log, its progress at most once per 30 s, and the whole of it to the log file' {
        Assert-False ($script:LlmBazelText -match 'bazel-build\.log \| Select-Object -Last 20') 'no 450 s of silence'
        Assert-Match 'Tee-Object -FilePath C:\\bazel-build\.log \| ForEach-Object' $script:LlmBazelText 'every line passes through'
        Assert-Match "TotalSeconds -ge 30\) \{ Write-Host \`$line; \`$lastProgress = Get-Date \}" $script:LlmBazelText 'progress throttled'
    }
}

Describe 'Build-LitertLmBazel: bazelisk, the JDK and git-lfs are pinned and checked (hub #185)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-LitertLmBazel.ps1' -FunctionName 'Get-PinnedTool', 'Get-LitertLmToolPin')
    # The download is a copy from -Uri, so a case controls the bytes that arrive.
    function Get-UrlWithRetry { param($Uri, $OutFile) Copy-Item -LiteralPath $Uri -Destination $OutFile -Force }
    $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')

    It 'fetches once, hits the cache while the bytes match, re-fetches a corrupt entry and refuses wrong bytes or no pin (mutation)' {
        Invoke-InTestDir { param($d)
            Set-Content -LiteralPath "$d\good.bin" -Value 'tool' -NoNewline
            Set-Content -LiteralPath "$d\bad.bin" -Value 'evil' -NoNewline
            $sha = (Get-FileHash -LiteralPath "$d\good.bin" -Algorithm SHA256).Hash
            Invoke-WithEnv @{ WBT_TOOL_SHA256 = $sha } {
                Get-PinnedTool -Uri "$d\good.bin" -Path "$d\cache.bin" -PinKey WBT_TOOL_SHA256 6>$null
                Assert-Equal 'tool' (Get-Content -LiteralPath "$d\cache.bin" -Raw) 'fetched'
                Get-PinnedTool -Uri "$d\absent.bin" -Path "$d\cache.bin" -PinKey WBT_TOOL_SHA256 6>$null
                Set-Content -LiteralPath "$d\cache.bin" -Value 'rot' -NoNewline
                Get-PinnedTool -Uri "$d\good.bin" -Path "$d\cache.bin" -PinKey WBT_TOOL_SHA256 6>$null
                Assert-Equal 'tool' (Get-Content -LiteralPath "$d\cache.bin" -Raw) 'a corrupt cache entry is fetched again'
                Assert-Throws { Get-PinnedTool -Uri "$d\bad.bin" -Path "$d\other.bin" -PinKey WBT_TOOL_SHA256 6>$null } -MessagePattern 'pins'
                Assert-False (Test-Path -LiteralPath "$d\other.bin") 'wrong bytes do not stay in the cache'
            }
            Invoke-WithEnv @{ WBT_TOOL_SHA256 = $null } {
                Assert-Throws { Get-PinnedTool -Uri "$d\good.bin" -Path "$d\x.bin" -PinKey WBT_TOOL_SHA256 } -MessagePattern 'refusing an unpinned x\.bin'
            }
        }
    }

    It 'builds the three release URLs from the versions.env pins, and every pin key is set' {
        $env = @{}
        foreach ($k in 'BAZELISK_WINDOWS_VERSION', 'TEMURIN_JDK_WINDOWS_VERSION', 'GIT_LFS_WINDOWS_VERSION') { $env[$k] = $pins[$k] }
        $tools = Invoke-WithEnv $env { Get-LitertLmToolPin }
        Assert-Equal 3 $tools.Count 'bazelisk, JDK, git-lfs'
        Assert-Match '^https://github\.com/bazelbuild/bazelisk/releases/download/v[\d.]+/bazelisk-windows-amd64\.exe$' $tools[0].Uri 'bazelisk, never releases/latest'
        Assert-Match '^https://github\.com/adoptium/temurin21-binaries/releases/download/jdk-21\.[\d.]+%2B\d+/OpenJDK21U-jdk_x64_windows_hotspot_21\.[\d.]+_\d+\.zip$' $tools[1].Uri 'the Temurin release asset'
        Assert-Match '^https://github\.com/git-lfs/git-lfs/releases/download/v[\d.]+/git-lfs-windows-amd64-v[\d.]+\.zip$' $tools[2].Uri 'git-lfs'
        foreach ($t in $tools) { Assert-Match '^[0-9a-f]{64}$' $pins[$t.PinKey] $t.PinKey }
        Invoke-WithEnv @{ BAZELISK_WINDOWS_VERSION = $null } { Assert-Throws { Get-LitertLmToolPin } -MessagePattern 'BAZELISK_WINDOWS_VERSION is unset' }
    }

    It 'has no floating fetch left: no releases/latest, no Adoptium latest API, no scoop install' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-LitertLmBazel.ps1'))
        foreach ($floating in 'releases/latest', 'api.adoptium.net', 'scoop install') { Assert-False ($text.Contains($floating)) $floating }
    }
}
