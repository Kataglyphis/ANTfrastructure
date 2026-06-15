<#
.SYNOPSIS
    Load version variables from the canonical linux/scripts/01-core/versions.env
    into the current PowerShell session as environment variables.

.DESCRIPTION
    Sources linux/scripts/01-core/versions.env (bash KEY=VALUE format) and
    exports each variable as a process-level environment variable so that
    Dockerfile RUN commands and setup scripts can reference $env:VARIABLE.

    Only lines matching /^[A-Za-z_][A-Za-z0-9_]*=/ are loaded (skipping
    comments, blank lines, and Linux-specific values like UBUNTU_CODENAME).

.PARAMETER VersionsEnvPath
    Path to versions.env relative to the repo root.  Defaults to
    linux/scripts/01-core/versions.env.
#>
param(
    [string]$VersionsEnvPath = ''
)

if ([string]::IsNullOrWhiteSpace($VersionsEnvPath)) {
    $searchPaths = @(
        Join-Path $PSScriptRoot '..\..\linux\scripts\01-core\versions.env'
        Join-Path (Split-Path -Parent $PSScriptRoot) 'linux\scripts\01-core\versions.env'
        Join-Path $PSScriptRoot 'linux\scripts\01-core\versions.env'
        'C:\linux\scripts\01-core\versions.env'
        'C:\temp\versions.env'
        'versions.env'
    )
    $VersionsEnvPath = $searchPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $VersionsEnvPath) { $VersionsEnvPath = '' }

if (-not (Test-Path $VersionsEnvPath)) {
    Write-Warning "versions.env not found at: $VersionsEnvPath"
    return
}

Write-Host "Loading versions from: $VersionsEnvPath"
$loaded = 0
Get-Content $VersionsEnvPath | ForEach-Object {
    if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $key = $matches[1]
        $value = $matches[2].Trim('"', "'")
        if ($value -match '^\{') { return }  # skip arrays/maps
        [Environment]::SetEnvironmentVariable($key, $value, 'Process')
        $loaded++
    }
}
Write-Host "Loaded $loaded version variables."
