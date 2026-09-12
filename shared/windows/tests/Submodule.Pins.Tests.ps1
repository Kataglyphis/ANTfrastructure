#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Guards a repository's submodule pins against silent drift. Repo-agnostic: it
# is meant to be run FROM the ANTfrastructure submodule by any consumer, not copied
# into it.
#
#   - uses: ./third_party/ANTfrastructure/.github/actions/run-pester-suite
#     with:
#       path: third_party/ANTfrastructure/shared/windows/tests/Submodule.Pins.Tests.ps1
#
# Promoted from BeschleunigerBallett scripts/windows/tests/Submodule.Pins.Tests.ps1
# on 2026-09-07. The checks were always generic - the guards themselves have
# lived in WindowsRepoHygiene.Common since 2026-08-07 - and what kept the suite
# downstream were exactly two project-specific things, both removed here:
#
#   * the repo root, hard-coded three levels above $PSScriptRoot. It is now a
#     PARAMETER, because from inside a submodule the script's own location says
#     nothing about which superproject is being checked.
#   * an assertion naming third_party/FUZZTEST. Generalised: EVERY pin has to be
#     restorable from its remote, and no repo has to remember to add its own.
#
# Why the drift check exists at all: a submodule sitting away from its recorded
# gitlink means the build is compiling something other than what is committed,
# and `git submodule status` marks it with a '+' that is easy to miss in a wall
# of output. In the origin repo the symptom was a submodule repeatedly
# re-checked-out to a newer tag by something nobody ever identified (investigated
# 2026-07-20: no hook, no FetchContent, no script, no `submodule.<n>.branch`).
# CORRECTION 2026-09-09: that last clause was doing work it cannot do. The 07-20
# reasoning discounted `git submodule update --remote` BECAUSE the submodule
# declares no `branch`, and an unset branch does not disarm --remote at all - it
# makes --remote follow the REMOTE'S DEFAULT BRANCH. Proven on a synthetic
# superproject whose upstream default branch is named `trunk`: --remote checked
# out trunk, so the fallback is remote HEAD, not a hardcoded main/master. A bare
# --remote is therefore a live candidate for exactly the symptom this file
# detects, and it fits it well: a pin walked forward to a newer upstream commit
# with nothing recorded. It does not change what this file does - it still
# chases the SYMPTOM and not a culprit - but the culprit list was wrong.
#
# ASSERTION DIALECT: plain `throw`, never `Should`. Pester 3.x (`Should Be 0`)
# and Pester 5.x (`Should -Be 0`) are incompatible dialects, and the consumers do
# not agree on a version - BeschleunigerBallett's Windows lane pins 3.4.0 while
# ANTfrastructure's own suites need >= 5. A throwing It block is a failed test in
# both, so one file serves every consumer.
#
# All the work happens in BeforeAll and the It blocks only assert on what it
# recorded. That is not style: in Pester 5+ the file body runs in the DISCOVERY
# phase and functions defined there are gone by the time an It body runs (`The
# term 'Resolve-...' is not recognized`, measured 2026-09-07 under Pester 6.1.0),
# whereas BeforeAll runs in the same phase as the assertions.
#
# NETWORK: the reachability check asks the remote (`git ls-remote`, escalating to
# a blobless fetch). That is deliberate - a pin that exists only on the machine
# that made it is precisely what this catches - but it means the suite belongs in
# CI, not in an offline pre-commit hook.

[CmdletBinding()]
param(
    # Superproject working tree to check. Falls back, in order, to
    # $env:ANTFRASTRUCTURE_PIN_CHECK_REPO_ROOT, $env:GITHUB_WORKSPACE (what
    # actions/checkout checked out), and finally the git top level of the
    # current directory. The run-pester-suite composite action can only pass a
    # path, so the environment fallbacks are what make it usable there.
    [string] $RepoRoot,

    # Also inspect nested submodules. Off by default because the cheap CI
    # checkout (`submodules: true`) is top-level only, and recursing over
    # working trees that were never checked out reports every one of them as
    # missing.
    [switch] $Recurse
)

Set-StrictMode -Version Latest

