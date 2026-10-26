#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

function Get-CiInstalledModule {
    param([string]$Name, [string]$VersionKind, [version]$Target)
    @(Get-Module -ListAvailable -Name $Name | Where-Object {
        $_.Name -eq $Name -and $(if ($VersionKind -eq 'RequiredVersion') { $_.Version -eq $Target } else { $_.Version -ge $Target })
    } | Sort-Object Version -Descending | Select-Object -First 1)
}

function Install-PinnedPowerShellModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][version]$Version,
        [switch]$Minimum,
        [switch]$SkipPublisherCheck
    )

    $maxAttempts = 5
    $retryDelaySeconds = 3
    $target = $Version
    $versionKind = if ($Minimum) { 'MinimumVersion' } else { 'RequiredVersion' }
    $installArgs = @{ Name = $Name; Scope = 'CurrentUser'; Force = $true; ErrorAction = 'Stop' }
    $installArgs[$versionKind] = $target.ToString()
    if ($SkipPublisherCheck) { $installArgs.SkipPublisherCheck = $true }

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $installed = @(Get-CiInstalledModule -Name $Name -VersionKind $versionKind -Target $target)
        if ($installed.Count -gt 0) { return $installed[0] }

        try {
            $null = Install-Module @installArgs
            $installed = @(Get-CiInstalledModule -Name $Name -VersionKind $versionKind -Target $target)
            if ($installed.Count -eq 0) { throw "Installer returned without $Name $versionKind $target" }
            return $installed[0]
        } catch {
            if ($attempt -eq $maxAttempts) {
                throw "Failed to install $Name $versionKind $target after $maxAttempts attempt(s): $($_.Exception.Message)"
            }
            Write-Warning "$Name $versionKind $target install attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds ($retryDelaySeconds * $attempt)
        }
    }
}

Export-ModuleMember -Function Install-PinnedPowerShellModule
