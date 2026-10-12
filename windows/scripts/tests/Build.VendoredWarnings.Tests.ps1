#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Hub #183: vendored code's GCC-style -Wall reaches clang-cl as -Weverything and floods the stage logs.

Describe 'Vendored builds compile with warnings off (hub #183)' {
    $script:Root = Get-RepoRoot

    It 'wraps <What> in _CL_=/w, which clang-cl appends after its own flags, and restores the caller''s _CL_' {
        foreach ($case in @(
                @{ What = 'x265'; Path = 'windows\scripts\build\Build-FfmpegCodecs.ps1'; Inside = "Invoke-CmakeConfigure -SourceDir \(Join-Path \`$x265Root 'source'\)" }
                @{ What = 'VVL and its dependencies'; Path = 'windows\scripts\build\Build-VulkanValidationLayers.ps1'; Inside = 'foreach \(\$dep in \$plan\)' })) {
            $text = [IO.File]::ReadAllText((Join-Path $script:Root $case.Path))
            Assert-Match ("(?s)\`$callerCl = \`$env:_CL_\s*\r?\n\s*\`$env:_CL_ = '/w'\s*\r?\n\s*try \{\s*\r?\n\s*" + $case.Inside) $text "$($case.What): /w set right before the vendored build"
            Assert-Match '\} finally \{ if \(\$null -eq \$callerCl\) \{ Remove-Item Env:_CL_ -ErrorAction SilentlyContinue \} else \{ \$env:_CL_ = \$callerCl \} \}' $text "$($case.What): restored on every exit"
        }
    }
}
