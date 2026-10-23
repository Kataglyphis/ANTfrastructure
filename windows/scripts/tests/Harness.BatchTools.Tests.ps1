#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Native batch execution covers cmd argument forwarding and exit behavior on Windows, not cross-platform shell execution.

Describe 'Native batch fixtures' {
    It 'writes exact ASCII CRLF bytes, forwards quoted arguments and applies the requested final exit' {
        Invoke-InTestDir { param($dir)
            $path = New-TestBatchFixture -Directory $dir
            Assert-Match 'ARG1=\[a b\] ARG2=\[second value\]' ((& $path 'a b' 'second value') | Out-String)
            Assert-Equal 7 $global:LASTEXITCODE
            $early = New-TestBatchTool -Directory $dir -Name early.cmd -Line 'exit /b 3' -ExitCode 7
            & $early
            Assert-Equal 3 $global:LASTEXITCODE 'caller branches can override the appended fallback'
        }
    }

    Invoke-TestBatchToolMutationCases -DroppedLineExpected 'does not match' -Body {
        param($path)
        $output = (& $path) | Out-String
        $code = $global:LASTEXITCODE
        Assert-Match caller-marker $output
        Assert-Equal 7 $code
    }
}

