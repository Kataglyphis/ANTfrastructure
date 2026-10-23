#requires -Version 7.0
# Stubbed file verdicts do not install an SDK or validate an import library.

function Invoke-OptionalFileFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsContainerImage.Common.psm1' `
        -FunctionName Assert-VulkanArm64Library -Find $Find -Replace $Replace -Body $Body
}

Describe 'Optional container file verdicts' {
    It 'preserves success, advisory and strict failure streams' {
        Invoke-OptionalFileFixture {
            Invoke-InTestDir -Files @{ 'arm64.lib' = 'fixture' } -Body { param($dir)
                $messages = @{ Phase = 'Verify' }
                $present = @(Assert-MutVulkanArm64Library -Path (Join-Path $dir arm64.lib) -Strict $true @messages 6>&1)
                Assert-Equal 1 $present.Count
                Assert-True ($present[0] -is [Management.Automation.InformationRecord])
                Assert-Equal ("Vulkan ARM64 import library OK: " + (Join-Path $dir arm64.lib)) "$($present[0])"
                $absent = Join-Path $dir missing.lib
                $advisory = @(Assert-MutVulkanArm64Library -Path $absent -Strict $false @messages 3>&1)
                Assert-Equal 1 $advisory.Count
                Assert-True ($advisory[0] -is [Management.Automation.WarningRecord])
                Assert-Match 'Vulkan ARM64 import library missing at .*missing.lib - an arm64 target cannot link Vulkan' "$($advisory[0])"
                Assert-Throws { Assert-MutVulkanArm64Library -Path $absent -Strict $true @messages } -MessagePattern 'WINDOWS_ARM64_STRICT=1 made this a hard gate'
            }
        }
    }

    It 'retains install and verify policy inputs at both call sites' {
        $install = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/host/Install-ScoopTools.ps1' -Name Assert-VulkanArm64Library)
        $verify = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Test-Toolchain.ps1' -Name Assert-VulkanArm64Library)
        Assert-Equal 1 $install.Count
        Assert-Equal 1 $verify.Count
        $installArgs = Get-TestCommandArguments $install[0]
        $verifyArgs = Get-TestCommandArguments $verify[0]
        Assert-Equal '$vkArm64Lib' $installArgs.Path
        Assert-Equal "(`$armStrict -eq '1')" $installArgs.Strict
        Assert-Equal "(Join-Path `$vkArmLib 'vulkan-1.lib')" $verifyArgs.Path
        Assert-Equal "(`$env:WINDOWS_ARM64_STRICT -eq '1')" $verifyArgs.Strict
        Assert-Equal Install $installArgs.Phase
        Assert-Equal Verify $verifyArgs.Phase
        Assert-Equal '$vkArmLib' $verifyArgs.DisplayPath
    }

    It 'rejects a strict missing file downgraded to advisory' {
        Invoke-OptionalFileFixture -Find 'elseif ($Strict)' -Replace 'elseif ($false)' -Body {
            Assert-Throws {
                Assert-Throws { Assert-MutVulkanArm64Library -Path 'missing-fixture.lib' -Strict $true -Phase Verify 3>$null } -MessagePattern 'WINDOWS_ARM64_STRICT=1 made this a hard gate'
            } -MessagePattern 'expected an exception'
        }
    }
}
