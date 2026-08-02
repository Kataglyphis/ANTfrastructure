Set-StrictMode -Version Latest
#requires -Version 7.0


# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
# No -Force when already loaded: a nested force-reimport moves the module's
# exports out of the global session state on Windows PowerShell 5.1.
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# The uv venv lifecycle (health-check, recreate, requirements install) lives in
# WindowsUv.Common - single source of truth instead of a per-module variant.
if (-not (Get-Module -Name 'WindowsUv.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsUv.Common.psm1')
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

  # The download helper ships next to this module in the ContainerHub layout
  # (windows/scripts/certificates). It is extension-agnostic; the .pfx filter
  # for the early certificate fetch is passed explicitly below.
  $earlyScript = Join-Path $PSScriptRoot '..\certificates\download_webdav_files.py'
  Write-BuildLog -Context $Context -Message "DEBUG: Early WebDAV script path (raw): $earlyScript"

  if (-not (Test-Path $earlyScript)) {
    Write-BuildLogWarning -Context $Context -Message "Early WebDAV script not found: $earlyScript"
    return
  }
  $earlyScript = (Resolve-Path $earlyScript).Path

  # Prefer explicit 'uv' on PATH and invoke the script with 'uv run'.
  $uvCmd = Get-Command 'uv' -ErrorAction SilentlyContinue
  if (-not $uvCmd) {
    Write-BuildLogWarning -Context $Context -Message 'uv not found on PATH; cannot run early WebDAV script.'
    return
  }

  $venvPath = Join-Path $WorkspacePath '.venv'
  Write-BuildLog -Context $Context -Message "DEBUG: Ensuring uv venv at: $venvPath (activation: .venv\Scripts\Activate)"

  # Reuse a healthy venv, recreate a broken one (missing or non-runnable
  # python.exe) - routed through the shared WindowsUv.Common implementation.
  $logInfo = {
    param([string]$Message)
    Write-BuildLog -Context $Context -Message $Message
  }
  $logWarning = {
    param([string]$Message)
    Write-BuildLogWarning -Context $Context -Message $Message
  }
  # -IgnoreExitCode preserves this step's original best-effort behaviour:
  # WebDAV bootstrap failures degrade to warnings, never abort the build.
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

    Write-BuildLog -Context $Context -Message "DEBUG: Installing Kataglyphis WebDAV client into uv venv: git+https://github.com/Kataglyphis/Kataglyphis-WebDavClient"
    Invoke-BuildExternal -Context $Context -File $uvCmd.Source -Parameters @('pip', 'install', 'git+https://github.com/Kataglyphis/Kataglyphis-WebDavClient') -IgnoreExitCode | Out-Null
  } catch {
    Write-BuildLogWarning -Context $Context -Message "uv pip install step failed: $($_.Exception.Message)"
  }

  Write-BuildLog -Context $Context -Message "DEBUG: Invoking early WebDAV download with: $($uvCmd.Source) run $earlyScript $WebDavHost $WebDavUser <redacted> $WebDavRemote $WebDavLocal --extension .pfx"
  Invoke-BuildExternal -Context $Context -File $uvCmd.Source -Parameters @('run', $earlyScript, $WebDavHost, $WebDavUser, $WebDavPass, $WebDavRemote, $WebDavLocal, '--extension', '.pfx') -IgnoreExitCode
}

Export-ModuleMember -Function @(
  'Invoke-EarlyWebDavDownload'
)
