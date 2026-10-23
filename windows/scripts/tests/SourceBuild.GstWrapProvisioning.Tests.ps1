#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Failures must be returned, since the caller owns the fail-closed throw and a module's $script: is module scope.

function script:Invoke-GstWrapFixture {
    param([string]$Wrap = '')
    Invoke-InTestDir -Prefix gstwrap- -Body { param($dir)
        New-Item -ItemType Directory -Path (Join-Path $dir 'libffi') -Force | Out-Null
        if ($Wrap) { Set-Content -LiteralPath (Join-Path $dir 'doomed.wrap') -Value $Wrap }
        Invoke-GstWrapProvisioning -SubprojectDir $dir -TempDir $dir -LibffiVersion '0.0' -Logger { param($m) }
    }.GetNewClosure()
}

Describe 'Invoke-GstWrapProvisioning (#88 failure collection)' {
    BeforeAll { $script:modPath = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsMeson.Common.psm1' }

    It 'returns an EMPTY COUNTABLE result when there is nothing to provision' {
        $r = @(Invoke-GstWrapFixture)
        $r.Count | Should -Be 0
    }

    It 'RETURNS a failure (never swallows it) when a wrap-git tarball cannot be fetched' {
        $r = @(Invoke-GstWrapFixture -Wrap @'
[wrap-git]
directory = doomed
url = https://invalid.invalid/kataglyphis/doomed.git
revision = deadbeef
'@)
        $r.Count | Should -BeGreaterThan 0 -Because 'a dead wrap must reach the caller, not just the log'
        ($r -join ' ') | Should -Match 'doomed'

    }

    It 'accumulates into a LOCAL list, not the module scope' {
        # A `$script:` accumulator would live in module scope, and the returned list would stop being the truth.
        $fn = (Get-ScriptFunctionDefinition -ScriptPath $script:modPath -FunctionName Invoke-GstWrapProvisioning).ToString()
        $fn | Should -Not -Match '\$script:' -Because 'a module script-scope list would not reach the caller'
        # The call site @()-wraps; a comma-wrap would nest the array and make .Count read 1 either way.
        $fn | Should -Not -Match 'return\s*,' -Because 'the caller @()-wraps; a comma-wrap nests the result and breaks the #88 count'
    }
}
