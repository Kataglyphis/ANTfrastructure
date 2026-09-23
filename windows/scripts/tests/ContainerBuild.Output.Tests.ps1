#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Invoke-ContainerBuild's docker output reaches the HOST, never the function's result:
# consumers write `$null = Invoke-ContainerBuild`, which swallowed every line of a failing
# CI build (2026-09-23). The in-process half lives with the bind-mount fake in
# Modules.Orchestrators.Tests.ps1. docs/windows-builds.md#reusable-module-windowscontainerbuildreuse

$script:reuseModule = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules') 'WindowsContainerBuild.Reuse.psm1'
Import-Module $script:reuseModule -Force -DisableNameChecking

Describe 'Invoke-ContainerBuild: a caller that discards the result still sees the build' {

    It 'prints the build''s stdout in a child session that ran `$null = Invoke-ContainerBuild`' {
        Invoke-InTestDir { param($dir)
            # A minimal docker for the bind-mount path: probe, pre-removal, run, wait, cleanup.
            $fake = @'
$j = $args -join ' '
$global:LASTEXITCODE = 0
if ($args[0] -eq 'run' -and $j -notmatch '--rm') { $env:WBT_C_RAN = '1'; 'VISIBLE-BUILD-LINE' }
elseif ($j -match 'State\.Status') { if ($env:WBT_C_RAN) { 'exited' } else { $global:LASTEXITCODE = 1; 'Error: No such object: c' } }
elseif ($j -match 'State\.ExitCode') { '0' }
elseif ($args[0] -eq 'inspect') { $global:LASTEXITCODE = 1 }
'@
            $child = Join-Path $dir 'child.ps1'
            Set-Content -Path $child -Encoding utf8 -Value @(
                "Import-Module '$($script:reuseModule)' -Force -DisableNameChecking"
                "Set-Item function:global:ChildDocker -Value ([scriptblock]::Create(@'"
                $fake
                "'@))"
                "`$null = Invoke-ContainerBuild -DockerExe ChildDocker -Image i -ContainerName c -RepoRoot '$dir' -BuildCommand @('b') -UseBindMount 6>`$null"
                "'CHILD-DONE'"
            )
            $out = (& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $child 2>&1 | Out-String)
            Assert-Match 'CHILD-DONE' $out "the child failed: $out"
            Assert-Match 'VISIBLE-BUILD-LINE' $out 'the build output never reached the host'
        }
    }
}

# Every `& $DockerExe ...` pipeline whose LAST element is docker and whose output nothing
# consumes (assignment, @(), $(), parentheses) leaks into its function's result.
function Get-LeakingDockerCall {
    param([Parameter(Mandatory)][string]$Text)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
        $last = $p.PipelineElements[-1]
        if ($last -isnot [System.Management.Automation.Language.CommandAst] -or
            $last.InvocationOperator -ne 'Ampersand' -or
            $last.CommandElements[0] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            $last.CommandElements[0].VariablePath.UserPath -ne 'DockerExe') { continue }
        $consumed = $false
        for ($a = $p.Parent; $a -and $a -isnot [System.Management.Automation.Language.FunctionDefinitionAst]; $a = $a.Parent) {
            if ($a -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                $a -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $a -is [System.Management.Automation.Language.SubExpressionAst] -or
                $a -is [System.Management.Automation.Language.ParenExpressionAst]) { $consumed = $true; break }
        }
        if (-not $consumed) { "line $($p.Extent.StartLineNumber): $($p.Extent.Text -replace '\s+', ' ')" }
    }
}

Describe 'WindowsContainerBuild.Reuse: no docker call leaks into a function result' {

    $src = [IO.File]::ReadAllText($script:reuseModule)

    It 'every unconsumed docker pipeline ends in Out-Host or Out-Null' {
        Assert-Equal '' (@(Get-LeakingDockerCall -Text $src) -join "`n")
    }

    It 'the guard sees the tar-pipe build exec, which no fake can reach (mutation)' {
        $find = '& $DockerExe exec -w $WorkspacePath $container cmd /S /C $EntrypointPath @buildArgs | Out-Host'
        Assert-True $src.Contains($find) 'the build exec line moved; update the mutation'
        $leaks = @(Get-LeakingDockerCall -Text $src.Replace($find, $find.Replace(' | Out-Host', '')))
        Assert-Equal 1 $leaks.Count
        Assert-Match 'EntrypointPath' $leaks[0]
    }

    It 'the guard sees the bind-mount run too (mutation)' {
        $find = '-w $WorkspacePath $Image @buildArgs | Out-Host'
        Assert-True $src.Contains($find) 'the bind-mount run moved; update the mutation'
        Assert-Equal 1 @(Get-LeakingDockerCall -Text $src.Replace($find, '-w $WorkspacePath $Image @buildArgs')).Count
    }
}
