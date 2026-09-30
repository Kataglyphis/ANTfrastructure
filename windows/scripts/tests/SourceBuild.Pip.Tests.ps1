#requires -Version 7.0
# A fake interpreter (a .bat that exits non-zero) drives Invoke-CpythonPip's exit-code handling without Python.

Describe 'Invoke-CpythonPip' {

    It 'throws on a non-zero pip exit' {
        Invoke-InTestDir { param($dir)
            $fake = Join-Path $dir 'python.bat'   # stands in for the interpreter; always exits non-zero
            Set-Content -LiteralPath $fake -Value 'exit /b 7' -Encoding ASCII
            Assert-Throws { Invoke-CpythonPip -Python @{ Exe = $fake } -Arguments @('install', 'x') } 'a non-zero pip exit must throw'
        }
    }

    It 'warns instead of throwing when -Optional is set' {
        Invoke-InTestDir { param($dir)
            $fake = Join-Path $dir 'python.bat'
            Set-Content -LiteralPath $fake -Value 'exit /b 7' -Encoding ASCII
            Invoke-CpythonPip -Python @{ Exe = $fake } -Arguments @('install', 'x') -Optional
            Assert-True $true 'a failed -Optional pip install continued without throwing'
        }
    }

    It 'throws a clear error when the interpreter is missing (before running pip)' {
        Assert-Throws { Invoke-CpythonPip -Python @{ Exe = 'C:\nope\python.exe' } -Arguments @('--version') } 'missing interpreter must throw'
    }
}
