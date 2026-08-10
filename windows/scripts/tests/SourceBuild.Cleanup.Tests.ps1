#requires -Version 7.0
# Tests for Remove-SourceBuildTree's exit-code contract. Cleanup is best-effort
# by design; its exit code must NEVER outlive the call: `rd` exiting 145
# (ERROR_DIR_NOT_EMPTY) once made Invoke-SourceBuildChain declare a fully green
# LiteRT-LM stage "failed (exit 145)" — the chain reads the AMBIENT
# $LASTEXITCODE after each in-process stage, and stage scripts routinely end on
# this call (2026-08-03 incident; AGENTS.md Windows Build Invariants).

Describe 'Remove-SourceBuildTree exit-code contract' {

    It 'resets a stale non-zero $LASTEXITCODE on the normal path' {
        Invoke-InTestDir { param($dir)
            $victim = Join-Path $dir 'tree-to-remove'
            New-Item -ItemType Directory -Path $victim -Force | Out-Null
            Set-Content (Join-Path $victim 'f.txt') 'x'
            & cmd /c "exit 145"   # simulate the lingering-handle rd failure code
            Remove-SourceBuildTree -Path $victim
            Assert-Equal 0 $LASTEXITCODE 'cleanup must clear the ambient exit code'
            Assert-False (Test-Path $victim) 'the tree was removed'
        }
    }

    It 'resets a stale non-zero $LASTEXITCODE even when the path does not exist' {
        Invoke-InTestDir { param($dir)
            & cmd /c "exit 145"
            Remove-SourceBuildTree -Path (Join-Path $dir 'never-existed')
            Assert-Equal 0 $LASTEXITCODE 'the skip path must also clear the exit code'
        }
    }

    It 'resets $LASTEXITCODE on the KEEP_BUILD_ARTIFACTS early return' {
        Invoke-InTestDir { param($dir)
            $victim = Join-Path $dir 'kept-tree'
            New-Item -ItemType Directory -Path $victim -Force | Out-Null
            $prev = $env:KEEP_BUILD_ARTIFACTS
            try {
                $env:KEEP_BUILD_ARTIFACTS = '1'
                & cmd /c "exit 145"
                Remove-SourceBuildTree -Path $victim
                Assert-Equal 0 $LASTEXITCODE 'the keep-artifacts path must also clear the exit code'
                Assert-True (Test-Path $victim) 'the tree was kept'
            } finally {
                if ($null -eq $prev) { Remove-Item Env:\KEEP_BUILD_ARTIFACTS -ErrorAction SilentlyContinue } else { $env:KEEP_BUILD_ARTIFACTS = $prev }
            }
        }
    }
}
