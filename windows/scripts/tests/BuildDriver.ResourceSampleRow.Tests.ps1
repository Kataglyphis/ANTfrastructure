#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Resource sampler row' {
    It 'samples a host with no running WSL VM, where no vmmem process exists (mutation)' {
        $prelude = @'
Set-StrictMode -Version Latest
function Get-Process { }
function Get-CimInstance { param($ClassName) [pscustomobject]@{ LoadPercentage = 40; FreePhysicalMemory = 8MB; TotalVisibleMemorySize = 32MB; TotalVirtualMemorySize = 40MB; FreeVirtualMemory = 20MB } }
function Get-PSDrive { [pscustomobject]@{ Free = 100GB } }
'@
        $sampler = 'windows\scripts\build\Build-ResourceSampler.ps1'
        Invoke-WithFunctionModule -ScriptPath $sampler -FunctionName Get-ResourceSampleRow -Prelude $prelude -Body {
            Assert-Match '^\S+ \S+,a;b,40,8,24,20,0,100$' (Get-MutResourceSampleRow -Phase 'a,b' -Drive C) 'one full row with vmmemGB 0'
        }
        Invoke-WithFunctionModule -ScriptPath $sampler -FunctionName Get-ResourceSampleRow -Prelude $prelude `
            -Find '$vmmemGB = if ($vmmemProcs) {' -Replace '$vmmemGB = if ($true) {' -Body {
                Assert-Throws { Get-MutResourceSampleRow -Phase p -Drive C } -MessagePattern 'Sum'
            }
    }
}
