#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The Bazel module's shared helper in the stage's bazelmods\ layout and a checkout's; a real Bazel run is not covered.

function Copy-BazelLayoutModule {
    param([string]$Name, [string[]]$Target)
    $source = Join-Path (Get-RepoRoot) "windows\scripts\modules\$Name"
    foreach ($dir in $Target) {
        $null = New-Item -ItemType Directory -Force -Path $dir
        Copy-Item -LiteralPath $source -Destination $dir
    }
}

function Invoke-BazelVisibilityProbe {
    param([string]$ModuleDir)
    $command = "Import-Module '$ModuleDir\WindowsBazel.Common.psm1'; `$p = Set-BazelProcessEnv -Values @{ BAZEL_VISIBILITY_PROBE = 'on' }; if (`$env:BAZEL_VISIBILITY_PROBE -ne 'on') { exit 9 }; exit 0"
    $output = & pwsh -NoProfile -Command $command 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
}

Describe 'WindowsBazel.Common sees its shared helper in a cold session' {
    It 'works in the stage layout and the checkout layout, and refuses a missing companion (mutation)' {
        $root = New-TestDir -Prefix 'bazel-visibility'
        try {
            Copy-BazelLayoutModule -Name 'WindowsBazel.Common.psm1' -Target "$root\stage\bazelmods", "$root\flat", "$root\alone\bazelmods"
            Copy-BazelLayoutModule -Name 'WindowsScripts.Shared.psm1' -Target "$root\stage\modules", "$root\flat"
            foreach ($dir in "$root\stage\bazelmods", "$root\flat") {
                $run = Invoke-BazelVisibilityProbe -ModuleDir $dir
                Assert-Equal 0 $run.Code "$dir must see Set-ProcessEnvironmentValue: $($run.Output)"
            }
            $missing = Invoke-BazelVisibilityProbe -ModuleDir "$root\alone\bazelmods"
            Assert-True ($missing.Code -ne 0 -and $missing.Output -match 'needs WindowsScripts\.Shared') "a missing companion fails at import: $($missing.Output)"
        } finally { Remove-TestDir $root }
    }
}
