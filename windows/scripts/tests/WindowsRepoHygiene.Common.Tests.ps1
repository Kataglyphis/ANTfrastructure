#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Real throwaway repos, not a mocked git: the risk is git changing what the wrapped arguments mean.

Describe 'WindowsRepoHygiene.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsRepoHygiene.Common.psm1'
    Import-Module $modulePath -Force
    Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -DisableNameChecking

    $script:sandbox = New-TestDir -Prefix 'repohygiene-'

    # Identity is per-repo so the suite never depends on or touches the host's global git config.
    function script:New-TestRepo {
      param([string]$Name, [object[]]$Commit)
      $repo = New-TestGitRepository -Path (Join-Path $script:sandbox $Name) -UserName 'Repo Hygiene Test' -UserEmail 'test@example.invalid'
      foreach ($c in $Commit) { script:Add-TestCommit -Path $repo -File $c[0] -Content $c[1] -Message $c[2] }
      $repo
    }

    function script:Add-TestCommit {
      param([string]$Path, [string]$File, [string]$Content, [string]$Message)
      Add-TestGitCommit -Path $Path -Files @{ $File = "$Content$([Environment]::NewLine)" } -Message $Message
    }

    function script:New-ChildClone {
      param([string]$Name)
      $clone = Join-Path $script:sandbox $Name
      & git -c protocol.file.allow=always clone --quiet ($script:child -replace '\\', '/') $clone 2>$null
      $clone
    }

    # Each fixture repo's (file, content, message) commits, committed in order.
    $script:repo = @{}
    foreach ($fixture in ([ordered]@{
          'child'              = @('a.txt', 'one', 'first'), @('a.txt', 'two', 'second')
          'parent'             = , @('root.txt', 'root', 'root')
          # The ignore rule arrives afterwards, which .gitignore does not fix retroactively.
          'stale-artifact'     = @('generated.log', 'output', 'commit artifact'), @('.gitignore', 'generated.log', 'ignore it')
          'unignored-artifact' = @('root.txt', 'root', 'root'), @('Testing/TAG', 'tag', 'commit ctest output')
          'pycache-artifact'   = @('pkg/__pycache__/m.pyc', 'x', 'bytecode'), @('build-x/out.o', 'x', 'object')
        }).GetEnumerator()) {
      $script:repo[$fixture.Key] = script:New-TestRepo -Name $fixture.Key -Commit $fixture.Value
    }

    # Child: the repository used as a submodule
    $script:child = $script:repo['child']
    $script:childFirst = (& git -C $script:child rev-parse HEAD~1).Trim()
    $script:childSecond = (& git -C $script:child rev-parse HEAD).Trim()

    # Parent: superproject pinning child at its tip; local-path submodules need protocol.file.allow (CVE-2022-39253)
    $script:parent = $script:repo['parent']
    & git -C $script:parent -c protocol.file.allow=always submodule add --quiet `
      ($script:child -replace '\\', '/') 'sub' 2>$null
    Add-TestGitCommit -Path $script:parent -Message 'add submodule'
    $script:parentSub = Join-Path $script:parent 'sub'
  }

  AfterAll {
    Remove-TestDir -Path $script:sandbox
  }

  Context 'Get-SubmoduleStatusLine' {
    It 'reports a line for every configured submodule' {
      @(Get-SubmoduleStatusLine -RepoRoot $script:parent).Count | Should -Be 1
    }

    It 'returns nothing for a repository with no submodules' {
      @(Get-SubmoduleStatusLine -RepoRoot $script:child).Count | Should -Be 0
    }
  }

  Context 'Get-SubmodulePinDrift' {
    It 'reports no drift when the submodule sits on its recorded commit' {
      @(Get-SubmodulePinDrift -RepoRoot $script:parent).Count | Should -Be 0
    }

    It 'reports the submodule once it is checked out elsewhere' {
      & git -C $script:parentSub checkout --quiet $script:childFirst 2>$null
      try {
        $drift = @(Get-SubmodulePinDrift -RepoRoot $script:parent)
        $drift.Count | Should -Be 1
        $drift[0] | Should -Match '^\+'
        $drift[0] | Should -Match 'sub'
      } finally {
        & git -C $script:parentSub checkout --quiet $script:childSecond 2>$null
      }
    }

    It 'is clean again after the pin is restored' {
      @(Get-SubmodulePinDrift -RepoRoot $script:parent).Count | Should -Be 0
    }
  }

  Context 'Get-TrackedIgnoredFile' {
    It 'returns nothing for a repository with no ignored-but-tracked paths' {
      @(Get-TrackedIgnoredFile -RepoRoot $script:child).Count | Should -Be 0
    }

    It 'reports a file that was committed before the ignore rule existed' {
      $tracked = @(Get-TrackedIgnoredFile -RepoRoot $script:repo['stale-artifact'])
      $tracked.Count | Should -Be 1
      $tracked[0] | Should -Be 'generated.log'
    }
  }

  Context 'Get-TrackedGeneratedArtifact' {
    It 'reports a tracked generated file that no ignore rule covers' {
      # Tracked but not ignored: Get-TrackedIgnoredFile returns clean while the artifact sits in the index.
      @(Get-TrackedIgnoredFile -RepoRoot $script:repo['unignored-artifact']).Count | Should -Be 0
      $found = @(Get-TrackedGeneratedArtifact -RepoRoot $script:repo['unignored-artifact'] -Pattern @('Testing/'))
      $found.Count | Should -Be 1
      $found[0] | Should -Be 'Testing/TAG'
    }

    It 'returns nothing when the generated paths hold no tracked files' {
      @(Get-TrackedGeneratedArtifact -RepoRoot $script:child -Pattern @('Testing/', 'docs/build/')).Count |
        Should -Be 0
    }

    It 'refuses a wildcard pathspec ending in a slash, which git matches against no file' {
      $repo = $script:repo['pycache-artifact']
      @(& git -C $repo ls-files -- '**/__pycache__/' 'build*/').Count | Should -Be 0
      foreach ($dead in '**/__pycache__/', 'build*/', ':(glob)**/__pycache__/', 'pkg/__pycache?/') {
        $pattern = 'matches no file: {0}\. Write ''{0}\*''\.' -f [regex]::Escape($dead)
        Assert-Throws -MessagePattern $pattern -Body {
          Get-TrackedGeneratedArtifact -RepoRoot $repo -Pattern @('logs/', $dead)
        }
      }
      (@(Get-TrackedGeneratedArtifact -RepoRoot $repo -Pattern @('**/__pycache__/*', 'build*/*', 'pkg/__pycache__/')) -join ',') |
        Should -Be 'build-x/out.o,pkg/__pycache__/m.pyc'
    }
  }

  Context 'Test-SubmoduleCommitReachable' {
    It 'finds the pin via local remote-tracking refs in a full clone' {
      $clone = script:New-ChildClone -Name 'child-clone'

      $result = Test-SubmoduleCommitReachable -SubmodulePath $clone
      $result.Head | Should -Be $script:childSecond
      $result.Reachable | Should -BeTrue
      $result.Method | Should -Be 'local-tracking'
    }

    It 'reports unreachable for a commit that exists only locally' {
      $clone = script:New-ChildClone -Name 'child-local-only'
      Set-TestGitIdentity -Path $clone -UserName 'Repo Hygiene Test' -UserEmail 'test@example.invalid'
      # A commit the remote never saw: no branch can contain it, so all three escalation steps come up empty.
      Add-TestGitCommit -Path $clone -Files @{ 'local.txt' = "local$([Environment]::NewLine)" } -Message 'local only'

      $result = Test-SubmoduleCommitReachable -SubmodulePath $clone
      $result.Reachable | Should -BeFalse
      $result.Method | Should -Be 'fetched-heads'
    }
  }
}
