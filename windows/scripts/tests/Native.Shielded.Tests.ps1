#requires -Version 7.0
# Invoke-ShieldedNative: a non-zero exit always throws (unless -Optional), and $LASTEXITCODE never leaks from a green call.

Describe 'Invoke-ShieldedNative' {

    It 'passes native output through and normalizes $LASTEXITCODE to 0 on success' {
        Invoke-InTestDir { param($dir)
            $out = Invoke-ShieldedNative -CommandLine 'echo shield-hello' -Quiet
            Assert-Match 'shield-hello' ($out | Out-String) 'stdout is captured and returned'
            Assert-Equal 0 $LASTEXITCODE 'a green call leaves LASTEXITCODE at 0'
        }
    }

    It 'merges a tool''s stderr into the returned output (the whole point of the shield)' {
        Invoke-InTestDir { param($dir)
            # The 2>&1 inside cmd.exe must fold the tool's stderr into the output, never a NativeCommandError.
            $tool = Join-Path $dir 'noisy.cmd'
            Set-Content -LiteralPath $tool -Value "@echo off`r`necho to-stderr 1>&2`r`nexit /b 0" -Encoding ASCII
            $out = Invoke-ShieldedNative -CommandLine "`"$tool`"" -Quiet
            Assert-Match 'to-stderr' ($out | Out-String) 'stderr arrives merged into the returned output'
            Assert-Equal 0 $LASTEXITCODE 'stderr noise alone must not dirty the exit code'
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
            $spaceDir = Join-Path $dir 'space dir'
            New-Item -ItemType Directory -Path $spaceDir -Force | Out-Null
            $tool = Join-Path $spaceDir 'my tool.cmd'
            Set-Content -LiteralPath $tool -Value "@echo off`r`necho tool-ran %1`r`nexit /b 0" -Encoding ASCII
            $out = Invoke-ShieldedNative -CommandLine "`"$tool`" arg-1" -Quiet
            Assert-Match 'tool-ran arg-1' ($out | Out-String) 'a command line STARTING with a quoted spaced path executes with its argument'
            Assert-Equal 0 $LASTEXITCODE 'green quoted-path call leaves LASTEXITCODE at 0'
        }
    }
}
