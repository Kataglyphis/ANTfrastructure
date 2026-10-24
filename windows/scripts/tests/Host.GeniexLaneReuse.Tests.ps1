#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'GenieX existing lane check' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Start-GeniexServers.ps1' -FunctionName 'Test-GeniexLaneAlreadyListening')
    $script:BindAddress = '127.0.0.1'
    $script:modelQueries = 0
    function Get-ServedModels { $script:modelQueries++; 'old.gguf' }
    function Get-BundleKind {
        param([string]$Model)
        if ($Model -like '*.gguf') { return 'gguf' }
        return 'qairt'
    }

    It 'skips a busy lane but warns when its bind and bundle kind differ' {
        $script:modelQueries = 0
        $busy = [pscustomobject]@{ OwningProcess = 123; LocalAddress = '0.0.0.0' }
        $report = @(Test-GeniexLaneAlreadyListening -Compute npu -Port 18181 -Model 'qualcomm/model' -Busy $busy 3>&1 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-Match 'listens on 0.0.0.0, not the requested 127.0.0.1' $report
        Assert-Match 'serves a gguf bundle.*but qualcomm/model is qairt' $report
        Assert-Match 'True' $report
        Assert-Equal 1 $script:modelQueries
    }

    It 'allows startup when no listener exists' {
        $script:modelQueries = 0
        Assert-False (Test-GeniexLaneAlreadyListening -Compute gpu -Port 18182 -Model 'model' -Busy $null 6>$null)
        Assert-Equal 0 $script:modelQueries
    }
}
