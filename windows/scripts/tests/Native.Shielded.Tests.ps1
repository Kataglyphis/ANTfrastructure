#requires -Version 7.0
# Invoke-ShieldedNative: a non-zero exit always throws (unless -Optional), and $LASTEXITCODE never leaks from a green call.

function Assert-ShieldedNativeSuccess {
    param([string]$CommandLine, [string]$OutputPattern, [string]$OutputReason, [string]$ExitReason)
    $out = Invoke-ShieldedNative -CommandLine $CommandLine -Quiet
    Assert-Match $OutputPattern ($out | Out-String) $OutputReason
    Assert-Equal 0 $LASTEXITCODE $ExitReason
}

Describe 'Invoke-ShieldedNative' {

    It 'passes native output through and normalizes $LASTEXITCODE to 0 on success' {
        Invoke-InTestDir { param($dir)
            Assert-ShieldedNativeSuccess 'echo shield-hello' 'shield-hello' 'stdout is captured and returned' 'a green call leaves LASTEXITCODE at 0'
        }
    }

    It 'merges a tool''s stderr into the returned output (the whole point of the shield)' {
        Invoke-InTestDir { param($dir)
            # The 2>&1 inside cmd.exe must fold the tool's stderr into the output, never a NativeCommandError.
            $tool = New-TestBatchTool -Directory $dir -Name noisy.cmd -Line 'echo to-stderr 1>&2'
            Assert-ShieldedNativeSuccess "`"$tool`"" 'to-stderr' 'stderr arrives merged into the returned output' 'stderr noise alone must not dirty the exit code'
        }
    }

    It 'throws on a non-zero exit with the exit code in the message' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Invoke-ShieldedNative -CommandLine 'exit 7' -Label 'wbt-fail' -Quiet } `
                -MessagePattern '\[wbt-fail\] failed \(exit 7\)' `
                'the throw must carry the label and the native exit code'
        }
    }

    It '-Optional swallows the failure and normalizes $LASTEXITCODE to 0' {
        Invoke-InTestDir { param($dir)
            $warnings = @()
            Invoke-ShieldedNative -CommandLine 'exit 9' -Label 'wbt-opt' -Optional -Quiet `
                -WarningVariable warnings -WarningAction SilentlyContinue
            Assert-Equal 0 $LASTEXITCODE 'an -Optional failure must not leak its exit code into the ambient state'
            Assert-Match 'exited 9' (@($warnings) -join ' ') 'the swallowed failure is still surfaced as a warning'
        }
    }

    It 'runs a quoted exe path with spaces (the /s + leading-space rule)' {
        Invoke-InTestDir { param($dir)
            $tool = New-TestBatchTool -Directory (Join-Path $dir 'space dir') -Name 'my tool.cmd' -Line 'echo tool-ran %1'
            Assert-ShieldedNativeSuccess "`"$tool`" arg-1" 'tool-ran arg-1' 'a command line STARTING with a quoted spaced path executes with its argument' 'green quoted-path call leaves LASTEXITCODE at 0'
        }
    }
}
