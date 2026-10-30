#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: whether GitLab recovers within the retry budget, or that tflite's FetchContent honours the override at configure time.

Describe 'Eigen clones from GitLab with a retry budget that outlasts its load shedding' {
    $calls = [System.Collections.Generic.List[hashtable]]::new()
    function Invoke-GitClone { param($RepoUrl, $Tag, $SourceDir, $MaxAttempts) $calls.Add(@{ Repo = $RepoUrl; Tag = $Tag; Dir = $SourceDir; Max = $MaxAttempts }); $true }
    function git { if ($args -contains 'rev-parse') { $calls[-1].Tag } else { $global:LASTEXITCODE = 0 } }
    $commit = 'ea13a98decd497a8c5588fb5de71b57bcf10d864'
    $declared = "OverridableFetchContent_Declare(`n  eigen`n  GIT_REPOSITORY https://gitlab.com/libeigen/eigen.git`n  # Sync with tensorflow/third_party/eigen3/workspace.bzl`n  GIT_TAG $commit`n  GIT_PROGRESS TRUE`n)`n"

    It 'LiteRT: clones tflite''s pinned commit, overrides FetchContent, and refuses a moved declaration (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-LitertFromSource.ps1' -FunctionName 'Get-LitertEigenSourceArg')
        $calls.Clear()
        Invoke-InTestDir -Files @{ 'eigen.cmake' = $declared; 'moved.cmake' = ($declared -replace 'GIT_TAG \S+', 'GIT_TAG master') } -Body {
            param($d)
            $dest = Join-Path $d 'eigen-prefetch'
            $arg = Get-LitertEigenSourceArg -EigenCmakePath (Join-Path $d 'eigen.cmake') -Destination $dest
            Assert-Equal "-DFETCHCONTENT_SOURCE_DIR_EIGEN=$($dest -replace '\\', '/')" $arg 'the override names the prefetch'
            Assert-Equal "https://gitlab.com/libeigen/eigen.git|$commit" "$($calls[0].Repo)|$($calls[0].Tag)" 'the declared repository at the declared commit'
            Assert-True ($calls[0].Max -ge 8) "retry budget $($calls[0].Max)"
            Assert-Throws { Get-LitertEigenSourceArg -EigenCmakePath (Join-Path $d 'moved.cmake') -Destination $dest } 'branch tag' -MessagePattern 're-derive the prefetch'
        }
        Assert-TestScriptContains -ScriptPath 'windows\scripts\build\Build-LitertFromSource.ps1' -Literal @("'-DTFLITE_ENABLE_BENCHMARK_MODEL=OFF', `$eigenSourceArg") -ReasonPrefix 'the cross host pass configures the same tree'
    }

    It 'HailoRT: a GitLab external takes its own budget and the GitHub ones keep the default (mutation)' {
        $hailo = 'windows\scripts\build\Build-HailortFromSource.ps1'
        . (Get-ScriptFunctionDefinition -ScriptPath $hailo -FunctionName 'Install-HailortExternals')
        $assignment = (Get-TestScriptAst -ScriptPath (Join-Path (Get-RepoRoot) $hailo)).Find({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$hailoExternals' }, $true)
        $externals = & ([scriptblock]::Create($assignment.Right.Extent.Text))
        $calls.Clear()
        Invoke-InTestDir -Files @{ 'hailort/external/protobuf-src/CMakeLists.txt' = '' } -Body {
            param($d) Install-HailortExternals -SourceRoot $d -ProtobufVersion '1' -ProtobufSha 'x' -Externals $externals
        }
        $budgets = @($calls | ForEach-Object { "$(if ($_.Repo -match '//gitlab\.com/') { 'gitlab' } else { 'other' }):$($_.Max)" } | Sort-Object -Unique)
        Assert-Equal 'gitlab:8 other:3' ($budgets -join ' ') 'the real table: Eigen from GitLab gets eight tries, the GitHub externals three'
    }
}
