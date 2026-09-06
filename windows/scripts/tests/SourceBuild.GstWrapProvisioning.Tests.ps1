#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Invoke-GstWrapProvisioning's #88 contract, lifted out of Build-GstreamerFromSource.ps1
# on 2026-08-31. The property that matters is the one the extraction could have broken
# SILENTLY: failures must be RETURNED to the caller, because the caller owns the
# fail-closed throw. A module function accumulating into `$script:` writes MODULE scope,
# the caller's own `$script:wrapFailures` would stay empty, and a broken provisioning run
# would ship a feature-reduced GStreamer -- exactly what #88 exists to prevent.

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
            # .Count must not throw: an un-wrapped empty return is $null under StrictMode,
            # which is how the caller's #88 gate would silently never fire.
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
        # Guards the specific regression: if the function ever goes back to
        # `$script:wrapFailures += ...`, that variable becomes visible in the
        # module's own scope and the returned list stops being the truth.
        $src = Get-Content $script:modPath -Raw
        $fn = [regex]::Match($src, '(?ms)^function Invoke-GstWrapProvisioning \{.*?^\}')
        $fn.Success | Should -BeTrue -Because 'the function must be findable for this guard to mean anything'
        $fn.Value | Should -Not -Match '\$script:' -Because 'inside a module `$script:` is MODULE scope; the caller would read its own empty variable and the #88 gate would never fire'
        # The call site @()-wraps. A comma-wrap here would NEST the array, making .Count
        # read 1 for an empty and a filled list alike -- #88 firing on every green build.
        $fn.Value | Should -Not -Match 'return\s*,' -Because 'the caller @()-wraps; a comma-wrap nests the result and breaks the #88 count'
    }
}
