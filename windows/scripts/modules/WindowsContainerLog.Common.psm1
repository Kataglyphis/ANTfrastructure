#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
  Console and file logging for scripts running inside a Windows build container.
.DESCRIPTION
  OxidANT's scripts/windows/container/*.ps1 import it through Resolve-BuildModule.ps1 from the streamed tree.
  Dependency-free, so a script can also import it by path alone. Every line goes to the log file too, because the
  docker CLI pipe drops on Windows container hosts while the container keeps running. Native commands run through
  `cmd /c "<cmd> 2>&1"`, so stderr arrives as text, not as ErrorRecords that reorder output or terminate the script.
#>

$script:ContainerLogPath = $null

<#
.SYNOPSIS
  Start (and truncate) the container log.
.PARAMETER Path
  Log file, e.g. <Workspace>\logs\in-container-build.log, which the runner streams back to the host.
#>
function Start-ContainerLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Remove-Item $Path -Force -ErrorAction SilentlyContinue
    $script:ContainerLogPath = $Path
}

<#
.SYNOPSIS
  Write a line to the console and the container log.
#>
function Write-ContainerLog {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Message)

    process {
        Write-Host $Message
        if ($script:ContainerLogPath) {
            Add-Content -Path $script:ContainerLogPath -Value $Message
        }
    }
}

<#
.SYNOPSIS
  Run a native command line, tee its combined output to the log, return its
  exit code.
.OUTPUTS
  [int] the command's exit code. Callers check it explicitly rather than
  relying on $ErrorActionPreference - see the module description.
#>
function Invoke-ContainerLoggedCommand {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$CommandLine)

    cmd /c "$CommandLine 2>&1" | Write-ContainerLog
    return $LASTEXITCODE
}

Export-ModuleMember -Function @(
    'Start-ContainerLog',
    'Write-ContainerLog',
    'Invoke-ContainerLoggedCommand'
)
