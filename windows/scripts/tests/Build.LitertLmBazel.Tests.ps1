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
            Remove-LitertLmBuildTree -OutputBase (Join-Path $d 'bzl') -Path @((Join-Path $d 'bzl'), $log, (Join-Path $d 'absent')) -Bazelisk (Join-Path $d 'no-bazelisk.exe')
            Assert-False (Test-Path -LiteralPath (Join-Path $d 'bzl')) 'the output base is gone'
            Assert-False (Test-Path -LiteralPath $log) 'the log is gone'
            Assert-True (Test-Path -LiteralPath $keep) 'the junction''s target survives'
            Assert-Equal 0 $global:LASTEXITCODE 'no exit code leaks into the chain'
        }
    }

    It 'runs after the install and its contract check, outside the checkout it deletes' {
        Assert-Match '(?s)throw \("LiteRT-LM install does not satisfy.*\} finally \{.*Pop-Location\s*\r?\n\}\s*\r?\nRemove-LitertLmBuildTree -OutputBase \$outputBase' $script:LlmBazelText 'after the finally that leaves C:\llm'
        Assert-Match "\[string\[\]\]\`$Path = @\('C:\\bzl', 'C:\\llm', 'C:\\bzl-tools', 'C:\\bazel-build\.log'\)" $script:LlmBazelText 'the four paths the sweep measured'
    }

    It 'streams bazel to the stage log, its progress at most once per 30 s, and the whole of it to the log file' {
        Assert-False ($script:LlmBazelText -match 'bazel-build\.log \| Select-Object -Last 20') 'no 450 s of silence'
        Assert-Match 'Tee-Object -FilePath C:\\bazel-build\.log \| ForEach-Object' $script:LlmBazelText 'every line passes through'
        Assert-Match "TotalSeconds -ge 30\) \{ Write-Host \`$line; \`$lastProgress = Get-Date \}" $script:LlmBazelText 'progress throttled'
    }
}
