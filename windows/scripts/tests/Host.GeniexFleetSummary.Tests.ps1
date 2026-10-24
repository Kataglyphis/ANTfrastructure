#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'GenieX fleet endpoint report' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Start-GeniexServers.ps1' -FunctionName 'Write-GeniexFleetEndpoints')
    function Get-ServedModels {
        param([int]$Port)
        if ($Port -eq 18182) { return 'old-gpu-model' }
        return 'configured'
    }
    function Get-LaneModel {
        param([string]$Compute)
        if ($Compute -eq 'gpu') { return 'new-gpu-model' }
        return 'configured'
    }
    function Get-FleetReport {
        param([switch]$OptionalLanes)
        return (@(Write-GeniexFleetEndpoints -ProbeHost '127.0.0.1' -NpuPort 18181 -GpuPort 18182 -HybridPort 18183 -CpuPort 18184 -UseHybrid:$OptionalLanes -UseCpu:$OptionalLanes 3>&1 6>&1 | ForEach-Object { "$_" }) -join "`n")
    }

    It 'shows only default lanes and warns when the live GPU model differs' {
        $report = Get-FleetReport
        Assert-Match '127\.0\.0\.1:18181/v1' $report
        Assert-Match '127\.0\.0\.1:18182/v1' $report
        Assert-False ($report -match ':18183/v1|:18184/v1')
        Assert-Match 'serves old-gpu-model, not the configured new-gpu-model' $report
    }

    It 'includes the optional hybrid and CPU lanes only when requested' {
        $report = Get-FleetReport -OptionalLanes
        Assert-Match '127\.0\.0\.1:18183/v1' $report
        Assert-Match '127\.0\.0\.1:18184/v1' $report
    }
}
