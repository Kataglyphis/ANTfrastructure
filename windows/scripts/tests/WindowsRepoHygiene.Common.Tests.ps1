#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Exercises the repo-state guards against REAL throwaway git repositories built
# in $env:TEMP rather than against mocks. These functions are thin wrappers over
# git porcelain, so a mocked `git` would only assert that the wrapper passes the
# arguments it was written to pass - it would not catch git changing what those
# arguments mean, which is the failure this suite exists to see.
#
# Local-path submodules need `protocol.file.allow=always` on git >= 2.38
# (CVE-2022-39253); it is set per-invocation, never in global config.

Describe 'WindowsRepoHygiene.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsRepoHygiene.Common.psm1'
    Import-Module $modulePath -Force

    $script:sandbox = (New-Item -ItemType Directory `
        -Path (Join-Path $env:TEMP ('repohygiene-' + (Get-Random))) -Force).FullName

    # Identity is set per-repo so the suite never depends on (or touches) the
    # host's global git config.
    function script:New-TestRepo {
      param([string]$Name)
      $path = (New-Item -ItemType Directory -Path (Join-Path $script:sandbox $Name) -Force).FullName
      & git -C $path init --quiet --initial-branch=main 2>$null
      & git -C $path config user.email 'test@example.invalid'
      & git -C $path config user.name 'Repo Hygiene Test'
      return $path
    }

    function script:Add-TestCommit {
      param([string]$Path, [string]$File, [string]$Content, [string]$Message)
      Set-Content -LiteralPath (Join-Path $Path $File) -Value $Content -Encoding utf8
      & git -C $Path add -A 2>$null
      & git -C $Path commit --quiet -m $Message 2>$null
    }

    # --- child: the repository used as a submodule -------------------------
    $script:child = script:New-TestRepo -Name 'child'
    script:Add-TestCommit -Path $script:child -File 'a.txt' -Content 'one' -Message 'first'
    $script:childFirst = (& git -C $script:child rev-parse HEAD).Trim()
    script:Add-TestCommit -Path $script:child -File 'a.txt' -Content 'two' -Message 'second'
    $script:childSecond = (& git -C $script:child rev-parse HEAD).Trim()

    # --- parent: superproject pinning child at its tip ---------------------
    $script:parent = script:New-TestRepo -Name 'parent'
    script:Add-TestCommit -Path $script:parent -File 'root.txt' -Content 'root' -Message 'root'
    & git -C $script:parent -c protocol.file.allow=always submodule add --quiet `
      ($script:child -replace '\\', '/') 'sub' 2>$null
    & git -C $script:parent commit --quiet -m 'add submodule' 2>$null
    $script:parentSub = Join-Path $script:parent 'sub'
  }

  AfterAll {
    Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
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
      $repo = script:New-TestRepo -Name 'stale-artifact'
      script:Add-TestCommit -Path $repo -File 'generated.log' -Content 'output' -Message 'commit artifact'
      # The ignore rule arrives afterwards - which is exactly the case
      # .gitignore does NOT retroactively fix.
      script:Add-TestCommit -Path $repo -File '.gitignore' -Content 'generated.log' -Message 'ignore it'

      $tracked = @(Get-TrackedIgnoredFile -RepoRoot $repo)
      $tracked.Count | Should -Be 1
      $tracked[0] | Should -Be 'generated.log'
    }
  }

  Context 'Get-TrackedGeneratedArtifact' {
    It 'reports a tracked generated file that no ignore rule covers' {
      # The blind spot: tracked but NOT ignored, so Get-TrackedIgnoredFile
      # returns clean while the artifact sits in the index anyway.
      $repo = script:New-TestRepo -Name 'unignored-artifact'
      script:Add-TestCommit -Path $repo -File 'root.txt' -Content 'root' -Message 'root'
      New-Item -ItemType Directory -Path (Join-Path $repo 'Testing') -Force | Out-Null
      script:Add-TestCommit -Path $repo -File 'Testing/TAG' -Content 'tag' -Message 'commit ctest output'

      @(Get-TrackedIgnoredFile -RepoRoot $repo).Count | Should -Be 0
      $found = @(Get-TrackedGeneratedArtifact -RepoRoot $repo -Pattern @('Testing/'))
      $found.Count | Should -Be 1
      $found[0] | Should -Be 'Testing/TAG'
    }

    It 'returns nothing when the generated paths hold no tracked files' {
      @(Get-TrackedGeneratedArtifact -RepoRoot $script:child -Pattern @('Testing/', 'docs/build/')).Count |
        Should -Be 0
    }
  }

  Context 'Test-SubmoduleCommitReachable' {
    It 'finds the pin via local remote-tracking refs in a full clone' {
      $clone = Join-Path $script:sandbox 'child-clone'
      & git -c protocol.file.allow=always clone --quiet ($script:child -replace '\\', '/') $clone 2>$null

      $result = Test-SubmoduleCommitReachable -SubmodulePath $clone
      $result.Head | Should -Be $script:childSecond
      $result.Reachable | Should -BeTrue
      $result.Method | Should -Be 'local-tracking'
    }

    It 'reports unreachable for a commit that exists only locally' {
      $clone = Join-Path $script:sandbox 'child-local-only'
      & git -c protocol.file.allow=always clone --quiet ($script:child -replace '\\', '/') $clone 2>$null
      & git -C $clone config user.email 'test@example.invalid'
      & git -C $clone config user.name 'Repo Hygiene Test'
      # A commit the remote has never seen: no branch, tip or otherwise, can
      # contain it, so all three escalation steps must come up empty.
      Set-Content -LiteralPath (Join-Path $clone 'local.txt') -Value 'local' -Encoding utf8
      & git -C $clone add -A 2>$null
      & git -C $clone commit --quiet -m 'local only' 2>$null

      $result = Test-SubmoduleCommitReachable -SubmodulePath $clone
      $result.Reachable | Should -BeFalse
      $result.Method | Should -Be 'fetched-heads'
    }
  }
}
