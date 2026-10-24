#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Host maintenance phase decisions' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Set-ContainerdConfig.ps1' -FunctionName 'Get-ContainerdDesiredConfiguration', 'Set-ContainerdServiceValues', 'Sync-ContainerdCni')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Publish-ShimPatch.ps1' -FunctionName 'Resolve-ShimDeploymentSource')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Test-HostSetup.ps1' -FunctionName 'Get-HostCniSubnet')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Update-HostVhdx.ps1' -FunctionName 'Write-HostVhdxHostFree')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Install-ScoopTools.ps1' -FunctionName 'Install-GitExecutable')

    function New-ContainerdDesiredCase {
        param([string]$ImagePath, [string[]]$Environment, [string]$Timeout)
        $current = [pscustomobject]@{ ImagePath = $ImagePath; Environment = $Environment }
        $desired = Get-ContainerdDesiredConfiguration -Current $current -CurrentEnvironment $Environment `
            -Name containerd -Level debug -LogPath 'C:\containerd.log' -Timeout $Timeout
        return [pscustomobject]@{ Current = $current; Desired = $desired }
    }

    It 'keeps unrelated containerd variables while replacing the shim timeout' {
        $case = New-ContainerdDesiredCase -ImagePath '"C:\Program Files\containerd\containerd.exe" --run-service' `
            -Environment @('KEEP=1', 'CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=30s') -Timeout 5m
        $desired = $case.Desired
        Assert-Equal '"C:\Program Files\containerd\containerd.exe" --run-service --service-name containerd --log-level debug --log-file C:\containerd.log' $desired.ImagePath
        Assert-Equal 'KEEP=1|CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m' ($desired.Environment -join '|')
        Assert-True $desired.ImagePathDrift
        Assert-True $desired.EnvironmentDrift
    }

    It 'removes the timeout registry value when the desired environment is empty' {
        $script:hostChanges = [System.Collections.Generic.List[string]]::new()
        function Write-HostMaintenanceMessage { }
        $case = New-ContainerdDesiredCase -ImagePath '"C:\containerd.exe"' `
            -Environment @('CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=30s') -Timeout ''
        $desired = $case.Desired
        Assert-Equal 0 $desired.Environment.Count
        Invoke-WithTestFunction -Name Set-ItemProperty -Definition { param($Path, $Name, $Value, $Type) $script:hostChanges.Add('set') } -Body {
            Invoke-WithTestFunction -Name Remove-ItemProperty -Definition { param($Path, $Name) $script:hostChanges.Add("remove:$Name") } -Body {
                Set-ContainerdServiceValues -ServiceKey 'HKLM:\test' -Current $case.Current -Desired $desired
            }
        }
        Assert-Equal 'set|remove:Environment' ($script:hostChanges -join '|')
    }

    It 'derives CNI config only when admin and approved' {
        function Write-HostMaintenanceMessage { }
        $dir = New-TestDir -Prefix 'host-cni-'
        try {
            $conf = Join-Path $dir '0-containerd-nat.conf'
            $conflist = Join-Path $dir '0-containerd-nat.conflist'
            Set-Content -LiteralPath $conflist -Value '{"cniVersion":"1.0.0","name":"nat","plugins":[{"type":"nat","ipam":{"subnet":"172.20.0.0/16"}}]}'
            $script:cniApprovals = 0
            $approve = { param($target, $action) $script:cniApprovals++; return $true }
            $moduleRoot = Join-Path (Get-RepoRoot) 'windows/scripts'
            Sync-ContainerdCni -ModuleRoot $moduleRoot -ConfDir $dir -Report:$true -IsAdmin:$true -Approve $approve
            Assert-False (Test-Path $conf) 'report only leaves the derived file absent'
            Sync-ContainerdCni -ModuleRoot $moduleRoot -ConfDir $dir -Report:$false -IsAdmin:$false -Approve $approve
            Assert-False (Test-Path $conf) 'non-admin leaves the derived file absent'
            Assert-Equal 0 $script:cniApprovals 'neither read-only path requests approval'
            Sync-ContainerdCni -ModuleRoot $moduleRoot -ConfDir $dir -Report:$false -IsAdmin:$true -Approve $approve
            Assert-Equal 1 $script:cniApprovals 'the write requests approval'
            Assert-Match '172.20.0.0/16' (Get-Content -LiteralPath $conf -Raw)
        } finally { Remove-TestDir $dir }
    }

    It 'uses a restore backup and rejects a missing shim source' {
        $dir = New-TestDir -Prefix 'host-shim-source-'
        try {
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -LiteralPath "$shim.orig" -Value 'backup'
            Assert-Equal "$shim.orig" (Resolve-ShimDeploymentSource -InstallPath $shim -Restore '.orig' -ShimPath '')
            Assert-Throws { Resolve-ShimDeploymentSource -InstallPath $shim -Restore '.bak' -ShimPath '' } -MessagePattern 'no such backup'
            Assert-Throws { Resolve-ShimDeploymentSource -InstallPath $shim -Restore '' -ShimPath '' } -MessagePattern 'Nothing to do'
        } finally { Remove-TestDir $dir }
    }

    It 'extracts the CNI subnet and leaves absent subnet text empty' {
        Assert-Equal '172.20.0.0/16' (Get-HostCniSubnet -Text '{"ipam":{"subnet":"172.20.0.0/16"}}')
        Assert-Equal '' (Get-HostCniSubnet -Text '{"ipam":{}}')
    }

    It 'reports VHDX free space with the previous value when supplied' {
        $script:hostLines = [System.Collections.Generic.List[string]]::new()
        function Write-HostStep { param($Log, [string]$Message) $script:hostLines.Add($Message) }
        Write-HostVhdxHostFree -HostFreeBytes 20GB -HostDrive C -Log @{} -PreviousHostFreeBytes 10GB
        Assert-Match '^host C: free : 20[.,]0 GB \(was 10[.,]0 GB\)$' $script:hostLines[0]
    }

    It 'fails a Git installer with a nonzero exit before deleting the installer' {
        Invoke-WithTestFunction -Name Start-Process -Definition {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow, [switch]$PassThru)
            return [pscustomobject]@{ ExitCode = 7 }
        } -Body {
            Assert-Throws { Install-GitExecutable -Installer 'C:\Git.exe' } -MessagePattern 'exit 7'
        }
    }
}
