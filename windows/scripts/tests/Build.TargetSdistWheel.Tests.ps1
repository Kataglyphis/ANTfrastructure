#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# A table row without its pins throws hours into the arm64 merge, and a shim without the target builds x64 objects (CON111).

Describe 'Build-TargetSdistWheel: pinned sdists, clang-cl for the target' {

    $script:tsPath = Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TargetSdistWheel.ps1'
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-TargetSdistWheel.ps1' -FunctionName 'Get-TargetSdistTable')

    It 'pins a version and a 64-hex sdist SHA256 for every row' {
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $table = Get-TargetSdistTable
        Assert-True ($table.Count -ge 1) 'the table names at least psutil'
        foreach ($name in $table.Keys) {
            Assert-Match '^\d+(\.\d+)+$' $pins["$($table[$name])_VERSION"] "$($table[$name])_VERSION"
            Assert-Match '^[0-9a-f]{64}$' $pins["$($table[$name])_SDIST_SHA256"] "$($table[$name])_SDIST_SHA256"
        }
    }

    It 'compiles for the target through the clang-cl shim and refuses an MSVC-linked member (mutation)' {
        $text = Get-Content -LiteralPath $script:tsPath -Raw
        foreach ($needle in @('$env:CL = "--target=$((Get-WindowsTargetArchInfo).ClangTriple) /clang:-fcommon"',
                "(Join-Path `$LlvmBin 'clang-cl.exe') -Destination (Join-Path `$shim 'cl.exe')", "carry MSVC's Rich header", '-ExpectedSha256 $sha')) {
            Assert-True $text.Contains($needle) "the script holds $needle"
        }
    }

    It 'runs in the merge before the deps gate, with its modules mounted' {
        $merge = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-merge-builder'))
        $build = $merge.IndexOf("& 'C:\bkmnt\Build-TargetSdistWheel.ps1'")
        $gate = $merge.IndexOf("& 'C:\bkmnt\Copy-TargetPythonDeps.ps1'")
        Assert-True ($build -gt 0 -and $gate -gt $build) 'Build-TargetSdistWheel.ps1 runs before Copy-TargetPythonDeps.ps1'
    }
}
