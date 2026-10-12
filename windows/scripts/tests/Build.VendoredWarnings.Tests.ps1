#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Hub #183: vendored code's GCC-style -Wall reaches clang-cl as -Weverything and floods the stage logs.

Describe 'Vendored builds compile with warnings off (hub #183)' {
    $script:Root = Get-RepoRoot

    It 'wraps <What> in CL=/w, which clang-cl reads before its own flags, never _CL_, and restores the caller''s CL' {
        foreach ($case in @(
                @{ What = 'x265'; Path = 'windows\scripts\build\Build-FfmpegCodecs.ps1'; Inside = "Invoke-CmakeConfigure -SourceDir \(Join-Path \`$x265Root 'source'\)" }
                @{ What = 'VVL and its dependencies'; Path = 'windows\scripts\build\Build-VulkanValidationLayers.ps1'; Inside = 'foreach \(\$dep in \$plan\)' })) {
            $text = [IO.File]::ReadAllText((Join-Path $script:Root $case.Path))
            Assert-Match ("(?s)\`$callerCl = \`$env:CL\s*\r?\n\s*\`$env:CL = '/w'\s*\r?\n\s*try \{\s*\r?\n\s*" + $case.Inside) $text "$($case.What): /w set right before the vendored build"
            Assert-Match '\} finally \{ if \(\$null -eq \$callerCl\) \{ Remove-Item Env:CL -ErrorAction SilentlyContinue \} else \{ \$env:CL = \$callerCl \} \}' $text "$($case.What): restored on every exit"
            # clang-cl appends _CL_ after CMake's `-- <source>`, where /w is a file name (bk-20261012-190400).
            Assert-False ($text -match '\$env:_CL_') "$($case.What): never _CL_"
        }
    }
}
