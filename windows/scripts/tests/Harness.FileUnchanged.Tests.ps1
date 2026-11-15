#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Exact local bytes and callback controls do not prove compiler behavior or native execution.

Describe 'Harness unchanged-file assertions' {
    It 'runs the callback with caller bindings and a literal bracketed path' {
        Invoke-InTestDir -Files @{ 'sample [1].bin' = 'original'; 'sample 1.bin' = 'decoy' } -Body { param($dir)
            $path = Join-Path $dir 'sample [1].bin'
            [IO.File]::WriteAllBytes($path, [byte[]]@(0, 13, 10, 255))
            $before = 'caller-before'
            $pattern = 'caller-pattern'
            $state = New-TestCallState
            Assert-FileUnchanged -Path $path -Action {
                Assert-Equal 'caller-before' $before 'hash locals do not hide caller variables'
                Assert-Equal 'caller-pattern' $pattern 'callback pattern binding'
                $state.Calls.Add($path)
            }
            Assert-Equal 1 $state.Calls.Count 'the callback runs exactly once'
            Assert-Equal $path $state.Calls[0] 'the caller path survives'
        }
    }

    It 'rejects newline and BOM byte changes instead of hashing a wildcard sibling' {
        Invoke-InTestDir -Files @{ 'sample [1].bin' = 'original'; 'sample 1.bin' = 'decoy' } -Body { param($dir)
            $path = Join-Path $dir 'sample [1].bin'
            foreach ($byteCase in @(@{ Bytes = [byte[]]@(10) }, @{ Bytes = [byte[]]@(239, 187, 191, 13, 10) })) {
                [IO.File]::WriteAllBytes($path, [byte[]]@(13, 10))
                Assert-Throws {
                    Assert-FileUnchanged -Path $path -Action { [IO.File]::WriteAllBytes($path, $byteCase.Bytes) } -Reason 'changed bytes'
                } -MessagePattern 'Assert-Equal.*changed bytes'
            }
        }
    }

    It 'refuses missing input before the callback and preserves the operation failure' {
        Invoke-InTestDir -Files @{ 'present.bin' = 'present' } -Body { param($dir)
            $state = New-TestCallState
            Assert-Throws {
                Assert-FileUnchanged -Path (Join-Path $dir 'missing.bin') -Action { $state.Calls.Add('unexpected') }
            }
            Assert-Equal 0 $state.Calls.Count 'missing input must not run the operation'
            Assert-Throws {
                Assert-FileUnchanged -Path (Join-Path $dir 'present.bin') -Action { throw 'unchanged-operation-failed' }
            } -MessagePattern '^unchanged-operation-failed$'
        }
    }
}