Describe 'Submodule pins' {

    BeforeAll {
        # $RepoRoot / $Recurse are the script parameters; they are read here
        # rather than inside the It bodies because only this scope can still see
        # them under every supported Pester version.
        #
        # The local is $doRecurse, NOT $recurse: PowerShell identifiers are
        # case-insensitive, so `$recurse = [bool]$Recurse` would assign straight
        # back over the [switch] parameter and destroy it (a [bool] is not a
        # [switch]) - which windows/scripts/Invoke-Lint.ps1's AST trap rejects.
        $repoRootArg = $RepoRoot
        $doRecurse = [bool]$Recurse

        $candidates = @(
            $repoRootArg
            $env:ANTFRASTRUCTURE_PIN_CHECK_REPO_ROOT
            $env:GITHUB_WORKSPACE
        )
        $resolvedRoot = $null
        foreach ($candidate in $candidates) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
                    throw "Submodule pin check: repo root '$candidate' does not exist."
                }
                $resolvedRoot = (Resolve-Path -LiteralPath $candidate).Path
                break
            }
        }
        if (-not $resolvedRoot) {
            # Last resort only. This deliberately asks about the CURRENT
            # directory and not about $PSScriptRoot: inside a consumer this file
            # lives in the ANTfrastructure submodule, so its own top level is
            # ANTfrastructure, never the superproject the caller means.
            $topLevel = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
            if ([string]::IsNullOrWhiteSpace($topLevel)) {
                throw ('Submodule pin check: no repo root. Pass -RepoRoot, set ' +
                    'ANTFRASTRUCTURE_PIN_CHECK_REPO_ROOT, or run from inside the repository.')
            }
            $resolvedRoot = (Resolve-Path -LiteralPath $topLevel.Trim()).Path
        }
        $script:PinsRepoRoot = $resolvedRoot

        # WindowsRepoHygiene.Common is located relative to THIS file rather than
        # through a consumer's Resolve-BuildModule: the path is identical whether
        # this repository is the superproject or is checked out at
        # third_party/ANTfrastructure, so it cannot resolve to a stale vendored
        # copy. -Global so the exports survive into every It body.
        $modulePath = Join-Path $PSScriptRoot '..\..\..\windows\scripts\modules\WindowsRepoHygiene.Common.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Submodule pin check: WindowsRepoHygiene.Common not found at $modulePath"
        }
        Import-Module $modulePath -Force -Global -DisableNameChecking

        # `git submodule status` flags: ' ' clean, '+' checked out away from the
        # recorded commit, '-' not initialised, 'U' unmerged conflict.
        $script:PinsStatus = @(
            foreach ($line in @(Get-SubmoduleStatusLine -RepoRoot $script:PinsRepoRoot)) {
                if ($line -match '^(?<flag>[ +\-U])(?<sha>[0-9a-fA-F]+)\s+(?<path>.+?)(?:\s+\(.*\))?$') {
                    [pscustomobject]@{
                        Flag = $Matches['flag']
                        Sha  = $Matches['sha']
                        Path = $Matches['path']
                        Line = $line
                    }
                } else {
                    throw "Submodule pin check: unparseable git submodule status line: '$line'"
                }
            }
        )

        $gitmodules = Join-Path $script:PinsRepoRoot '.gitmodules'
        $script:PinsConfiguredCount = 0
        if (Test-Path -LiteralPath $gitmodules -PathType Leaf) {
            $script:PinsConfiguredCount =
            @(Select-String -LiteralPath $gitmodules -Pattern '^\s*\[submodule ').Count
        }

        $script:PinsUninitialised = @($script:PinsStatus | Where-Object { $_.Flag -eq '-' })

        # Assigned INSIDE each branch, not as `$x = if (...) {...}`: a branch
        # whose value is an empty array writes zero objects to the output
        # stream, so the if-as-expression form silently yields $null and the
        # `.Count` below then dies under Set-StrictMode (seen under Pester 3.4.0,
        # and masked under Pester 6 only because it installs its own strict
        # mode). Every other collection here is built with @( ) for the same
        # reason.
        if ($doRecurse) {
            $drifted = @(Get-SubmodulePinDrift -RepoRoot $script:PinsRepoRoot -Recurse)
        } else {
            $drifted = @(Get-SubmodulePinDrift -RepoRoot $script:PinsRepoRoot)
        }
        $script:PinsDrifted = @($drifted)

        # Reachability costs a network round trip per submodule, so it is done
        # once here rather than per assertion.
        $unreachable = New-Object System.Collections.Generic.List[string]
        foreach ($submodule in $script:PinsStatus) {
            if ($submodule.Flag -eq '-') { continue }
            $result = Test-SubmoduleCommitReachable -SubmodulePath (Join-Path $script:PinsRepoRoot $submodule.Path)
            if ($result.Reachable) {
                Write-Host ("{0} pin {1} reachable via {2}: {3}" -f
                    $submodule.Path, $result.Head, $result.Method, ($result.ContainingRef -join ', '))
            } else {
                Write-Host "$($submodule.Path) HEAD $($result.Head) is on no remote branch."
                $unreachable.Add("$($submodule.Path) @ $($result.Head)")
            }
        }
        $script:PinsUnreachable = @($unreachable)

        Write-Host "Repo root: $script:PinsRepoRoot"
        Write-Host ("Configured submodules: {0}; status lines: {1}" -f
            $script:PinsConfiguredCount, $script:PinsStatus.Count)
    }

    It 'reports a status line for every configured submodule' {
        # A vacuous pass guard. An empty result means the checkout omitted
        # submodules entirely, which would make every check below prove nothing,
        # and a repo with no .gitmodules has nothing to check in the first place
        # - so the two cases are told apart rather than both passing.
        if ($script:PinsConfiguredCount -ne $script:PinsStatus.Count) {
            throw ("Submodule pin check: .gitmodules declares $($script:PinsConfiguredCount) " +
                "submodule(s) but git submodule status reported $($script:PinsStatus.Count) " +
                "line(s) in $script:PinsRepoRoot.")
        }
    }

    It 'has every configured submodule initialised' {
        # Without this the whole suite passes vacuously on a checkout that never
        # fetched submodules: nothing is checked out, so nothing can have
        # drifted and nothing has a HEAD to test for reachability. Running the
        # pin gate against a repo whose pins are not on disk is not a pass, it
        # is a misconfigured job - so it is reported as a failure with the fix.
        if ($script:PinsUninitialised.Count -gt 0) {
            Write-Host 'Submodules configured but not checked out:'
            $script:PinsUninitialised | ForEach-Object { Write-Host "  $($_.Path)" }
            throw ("Submodule pin check: $($script:PinsUninitialised.Count) submodule(s) are not " +
                'checked out, so their pins cannot be verified. Check out with `submodules: true` ' +
                'in actions/checkout, or locally: git submodule update --init --recursive')
        }
    }

    It 'has no submodule checked out away from its recorded commit' {
        if ($script:PinsDrifted.Count -gt 0) {
            Write-Host 'Submodules checked out away from their recorded commit:'
            $script:PinsDrifted | ForEach-Object { Write-Host "  $_" }
            throw ("Submodule pin check: $($script:PinsDrifted.Count) submodule(s) drifted from the " +
                'recorded gitlink. Builds are only supported against the recorded pins. Restore ' +
                'with `git submodule update --checkout --recursive`, or - if the drifted commit is ' +
                'what you actually want - update the gitlink and fix the fallout in the same change.')
        }
    }

    It 'keeps every submodule pin reachable from its remote' {
        # A pin that is on no remote branch cannot be restored by a fresh clone,
        # which turns local-only drift into a build that only works on the
        # machine that made it. The shallow-clone escalation this needs (CI
        # checks out at depth 1) lives in WindowsRepoHygiene.Common.
        if ($script:PinsUnreachable.Count -gt 0) {
            throw ("Submodule pin check: $($script:PinsUnreachable.Count) pin(s) cannot be restored " +
                "by a fresh clone - $($script:PinsUnreachable -join '; '). Push the commit to its " +
                'remote, or move the pin to one that is already there.')
        }
    }
}
