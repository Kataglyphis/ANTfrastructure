#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: Get-PythonAbiTag, which asks a real interpreter (New-PythonAppBundle.ps1 runs it inside :winamd64).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

# Leaves exactly -Names as wheels in -Dir and returns the name Select-PythonAppWheel picks from them.
function script:Get-PickedWheel {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][string]$AbiTag)
    Get-ChildItem -LiteralPath $Dir -Filter '*.whl' -File | Remove-Item
    foreach ($n in $Names) { Set-Content -LiteralPath (Join-Path $Dir $n) -Value 'wheel' -Encoding ASCII }
    $wheels = @(Get-ChildItem -LiteralPath $Dir -Filter '*.whl' -File | Sort-Object Name)
    return (Select-PythonAppWheel -Wheels $wheels -AbiTag $AbiTag).Name
}

Describe 'Select-PythonAppWheel' {

    It 'takes the runtime ABI over its free-threaded twin, then abi3, then the pure wheel when no binary exists' {
        Invoke-InTestDir { param($d)
            $both = @('app-1.0-cp314-cp314t-win_amd64.whl', 'app-1.0-cp314-cp314-win_amd64.whl', 'app-1.0-py3-none-any.whl')
            $cases = @(
                @('cp314', 'app-1.0-cp314-cp314-win_amd64.whl', $both),
                @('cp314t', 'app-1.0-cp314-cp314t-win_amd64.whl', $both),
                @('cp314', 'app-1.0-cp312-abi3-win_amd64.whl', @('app-1.0-cp312-abi3-win_amd64.whl', 'app-1.0-py3-none-any.whl')),
                @('cp314', 'app-1.0-py3-none-any.whl', @('app-1.0-py3-none-any.whl'))
            )
            foreach ($c in $cases) {
                Assert-Equal $c[1] (Get-PickedWheel -Dir $d -Names $c[2] -AbiTag $c[0]) "$($c[0]) from $($c[2] -join ', ')"
            }
        }
    }

    It 'refuses binaries built for another ABI instead of bundling them or the pure wheel' {
        Invoke-InTestDir { param($d)
            $names = @('app-1.0-cp314-cp314t-win_amd64.whl', 'app-1.0-py3-none-any.whl')
            Assert-Throws { Get-PickedWheel -Dir $d -Names $names -AbiTag 'cp314' } -MessagePattern 'No cp314 wheel, only app-1\.0-cp314-cp314t'
        }
    }
}
