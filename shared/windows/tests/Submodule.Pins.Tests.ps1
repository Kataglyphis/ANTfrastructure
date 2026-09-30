#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Guards a repository's submodule pins against drift; run from the hub by any consumer (submodule-pins.yml), never copied.

[CmdletBinding()]
param(
    # Superproject to check; falls back to $env:ANTFRASTRUCTURE_PIN_CHECK_REPO_ROOT, $env:GITHUB_WORKSPACE, then the cwd's top level.
    [string] $RepoRoot,

    # Also inspect nested submodules; off because CI's `submodules: true` checkout is top-level only.
    [switch] $Recurse
)

Set-StrictMode -Version Latest

# Plain `throw`, never `Should`: consumers run the incompatible Pester 3.x and 5.x+ dialects.
Describe 'Submodule pins' {

    # All work runs here: in Pester 5+ functions defined at file level are gone by the time an It runs.
    BeforeAll {
        # Params are visible here under every Pester version; $doRecurse, since `$recurse` would overwrite the [switch].
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
            # The cwd, not $PSScriptRoot, whose top level inside a consumer is the submodule.
            $topLevel = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
            if ([string]::IsNullOrWhiteSpace($topLevel)) {
                throw ('Submodule pin check: no repo root. Pass -RepoRoot, set ' +
                    'ANTFRASTRUCTURE_PIN_CHECK_REPO_ROOT, or run from inside the repository.')
            }
            $resolvedRoot = (Resolve-Path -LiteralPath $topLevel.Trim()).Path
        }
        $script:PinsRepoRoot = $resolvedRoot

        # Relative to this file, never a stale vendored copy; -Global so the exports reach every It body.
        $modulePath = Join-Path $PSScriptRoot '..\..\..\windows\scripts\modules\WindowsRepoHygiene.Common.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Submodule pin check: WindowsRepoHygiene.Common not found at $modulePath"
        }
        Import-Module $modulePath -Force -Global -DisableNameChecking

        # Status flags: ' ' clean, '+' away from the recorded commit, '-' not initialised, 'U' conflicted.
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

        # Assigned inside each branch: `$x = if` yields $null for an empty array, and `.Count` dies under StrictMode.
        if ($doRecurse) {
            $drifted = @(Get-SubmodulePinDrift -RepoRoot $script:PinsRepoRoot -Recurse)
        } else {
            $drifted = @(Get-SubmodulePinDrift -RepoRoot $script:PinsRepoRoot)
        }
        $script:PinsDrifted = @($drifted)

        # A network round trip per submodule, done once here; hence CI, not an offline pre-commit hook.
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
        # Tells a checkout that omitted submodules apart from a repo that has none.
        if ($script:PinsConfiguredCount -ne $script:PinsStatus.Count) {
            throw ("Submodule pin check: .gitmodules declares $($script:PinsConfiguredCount) " +
                "submodule(s) but git submodule status reported $($script:PinsStatus.Count) " +
                "line(s) in $script:PinsRepoRoot.")
        }
    }

    It 'has every configured submodule initialised' {
        # Otherwise a checkout without submodules passes every check vacuously.
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
        # A pin on no remote branch cannot be restored by a fresh clone.
        if ($script:PinsUnreachable.Count -gt 0) {
            throw ("Submodule pin check: $($script:PinsUnreachable.Count) pin(s) cannot be restored " +
                "by a fresh clone - $($script:PinsUnreachable -join '; '). Push the commit to its " +
                'remote, or move the pin to one that is already there.')
        }
    }
}
