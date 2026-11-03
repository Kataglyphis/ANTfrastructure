#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# New-PythonAppBundle's lock data rows; not covered: the bundle build around them or the Linux twin.

Describe 'New-PythonAppBundle lock data rows' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/python/New-PythonAppBundle.ps1' -FunctionName @('Copy-PythonAppBundleLock', 'Copy-PythonAppBundleData'))
    function Resolve-PythonAppPath { param([string]$Root, [string]$Path) Join-Path $Root $Path }
    $script:lockBody = "# sha256 file url`naa  other_model.onnx  https://example.invalid/other_model.onnx`nbb  other_model.LICENSE  https://example.invalid/other_model.LICENSE`n"
    $script:lockRow = @{ data = @(@{ lock = 'models/models.lock'; to = 'share/app/models' }) }

    function Write-LockFixture {
        param([string]$Dir, [string]$Body, [string[]]$Named = @('other_model.onnx', 'other_model.LICENSE'))
        $models = (New-Item -ItemType Directory -Force -Path "$Dir/models").FullName
        Set-Content -NoNewline -LiteralPath "$models/models.lock" -Value $Body
        $Named | ForEach-Object { Set-Content -NoNewline -LiteralPath "$models/$_" -Value $_ }
    }

    function Assert-LockRefused {
        param([string]$Dir, [string]$Pattern)
        Assert-Throws { Copy-PythonAppBundleData -App $script:lockRow -RepoRoot $Dir -Bundle (Join-Path $Dir 'bundle') 6>$null } -MessagePattern $Pattern
    }

    It 'ships the lock and every file it names under the names the lock gives' {
        Invoke-InTestDir {
            param($dir)
            Write-LockFixture -Dir $dir -Body $script:lockBody
            $bundle = Join-Path $dir 'bundle'
            Copy-PythonAppBundleData -App $script:lockRow -RepoRoot $dir -Bundle $bundle 6>$null
            $models = Join-Path $bundle 'share/app/models'
            Assert-Equal 'other_model.onnx' ([IO.File]::ReadAllText((Join-Path $models 'other_model.onnx')))
            Assert-Equal 'other_model.LICENSE' ([IO.File]::ReadAllText((Join-Path $models 'other_model.LICENSE')))
            Assert-Equal $script:lockBody ([IO.File]::ReadAllText((Join-Path $models 'models.lock')))
        }
    }

    It 'fails when a named file is absent' {
        Invoke-InTestDir {
            param($dir)
            Write-LockFixture -Dir $dir -Body $script:lockBody -Named 'other_model.onnx'
            Assert-LockRefused -Dir $dir -Pattern 'other_model.LICENSE'
        }
    }

    It 'refuses an empty lock and a lock naming a path' {
        Invoke-InTestDir {
            param($dir)
            Write-LockFixture -Dir $dir -Body "# sha256 file url`n"
            Assert-LockRefused -Dir $dir -Pattern 'names no file'
            Write-LockFixture -Dir $dir -Body "aa  ..\escape.onnx  https://example.invalid/x`n"
            Assert-LockRefused -Dir $dir -Pattern 'names a path, not a file'
        }
    }
}
