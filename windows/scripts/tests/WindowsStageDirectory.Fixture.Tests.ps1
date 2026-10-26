#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: building a wheel or Cargo binary; this suite checks only staging reset wiring and effects.

Import-Module (Join-Path $PSScriptRoot 'WindowsStageDirectory.Fixture.psm1') -ErrorAction Stop

Describe 'Shared stage directory fixture' {
    It 'finds one reset before copy and rejects missing, late, or malformed wiring' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'Stage.ps1'
            Set-Content -LiteralPath $path -Value 'function Stage { Initialize-BuildDirectory -Path $out -Empty; Copy-Item item -Destination $out }'
            Assert-StageResetBeforeCopy -ScriptPath $path -ResetCommand Initialize-BuildDirectory -PathArgument '$out'
            $mutants = @(
                @{ Text = 'function Stage { Initialize-BuildDirectory -Path $out; Copy-Item item -Destination $out }'; Failure = 'literal command wiring' },
                @{ Text = 'function Stage { Initialize-BuildDirectory -Path $out -Empty:$false; Copy-Item item -Destination $out }'; Failure = 'literal command wiring' },
                @{ Text = 'function Stage { Copy-Item item -Destination $out; Initialize-BuildDirectory -Path $out -Empty }'; Failure = 'reset must precede' },
                @{ Text = 'function Stage { Initialize-BuildDirectory -Path $out -Empty }'; Failure = 'must copy staged payloads' },
                @{ Text = 'function Stage { Initialize-BuildDirectory -Path $out -Empty; Copy-Item item -Destination $out'; Failure = 'parse errors' }
            )
            foreach ($mutant in $mutants) {
                Set-Content -LiteralPath $path -Value $mutant.Text
                Assert-Throws {
                    Assert-StageResetBeforeCopy -ScriptPath $path -ResetCommand Initialize-BuildDirectory -PathArgument '$out'
                } -MessagePattern $mutant.Failure
            }
        }
    }

    It 'catches stale bytes left by a reset callback' {
        Invoke-InTestDir { param($dir)
            Assert-StageDirectoryCleared -TestRoot $dir -RunReset {
                param($path)
                Remove-Item -LiteralPath $path -Recurse -Force
                $null = New-Item -ItemType Directory -Path $path
            }
            Assert-Throws {
                Assert-StageDirectoryCleared -TestRoot $dir -RunReset { param($path) $null = $path }
            } -MessagePattern 'remove stale bytes'
        }
    }

    It 'catches a swallowed allocation failure' {
        Invoke-InTestDir { param($dir)
            Assert-StageDirectoryAllocationFailure -TestRoot $dir -RunReset { param($path) throw "cannot create $path" }
            Assert-Throws {
                Assert-StageDirectoryAllocationFailure -TestRoot $dir -RunReset { param($path) $null = $path }
            } -MessagePattern 'failed allocation must throw'
        }
    }
}
