<#
.SYNOPSIS
    Generic Python package builder for Windows

.DESCRIPTION
    Builds source distribution and binary wheels for Python packages.
    Uses shared modules from Kataglyphis-ContainerHub.

.PARAMETER PythonVersion
    Python version to use (default: "3.14")

.EXAMPLE
    Invoke-CiPackaging.ps1 -PythonVersion "3.13"
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14"
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$containerHubModulesPath = Join-Path $scriptDir "..\modules"
$buildCommonModulePath = Join-Path $containerHubModulesPath "WindowsBuild.Common.psm1"
$uvCommonModulePath = Join-Path $containerHubModulesPath "WindowsUv.Common.psm1"

if (-not (Test-Path -Path $buildCommonModulePath)) {
    throw "Required reusable module not found: $buildCommonModulePath"
}

if (-not (Test-Path -Path $uvCommonModulePath)) {
    throw "Required reusable module not found: $uvCommonModulePath"
}

Import-Module $buildCommonModulePath -Force
Import-Module $uvCommonModulePath -Force

$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..\..")
Set-Location $repoRoot

$script:BuildContext = New-BuildContext -Workspace $repoRoot -LogDir "logs"

function Write-Log { param([string]$Message); Write-BuildLog -Context $script:BuildContext -Message $Message }
function Write-LogWarning { param([string]$Message); Write-BuildLogWarning -Context $script:BuildContext -Message $Message }

$script:UvCommandRunner = {
    param([string]$File, [string[]]$CommandArgs)
    Invoke-BuildExternal -Context $script:BuildContext -File $File -Parameters $CommandArgs | Out-Null
}

$script:UvLogInfo = { param([string]$Message); Write-BuildLog -Context $script:BuildContext -Message $Message }
$script:UvLogWarning = { param([string]$Message); Write-BuildLogWarning -Context $script:BuildContext -Message $Message }

Open-BuildLog -Context $script:BuildContext

Write-Log "Using Python version: $PythonVersion"

try {
    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (source)" -Script {
        Write-Log "=== Packaging (source) ==="
        $envPath = Join-Path $repoRoot ".venv-packaging-sources"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-sources" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

        try {
            Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("build") | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (Windows binaries)" -Script {
        Write-Log "=== Packaging (Windows binaries) ==="
        $env:CYTHONIZE = "True"

        $envPath = Join-Path $repoRoot ".venv-packaging-binaries"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-binaries" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

        try {
            Sync-UvProjectDependencies
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("build") | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    Write-Log "=== Packaging completed ==="

} finally {
    Write-BuildSummary -Context $script:BuildContext
    Close-BuildLog -Context $script:BuildContext

    if ($script:BuildContext.Results.Failed.Count -gt 0) {
        exit 1
    }
}
