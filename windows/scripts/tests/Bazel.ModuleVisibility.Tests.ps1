#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The Bazel module's shared helper in the stage's bazelmods\ layout and a checkout's; a real Bazel run is not covered.

Describe 'WindowsBazel.Common sees its shared helper in a cold session' {
    It 'works in the stage layout and the checkout layout, and refuses a missing companion (mutation)' {
        $modules = Join-Path (Get-RepoRoot) 'windows\scripts\modules'
        $root = New-TestDir -Prefix 'bazel-visibility'
        try {
            $stage = Join-Path $root 'stage'
            $flat = Join-Path $root 'flat'
            $alone = Join-Path $root 'alone\bazelmods'
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $stage 'bazelmods'), (Join-Path $stage 'modules'), $flat, $alone
            Copy-Item -LiteralPath (Join-Path $modules 'WindowsBazel.Common.psm1') -Destination (Join-Path $stage 'bazelmods'), $flat, $alone
            Copy-Item -LiteralPath (Join-Path $modules 'WindowsScripts.Shared.psm1') -Destination (Join-Path $stage 'modules')
            Copy-Item -LiteralPath (Join-Path $modules 'WindowsScripts.Shared.psm1') -Destination $flat
            $probe = {
                param($moduleDir)
                $command = "Import-Module '$moduleDir\WindowsBazel.Common.psm1'; `$p = Set-BazelProcessEnv -Values @{ BAZEL_VISIBILITY_PROBE = 'on' }; if (`$env:BAZEL_VISIBILITY_PROBE -ne 'on') { exit 9 }; exit 0"
                $output = & pwsh -NoProfile -Command $command 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
            }
            foreach ($dir in (Join-Path $stage 'bazelmods'), $flat) {
                $run = & $probe $dir
                Assert-Equal 0 $run.Code "$dir must see Set-ProcessEnvironmentValue: $($run.Output)"
            }
            $missing = & $probe $alone
            Assert-True ($missing.Code -ne 0 -and $missing.Output -match 'needs WindowsScripts\.Shared') "a missing companion fails at import: $($missing.Output)"
        } finally { Remove-TestDir $root }
    }
}
