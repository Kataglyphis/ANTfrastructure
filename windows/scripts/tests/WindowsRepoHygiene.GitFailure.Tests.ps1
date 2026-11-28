#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Harness-style, so the Linux mutation shards run it without Pester; the guards' other cases stay in WindowsRepoHygiene.Common.Tests.ps1.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsRepoHygiene.Common.psm1') -Force

# The ceiling keeps git from finding a repository above the fixture, wherever the temp dir sits.
function Invoke-OutsideWorkTree {
    param([Parameter(Mandatory)][scriptblock]$Body)
    Invoke-InTestDir { param($dir)
        Invoke-WithEnv @{ GIT_CEILING_DIRECTORIES = $dir } { & $Body $dir }
    }
}

Describe 'WindowsRepoHygiene.Common: a git that fails' {
    It 'throws with git''s stderr outside a work tree instead of reporting it clean' {
        Invoke-OutsideWorkTree { param($dir)
            Assert-Throws -MessagePattern 'git ls-files -i -c --exclude-standard in .* exited 128: .*not a git repository' -Body {
                Get-TrackedIgnoredFile -RepoRoot $dir
            }
            Assert-Throws -MessagePattern 'git submodule status in .* exited 128' -Body { Get-SubmodulePinDrift -RepoRoot $dir }
        }
    }

    It 'answers unreachable, not an error, when the reachability probes fail' {
        Invoke-OutsideWorkTree { param($dir)
            $result = Test-SubmoduleCommitReachable -SubmodulePath $dir
            Assert-False $result.Reachable 'a failed probe reads as unreachable'
            Assert-Equal 'no-head' $result.Method
        }
    }
}
