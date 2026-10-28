#requires -Version 7.0
# Its own harness-style suite: the Linux mutation shards cannot run the rocm suite's Windows-only cases.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsNative.Common.psm1') -DisableNameChecking

$script:IreeScript = 'windows\scripts\build\Build-IreeFromSource.ps1'
$script:TvmScript = 'windows\scripts\build\Build-TvmFromSource.ps1'

Describe 'IREE and TVM off their cross and rocm branches return $null under strict mode' {
    It 'Get-TvmRocmLlvmTargets returns $null off the rocm lane instead of reading an unset variable (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmScript -FunctionName 'Get-TvmRocmLlvmTargets')
        Set-StrictMode -Version Latest
        Assert-Equal $null (Get-TvmRocmLlvmTargets -Plan ([pscustomobject]@{ OnLane = $false; Rocm = $false }) -LlvmConfig 'C:\llvm\bin\llvm-config.exe') 'the default lane'
    }

    It 'Install-IreeHostTools returns $null on a native build instead of reading an unset variable (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:IreeScript -FunctionName 'Install-IreeHostTools')
        Set-StrictMode -Version Latest
        Assert-Equal $null (Install-IreeHostTools -Cross $false -SourceDir 'C:\iree' -BuildType Release -EhscInclude 'C:\ehsc.cmake' -Masm 'ml64') 'the native lane'
    }
}
