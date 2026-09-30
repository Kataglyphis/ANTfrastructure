#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Failures must be returned, since the caller owns the fail-closed throw and a module's $script: is module scope.

Describe 'Invoke-GstWrapProvisioning (#88 failure collection)' {

    BeforeAll {
        $script:modPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'windows\scripts\modules\WindowsMeson.Common.psm1'
        if (-not (Test-Path $script:modPath)) {
            $script:modPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsMeson.Common.psm1'
        }
    }

    It 'returns an EMPTY COUNTABLE result when there is nothing to provision' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("gstwrap-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir 'libffi') -Force | Out-Null   # skip the libffi fetch
        try {
            $r = @(Invoke-GstWrapProvisioning -SubprojectDir $dir -TempDir $dir -LibffiVersion '0.0' -Logger { param($m) })
            # An unwrapped empty return is $null under StrictMode, so the caller's gate would never fire.
            $r.Count | Should -Be 0
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'RETURNS a failure (never swallows it) when a wrap-git tarball cannot be fetched' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("gstwrap-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir 'libffi') -Force | Out-Null
        # An unroutable host: fails fast without depending on the network being down.
        @'
[wrap-git]
directory = doomed
url = https://invalid.invalid/kataglyphis/doomed.git
revision = deadbeef
'@ | Set-Content -Path (Join-Path $dir 'doomed.wrap')
        try {
            $r = @(Invoke-GstWrapProvisioning -SubprojectDir $dir -TempDir $dir -LibffiVersion '0.0' -Logger { param($m) })
            $r.Count | Should -BeGreaterThan 0 -Because 'a dead wrap must reach the caller, not just the log'
            ($r -join ' ') | Should -Match 'doomed'
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accumulates into a LOCAL list, not the module scope' {
        # A `$script:` accumulator would live in module scope, and the returned list would stop being the truth.
        $src = Get-Content $script:modPath -Raw
        $fn = [regex]::Match($src, '(?ms)^function Invoke-GstWrapProvisioning \{.*?^\}')
        $fn.Success | Should -BeTrue -Because 'the function must be findable for this guard to mean anything'
        $fn.Value | Should -Not -Match '\$script:' -Because 'inside a module `$script:` is MODULE scope; the caller would read its own empty variable and the #88 gate would never fire'
        # The call site @()-wraps; a comma-wrap would nest the array and make .Count read 1 either way.
        $fn.Value | Should -Not -Match 'return\s*,' -Because 'the caller @()-wraps; a comma-wrap nests the result and breaks the #88 count'
    }
}
