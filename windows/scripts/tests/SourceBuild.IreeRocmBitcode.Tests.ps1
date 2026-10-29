#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: whether TheRock's bitcode links into an AMD GPU executable; that needs the rocm image and a GPU.

Describe 'Build-IreeFromSource: device bitcode from the rocm layer' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-IreeFromSource.ps1' -FunctionName 'Get-IreeRocmDeviceBitcodeArg')
    $cmake = @'
set(IREE_TARGET_BACKEND_ROCM_DEVICE_BC_PATH "" CACHE PATH
    "Optional path to load device bitcode from (default to dynamic fetch)")
'@

    It 'points IREE at the rocm layer''s ocml/ockl and refuses a missing file or a dropped option (mutation)' {
        Invoke-InTestDir -Files @{ 'bc/ocml.bc' = 'x'; 'bc/ockl.bc' = 'x'; 'partial/ocml.bc' = 'x' } -Body {
            param($d)
            $f = Join-Path $d 'CMakeLists.txt'
            [System.IO.File]::WriteAllText($f, $cmake)
            $bc = Join-Path $d 'bc'
            Assert-Equal "-DIREE_TARGET_BACKEND_ROCM_DEVICE_BC_PATH=$($bc -replace '\\', '/')" (Get-IreeRocmDeviceBitcodeArg -CMakeListsPath $f -BitcodeDir $bc) 'local bitcode, no download'
            Assert-Throws { Get-IreeRocmDeviceBitcodeArg -CMakeListsPath $f -BitcodeDir (Join-Path $d 'partial') } 'ockl missing' -MessagePattern 'ockl\.bc missing'
            [System.IO.File]::WriteAllText($f, ($cmake -replace 'set\(IREE_TARGET_BACKEND_ROCM_DEVICE_BC_PATH', 'set(SOMETHING_ELSE'))
            Assert-Throws { Get-IreeRocmDeviceBitcodeArg -CMakeListsPath $f -BitcodeDir $bc } 'option gone' -MessagePattern 'no longer takes'
        }
    }
}
