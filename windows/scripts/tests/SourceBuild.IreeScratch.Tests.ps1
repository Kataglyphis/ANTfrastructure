#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# IREE's build tree lives on the media-tvm RUN's cache mount, outside the 20 GB scratch; host-portable for Linux pwsh.

Describe 'IREE build tree on the media-tvm cache mount' {
    $script:ireeScript = 'windows/scripts/build/Build-IreeFromSource.ps1'
    Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSourceBuild.Common.psm1') -DisableNameChecking
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ireeScript -FunctionName 'Resolve-IreeBuildDir', 'Clear-IreeBuildMount')

    function Get-IreeBuildMountLiteral {
        $ast = Get-TestScriptAst -ScriptPath $script:ireeScript
        $assignments = @($ast.FindAll({ param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:IreeBuildMount'
                }, $false))
        if ($assignments.Count -ne 1) { throw "expected one top-level `$script:IreeBuildMount, found $($assignments.Count)" }
        $assignments[0].Right.Extent.Text.Trim("'", '"')
    }

    function Get-TvmRunCacheTarget {
        $parsed = Get-TestDockerfileStagesFromPath -Path (Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder') -JoinContinuations -IgnoreComments -TrimLines
        $run = @($parsed.ByName['media-tvm-built'].Lines | Where-Object { $_ -match '^RUN\s' -and $_ -match 'Build-MediaTvmAll\.ps1' })
        if ($run.Count -ne 1) { throw "expected one media-tvm RUN, found $($run.Count)" }
        foreach ($mount in [regex]::Matches($run[0], '--mount=type=cache,target=(?<target>[^,\s]+),id=(?<id>[^,\s]+)')) {
            [pscustomobject]@{ Target = $mount.Groups['target'].Value; Id = $mount.Groups['id'].Value }
        }
    }

    function Get-TopLevelCommand {
        param($Ast, [string]$Name)
        foreach ($command in @(Get-TestAstCommands -Ast $Ast -Name $Name)) {
            $node = $command.Parent
            while ($node -and $node -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $node = $node.Parent }
            if (-not $node) { $command }
        }
    }

    It 'names the cache mount the media-tvm RUN provides, and fails when either side moves (mutation)' {
        $literal = Get-IreeBuildMountLiteral
        $mount = @(Get-TvmRunCacheTarget | Where-Object { $_.Target -eq $literal })
        Assert-Equal 1 $mount.Count "the media-tvm RUN mounts $literal as a cache"
        Assert-Match '^iree-build-' $mount[0].Id 'its own cache id, never the sccache one'
    }

    It 'builds on an emptied mount when there is one, in the checkout otherwise, and clears the mount after (mutation)' {
        Invoke-InTestDir -Files @{ 'mount/stale/CMakeCache.txt' = 'old'; 'src/keep.txt' = 'x' } -Body {
            param($root)
            $script:IreeBuildMount = Join-Path $root 'mount'
            Assert-Equal $script:IreeBuildMount (Resolve-IreeBuildDir -SourceDir (Join-Path $root 'src')) 'the mount wins when present'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:IreeBuildMount -Force -ErrorAction SilentlyContinue).Count 'an earlier run''s tree never reaches configure'
            Write-TestFileTree -Root $root -Files @{ 'mount/built.obj' = 'x' }
            Clear-IreeBuildMount
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:IreeBuildMount -Force -ErrorAction SilentlyContinue).Count 'the host gets the space back'
            $script:IreeBuildMount = Join-Path $root 'absent'
            Assert-Equal (Join-Path (Join-Path $root 'src') 'build') (Resolve-IreeBuildDir -SourceDir (Join-Path $root 'src')) 'no mount: the checkout tree, as before'
            Assert-True (Test-Path -LiteralPath (Join-Path $root 'src\keep.txt')) 'the checkout is left alone'
        }
    }

    It 'resolves the tree before configure and clears the mount after the wheels, and fails when either call goes (mutation)' {
        $ast = Get-TestScriptAst -ScriptPath $script:ireeScript
        $resolve = @(Get-TopLevelCommand -Ast $ast -Name 'Resolve-IreeBuildDir')
        $clear = @(Get-TopLevelCommand -Ast $ast -Name 'Clear-IreeBuildMount')
        Assert-Equal 1 $resolve.Count 'one resolution'
        Assert-Equal 1 $clear.Count 'one clear'
        $configure = @(Get-TopLevelCommand -Ast $ast -Name 'Invoke-CmakeConfigure')[0]
        $cleanup = @(Get-TopLevelCommand -Ast $ast -Name 'Remove-SourceBuildTree')[-1]
        Assert-TestAstOrder -Before $resolve[0] -After $configure
        Assert-TestAstOrder -Before $cleanup -After $clear[0]
    }
}
