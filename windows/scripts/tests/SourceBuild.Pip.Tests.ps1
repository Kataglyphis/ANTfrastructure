# Tests for Invoke-CpythonPip — the shared `python -m pip` wrapper (routed through cmd.exe so
# pip's stderr progress doesn't trip EAP=Stop). A regression here would either swallow a failed
# pip install or abort a build on a non-critical wheel that should have been -Optional. A fake
# interpreter (a .bat that exits non-zero) drives the exit-code handling without needing Python.

Describe 'Invoke-CpythonPip' {

    It 'throws on a non-zero pip exit' {
        $global:LASTEXITCODE = 0
        $dir = New-TestDir
        $fake = Join-Path $dir 'python.bat'   # stands in for the interpreter; always exits non-zero
        Set-Content -LiteralPath $fake -Value 'exit /b 7' -Encoding ASCII
        Assert-Throws { Invoke-CpythonPip -Python @{ Exe = $fake } -Arguments @('install', 'x') } 'a non-zero pip exit must throw'
    }

    It 'warns instead of throwing when -Optional is set' {
        $global:LASTEXITCODE = 0
        $dir = New-TestDir
        $fake = Join-Path $dir 'python.bat'
        Set-Content -LiteralPath $fake -Value 'exit /b 7' -Encoding ASCII
        Invoke-CpythonPip -Python @{ Exe = $fake } -Arguments @('install', 'x') -Optional
        Assert-True $true 'a failed -Optional pip install continued without throwing'
    }

    It 'throws a clear error when the interpreter is missing (before running pip)' {
        Assert-Throws { Invoke-CpythonPip -Python @{ Exe = 'C:\nope\python.exe' } -Arguments @('--version') } 'missing interpreter must throw'
    }
}
