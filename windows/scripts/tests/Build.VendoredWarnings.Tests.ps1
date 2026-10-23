#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: emitted compiler diagnostics; this source-wiring check guards hub #183's clang-cl warning flag.

function Assert-VendoredWarningScope {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$Inside, [switch]$SharedScope)
    if ($SharedScope) {
        $scopeStart = $Text.IndexOf("Invoke-WithProcessEnvironment -Environment @{ CL = '/w' } -ScriptBlock {", [StringComparison]::Ordinal)
        $scopeEnd = if ($scopeStart -ge 0) { $Text.IndexOf('    foreach ($name in "$LayerName.dll", "$LayerName.json")', $scopeStart, [StringComparison]::Ordinal) } else { -1 }
        Assert-True ($scopeStart -ge 0 -and $scopeEnd -gt $scopeStart) "$What`: scoped warning flag encloses the vendored builds"
        $scope = $Text.Substring($scopeStart, $scopeEnd - $scopeStart)
        Assert-Match $Inside $scope "$What`: /w set before the dependency builds"
        Assert-Match 'Invoke-CmakeConfigure -SourceDir \$dep.SourceDir' $scope "$What`: dependency configure uses /w"
        Assert-Match 'Invoke-NinjaBuildWithRetry -BuildDir \$buildDir' $scope "$What`: dependency build uses /w"
        Assert-Match 'Invoke-CmakeConfigure -SourceDir \$vvlSource' $scope "$What`: layer configure uses /w"
        Assert-Match 'Invoke-NinjaBuildWithRetry -BuildDir \$vvlBuild' $scope "$What`: layer build uses /w"
    } else {
        Assert-Match ("(?s)\`$callerCl = \`$env:CL\s*\r?\n\s*\`$env:CL = '/w'\s*\r?\n\s*try \{\s*\r?\n\s*" + $Inside) $Text "$What`: /w set right before the vendored build"
        Assert-Match '\} finally \{ if \(\$null -eq \$callerCl\) \{ Remove-Item Env:CL -ErrorAction SilentlyContinue \} else \{ \$env:CL = \$callerCl \} \}' $Text "$What`: restored on every exit"
    }
    # clang-cl appends _CL_ after CMake's `-- <source>`, where /w is a file name (bk-20261012-190400).
    Assert-False ($Text -match '\$env:_CL_') "$What`: never _CL_"
}

Describe 'Vendored builds compile with warnings off (hub #183)' {
    $script:Root = Get-RepoRoot

    It 'wraps <What> in CL=/w, which clang-cl reads before its own flags, never _CL_, and restores the caller''s CL' {
        foreach ($case in @(
                @{ What = 'x265'; Path = 'windows\scripts\build\Build-FfmpegCodecs.ps1'; Inside = "Invoke-CmakeConfigure -SourceDir \(Join-Path \`$x265Root 'source'\)"; SharedScope = $false }
                @{ What = 'VVL and its dependencies'; Path = 'windows\scripts\build\Build-VulkanValidationLayers.ps1'; Inside = 'foreach \(\$dep in \$plan\)'; SharedScope = $true })) {
            $text = [IO.File]::ReadAllText((Join-Path $script:Root $case.Path))
            Assert-VendoredWarningScope -Text $text -What $case.What -Inside $case.Inside -SharedScope:$case.SharedScope
        }
    }

    It 'rejects a VVL mutation that changes the scoped warning flag' {
        $path = Join-Path $script:Root 'windows\scripts\build\Build-VulkanValidationLayers.ps1'
        $source = [IO.File]::ReadAllText($path)
        $mutated = $source.Replace("@{ CL = '/w' }", "@{ CL = '/wrong' }")
        Assert-Throws {
            Assert-VendoredWarningScope -Text $mutated -What 'VVL and its dependencies' -Inside 'foreach \(\$dep in \$plan\)' -SharedScope
        } -MessagePattern 'scoped warning flag encloses the vendored builds'
    }
}
