#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

# Keeps generated output out of a repository's index; run from the hub by any consumer, never copied.

[CmdletBinding()]
param(
    # Repository to check; falls back to $env:GITHUB_WORKSPACE, then the cwd's top level.
    [string] $RepoRoot,

    # Git pathspecs of generated output; empty reads -PatternFile.
    [string[]] $Pattern = @(),

    # One pathspec per line, '#' to the end of a line is a comment; empty is <RepoRoot>\scripts\windows\generated-artifacts.txt.
    [string] $PatternFile
)

Set-StrictMode -Version Latest

# Plain `throw`, never `Should`: consumers run the incompatible Pester 3.x and 5.x+ dialects.
Describe 'Repo generated artifacts' {

    BeforeAll {
        # Each It rethrows a setup error: Pester 6.1 reports a throw from BeforeAll as an escaped 'break'.
        $script:ArtifactsSetupError = $null
        try {
            # Params are visible here under every Pester version, but not inside an It under Pester 5.
            $root = $RepoRoot
            if (-not $root) { $root = $env:GITHUB_WORKSPACE }
            # The cwd, not $PSScriptRoot, whose top level inside a consumer is the submodule.
            if (-not $root) { $root = "$(& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)".Trim() }
            if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
                throw "Generated-artifact check: no repo root ('$root'). Pass -RepoRoot, set GITHUB_WORKSPACE, or run from inside the repository."
            }
            $root = (Resolve-Path -LiteralPath $root).Path

            $patterns = @($Pattern | Where-Object { $_ })
            if ($patterns.Count -eq 0) {
                $file = if ($PatternFile) { $PatternFile } else { Join-Path $root 'scripts\windows\generated-artifacts.txt' }
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    throw "Generated-artifact check: no -Pattern and no pattern file $file (one git pathspec per line)."
                }
                $patterns = @(Get-Content -LiteralPath $file | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
                if ($patterns.Count -eq 0) { throw "Generated-artifact check: $file names no pathspec, so the check would grade nothing." }
            }

            # Relative to this file, never a stale vendored copy; -Global so the exports reach every It body.
            Import-Module (Join-Path $PSScriptRoot '..\..\..\windows\scripts\modules\WindowsRepoHygiene.Common.psm1') -Force -Global -DisableNameChecking
            $script:ArtifactsRoot = $root
            $script:ArtifactsFound = @{
                ignored   = @(Get-TrackedIgnoredFile -RepoRoot $root)
                generated = @(Get-TrackedGeneratedArtifact -RepoRoot $root -Pattern $patterns)
            }
            Write-Host "Repo root: $root; generated-output pathspecs: $($patterns -join ' ')"
        } catch {
            $script:ArtifactsSetupError = $_.Exception.Message
        }
        # A scriptblock, not a function: Pester 3.4 and 5+ agree on what an It body sees of $script:.
        $script:AssertNoArtifact = {
            param([string]$Kind, [string]$What, [string]$Fix)
            if ($script:ArtifactsSetupError) { throw $script:ArtifactsSetupError }
            $files = $script:ArtifactsFound[$Kind]
            if ($files.Count -eq 0) { return }
            $files | ForEach-Object { Write-Host "  $_" }
            throw "Generated-artifact check: $($files.Count) tracked file(s) in $script:ArtifactsRoot $What. Fix with $Fix"
        }
    }

    It 'has no tracked file that is also gitignored' {
        & $script:AssertNoArtifact ignored 'are also gitignored' (
            'git rm --cached <path>; if the file is tracked on purpose, the .gitignore rule is what is wrong.')
    }

    It 'has no tracked file under a known generated-output path' {
        & $script:AssertNoArtifact generated 'are generated output' 'git rm -r --cached <path>, then add the path to .gitignore.'
    }
}
