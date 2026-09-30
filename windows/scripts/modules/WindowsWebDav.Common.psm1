Set-StrictMode -Version Latest
#requires -Version 7.0


# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# The uv venv lifecycle lives in WindowsUv.Common, not in a per-module copy.
if (-not (Get-Module -Name 'WindowsUv.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsUv.Common.psm1')
}

if (-not (Get-Module -Name 'WindowsBuild.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

function Invoke-EarlyWebDavDownload {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [Parameter(Mandatory)]
    [string]$WebDavHost,
    [Parameter(Mandatory)]
    [string]$WebDavUser,
    [Parameter(Mandatory)]
    [string]$WebDavPass,
    [Parameter(Mandatory)]
    [string]$WebDavRemote,
    [Parameter(Mandatory)]
    [string]$WebDavLocal
  )

  # Extension-agnostic; the .pfx filter for the early certificate fetch is passed below.
  $earlyScript = Join-Path $PSScriptRoot '..\certificates\download_webdav_files.py'
  Write-BuildLog -Context $Context -Message "DEBUG: Early WebDAV script path (raw): $earlyScript"

  if (-not (Test-Path $earlyScript)) {
    Write-BuildLogWarning -Context $Context -Message "Early WebDAV script not found: $earlyScript"
    return
  }
  $earlyScript = (Resolve-Path $earlyScript).Path

  $uvCmd = Get-Command 'uv' -ErrorAction SilentlyContinue
  if (-not $uvCmd) {
    Write-BuildLogWarning -Context $Context -Message 'uv not found on PATH; cannot run early WebDAV script.'
    return
  }

  $venvPath = Join-Path $WorkspacePath '.venv'
  Write-BuildLog -Context $Context -Message "DEBUG: Ensuring uv venv at: $venvPath (activation: .venv\Scripts\Activate)"

  $uvDelegates = New-UvBuildDelegates -Context $Context
  $logInfo = $uvDelegates.LogInfo
  $logWarning = $uvDelegates.LogWarning
  # -IgnoreExitCode: WebDAV bootstrap failures degrade to warnings, never abort the build.
  $commandRunner = {
    param([string]$File, [string[]]$Parameters)
    Invoke-BuildExternal -Context $Context -File $File -Parameters $Parameters -IgnoreExitCode | Out-Null
  }

  try {
    Initialize-UvVenv -Workspace $WorkspacePath -EnvName '.venv' `
      -CommandRunner $commandRunner -LogInfo $logInfo -LogWarning $logWarning | Out-Null
  } catch {
    Write-BuildLogWarning -Context $Context -Message "uv venv creation failed: $($_.Exception.Message)"
  }

  try {
    Write-BuildLog -Context $Context -Message "DEBUG: Running: $($uvCmd.Source) pip install --upgrade pip"
    Invoke-BuildExternal -Context $Context -File $uvCmd.Source -Parameters @('pip', 'install', '--upgrade', 'pip') -IgnoreExitCode | Out-Null

    # Pinned from versions.env, the same ref the bash half installs.
    $hubRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $versions = ConvertFrom-VersionsEnv -Path (Join-Path $hubRoot 'linux/scripts/01-core/versions.env')
    if (-not $versions.Contains('WEBDAVCLIENT_REF')) {
      throw 'WEBDAVCLIENT_REF is not set in linux/scripts/01-core/versions.env; the ANTfrastructure pin predates the convention.'
    }
    $requirement = Get-WebDavClientRequirement -Ref $versions['WEBDAVCLIENT_REF']
    Write-BuildLog -Context $Context -Message "DEBUG: Installing Kataglyphis WebDAV client into uv venv: $requirement"
    Invoke-BuildExternal -Context $Context -File $uvCmd.Source -Parameters @('pip', 'install', $requirement) -IgnoreExitCode | Out-Null
  } catch {
    Write-BuildLogWarning -Context $Context -Message "uv pip install step failed: $($_.Exception.Message)"
  }

  Write-BuildLog -Context $Context -Message "DEBUG: Invoking early WebDAV download with: $($uvCmd.Source) run $earlyScript $WebDavHost $WebDavUser <redacted> $WebDavRemote $WebDavLocal --extension .pfx"
  # -RedactParameterValues keeps the password out of Invoke-BuildExternal's own CMD log line.
  Invoke-BuildExternal -Context $Context -File $uvCmd.Source -Parameters @('run', $earlyScript, $WebDavHost, $WebDavUser, $WebDavPass, $WebDavRemote, $WebDavLocal, '--extension', '.pfx') -IgnoreExitCode -RedactParameterValues @($WebDavPass)
}

function Get-WebDavClientRequirement {
  <#
  .SYNOPSIS
      The pip requirement for the pinned WebDAV client: the commit's source archive, never a git+https URL.
  .DESCRIPTION
      A git requirement makes uv init nested submodules that overflow Git for Windows' gitdir limit.
  #>
  param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Ref
  )
  return "kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/$Ref.tar.gz"
}

Export-ModuleMember -Function @(
  'Get-WebDavClientRequirement',
  'Invoke-EarlyWebDavDownload'
)
