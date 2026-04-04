Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Invoke-UvCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo
    )

    if ($LogInfo) {
        & $LogInfo "Running uv command: uv $($Arguments -join ' ')"
    }

    if ($CommandRunner) {
        & $CommandRunner 'uv' $Arguments
        return
    }

    & uv @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('Command failed with exit code {0}: uv {1}' -f $LASTEXITCODE, ($Arguments -join ' '))
    }
}

function Remove-UvProjectEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$EnvPath,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning,
        [int]$MaxAttempts = 8
    )

    if (-not $EnvPath) {
        return
    }

    if ($env:UV_PROJECT_ENVIRONMENT -eq $EnvPath) {
        $env:UV_PROJECT_ENVIRONMENT = $null
    }

    if (-not (Test-Path -Path $EnvPath)) {
        return
    }

    if ($LogInfo) {
        & $LogInfo "Removing uv environment: $EnvPath"
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $removeErrors = @()
        Remove-Item -Path $EnvPath -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +removeErrors
        if (-not (Test-Path -Path $EnvPath)) {
            return
        }

        try {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        } catch {
        }

        $lastError = $null
        $removeErrors = @($removeErrors)
        if ($removeErrors -and $removeErrors.Count -gt 0) {
            $lastError = $removeErrors[-1].Exception.Message
        }

        if ($LogWarning) {
            & $LogWarning "Failed to remove environment '$EnvPath' (attempt $attempt/$MaxAttempts). $lastError"
        }

        Start-Sleep -Seconds 2
    }
}

function New-UvProjectEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$PythonVersion,
        [Parameter(Mandatory)]
        [string]$EnvName,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    $envPath = Join-Path $Workspace $EnvName

    if ($LogInfo) {
        & $LogInfo "Creating uv environment: $envPath (Python $PythonVersion)"
    }

    if (Test-Path -Path $envPath) {
        Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $LogInfo -LogWarning $LogWarning
    }

    Invoke-UvCommand -Arguments @('venv', '--python', $PythonVersion, '--clear', $envPath) -CommandRunner $CommandRunner -LogInfo $null

    $env:UV_PROJECT_ENVIRONMENT = $envPath
    return $envPath
}

function Sync-UvProjectDependencies {
    param(
        [switch]$NoBuildIsolationPackageWxPython,
        [switch]$UseLocked,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo
    )

    $syncArgs = @('-v', 'sync', '--dev', '--all-extras')
    if ($UseLocked) {
        $syncArgs += '--locked'
    }
    if ($NoBuildIsolationPackageWxPython) {
        $syncArgs += @('--no-build-isolation-package', 'wxpython')
    }

    Invoke-UvCommand -Arguments $syncArgs -CommandRunner $CommandRunner -LogInfo $LogInfo
}

Export-ModuleMember -Function @(
    'Invoke-UvCommand',
    'New-UvProjectEnvironment',
    'Remove-UvProjectEnvironment',
    'Sync-UvProjectDependencies'
)
