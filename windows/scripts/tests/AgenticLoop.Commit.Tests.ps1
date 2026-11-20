#requires -Version 7.0
# Invoke-GitAutoCommit against a real git repository: what it stages, what it leaves out, and a refusal it reports.

Import-Module (Join-Path $PSScriptRoot 'WindowsAgentic.Fixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop

$script:agenticCommitFactory = New-TestAgenticModuleFactory -FunctionName @('Invoke-AgenticStage', 'Invoke-GitAutoCommit') -Prelude @'
$script:AgenticStageMaxKiB = 500
'@

# A repository with one commit whose author is fixed, so no host config decides the commit.
function New-AgenticCommitRepo {
    param([Parameter(Mandatory)][string]$Root)
    $repo = Join-Path $Root ('repo-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $repo
    & git -C $repo init -q
    & git -C $repo config user.email 'fixture@example.invalid'
    & git -C $repo config user.name 'fixture'
    & git -C $repo config commit.gpgsign false
    Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'one'
    & git -C $repo add tracked.txt
    & git -C $repo commit -q -m base
    return $repo
}

function Get-AgenticCommitFiles {
    param([string]$Repo)
    return (@(& git -C $Repo show --name-only --format= HEAD | Where-Object { $_ }) | Sort-Object) -join ' '
}

Describe 'Agentic auto-commit' {
    Invoke-TestMutationChecks -Check @(
        @{ Name = 'commits tracked edits and new text, and leaves a 1 MB binary and a large file out, with a sniff fault control'; Arguments = @{
            ModuleArgumentsFactory = $script:agenticCommitFactory; Find = '-or ($head -and $head -contains 0)'
            Replace = '-or $false'; Expected = 'only the staging rule'; Body = {
                param($state)
                $repo = New-AgenticCommitRepo -Root $state.Root
                Add-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'two'
                Set-Content -LiteralPath (Join-Path $repo 'notes.md') -Value 'text'
                [IO.File]::WriteAllBytes((Join-Path $repo 'core'), [byte[]](@(120, 0) + @(121) * 1048576))
                [IO.File]::WriteAllText((Join-Path $repo 'big.log'), ('a' * (501 * 1024)))
                [IO.File]::WriteAllBytes((Join-Path $repo 'small.bin'), [byte[]](120, 0, 121))
                Assert-True (Invoke-MutGitAutoCommit -Message 'loop: task #1' -RepoRoot $repo -Enabled $true) 'a commit that went in is a success'
                Assert-Equal 'notes.md tracked.txt' (Get-AgenticCommitFiles $repo) 'only the staging rule decides what goes in'
                Assert-True ($state.Calls -contains 'log|WARN|Auto-commit: left out core (binary, a link or over 500 KiB); stage it by hand if it belongs') 'the binary is named'
                Assert-True ($state.Calls -contains 'log|WARN|Auto-commit: left out small.bin (binary, a link or over 500 KiB); stage it by hand if it belongs') 'a small binary is caught by its NUL byte'
                Assert-True ($state.Calls -contains 'log|WARN|Auto-commit: left out big.log (binary, a link or over 500 KiB); stage it by hand if it belongs') 'the large file is named'
            } } }
        @{ Name = 'reports a refused git commit as failed and says why, with a status fault control'; Arguments = @{
            ModuleArgumentsFactory = $script:agenticCommitFactory; Find = 'if ($LASTEXITCODE -ne 0) { Write-AgenticLog "Auto-commit refused: $out"'
            Replace = 'if ($false) { Write-AgenticLog "Auto-commit refused: $out"'; Expected = 'a refused commit'; Body = {
                param($state)
                $repo = New-AgenticCommitRepo -Root $state.Root
                $hook = Join-Path $repo '.git/hooks/pre-commit'
                Set-Content -LiteralPath $hook -Value "#!/bin/sh`necho refused-by-hook >&2`nexit 1"
                if (-not $IsWindows) { & chmod +x $hook }
                Add-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'three'
                Assert-False (Invoke-MutGitAutoCommit -Message 'loop: task #2' -RepoRoot $repo -Enabled $true) 'a refused commit must return $false'
                Assert-Equal '1' ((& git -C $repo rev-list --count HEAD) | Out-String).Trim() 'nothing was committed'
                Assert-True (@($state.Calls | Where-Object { $_ -like 'log|ERROR|Auto-commit refused:*refused-by-hook*' }).Count -eq 1) 'the log names the refusal'
            } } }
    )

    It 'treats nothing to commit as no failure' {
        Invoke-InTestDir { param($dir)
            $recipe = & $script:agenticCommitFactory $dir
            Invoke-WithFunctionModule @recipe -Body {
                param($state)
                $repo = New-AgenticCommitRepo -Root $state.Root
                Assert-True (Invoke-MutGitAutoCommit -Message 'x' -RepoRoot $repo -Enabled $true)
                Assert-True ($state.Calls -contains 'log|INFO|Auto-commit: nothing to commit')
            }
        }
    }
}
