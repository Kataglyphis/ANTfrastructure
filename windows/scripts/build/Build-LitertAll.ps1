# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
# The media-litert chain in one RUN, bind-mounted so an edit re-keys that branch alone.

[CmdletBinding()]
param(

    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts',
    # Skip the stages before the named one; BuildKit replays cached RUN vertices, there is no container to resume.
    [string]$ResumeFrom = '',
    # Stop after the named stage (inclusive).
    [string]$Until = '',
    # Scrub scratch inside this layer; see Complete-SourceBuildChain for why a later scrub cannot shrink it.
    [switch]$ScrubAfter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# LiteRT, then LiteRT-LM on its install; only LiteRT cross-builds. See docs/windows-cross-builds.md § LiteRT-LM
$litertStages = @(
    @{ Name = 'LiteRT'; Script = 'Build-LitertFromSource.ps1'; SourceDir = 'C:\temp\litert-src' }
)
if (Test-WindowsCrossTarget) {
    Write-Host ("media-litert: LiteRT-LM stage SKIPPED on the $(Get-WindowsTargetArch) cross lane -- upstream's bazel " +
                'path has no windows-arm64 config and default-links an x86_64-only prebuilt (see backlog; ' +
                'plain LiteRT above is unaffected and builds).')
    # The merge fan-in COPYs this path unconditionally, so a cross branch leaves an empty tree with a marker.
    $lmRoot = Join-Path $InstallDir 'lib\litert-lm'
    [void](Write-AbsentOnCrossMarker -Root $lmRoot -Component 'LiteRT-LM' -EnsureDirs @('include', 'bin') -Reason @(
        'Its ACTIVE build path is Bazel, where two blockers are real: upstream''s .bazelrc has no'
        'windows-arm64 config, and the x86_64-only libGemmaModelConstraintProvider prebuilt sits in the'
        'default Windows dependency graph (severable via the litert_lm_fst_constraints_disabled'
        'config_setting). Plain LiteRT IS built on this lane (see C:\runtime\lib\litert).'
    ))
} else {
    $litertStages += @{ Name = 'LiteRT-LM'; Invoke = { param($sd, $id)
            # The repository cache is shared across runs; output_base stays container-local.
            & (Join-Path $sd 'Build-LitertLmBazel.ps1') -InstallDir $id -RepositoryCache ([string]$env:BAZEL_REPO_CACHE)
        } }
}
Invoke-SourceBuildChain -Label 'media-litert' -InstallDir $InstallDir -ScriptDir $ScriptDir `
    -StartAt $ResumeFrom -Until $Until -Stages $litertStages

Complete-SourceBuildChain -Label 'media-litert' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0