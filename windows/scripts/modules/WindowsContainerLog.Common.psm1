# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
  Console+file logging for scripts running INSIDE a Windows build container.

.DESCRIPTION
  Lifted from a consumer (Kataglyphis-RustProjectTemplate's
  scripts/windows/Container/rust-build-all.ps1 and rust-test-all.ps1), which
  carried two byte-identical copies of it.

  Deliberately DEPENDENCY-FREE and self-contained. An in-container script is
  usually staged alone - the consumer's driver excludes ExternalLib from the
  sources it copies in, so nothing under windows/scripts/modules/ is reachable
  from inside the container unless it is copied there explicitly. This module
  is therefore safe to drop next to the script it serves and import by path.

  Two behaviours are the whole point, and both are hard-won:

  * Every line is written to a file on the MOUNTED scratch directory as well
    as the console. The docker CLI pipe drops intermittently on Windows
    container hosts (hcsshim/ttrpc flakiness) while the container keeps
    working, so console output alone can vanish mid-run and take the reason
    for a failure with it.

  * Native commands run through `cmd /c "<cmd> 2>&1"`. That merges stderr into
    stdout as plain text instead of letting PowerShell wrap each stderr line
    in an ErrorRecord, which reorders output and can turn a harmless warning
    into a terminating error depending on $ErrorActionPreference and the
    PowerShell version.
#>

$script:ContainerLogPath = $null

<#
.SYNOPSIS
  Start (and truncate) the container log.
.PARAMETER Path
  Log file, normally under the mounted scratch dir (e.g. C:\host-scratch\x.log).
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

    cmd /c "$CommandLine 2>&1" | ForEach-Object {
        Write-Host $_
        if ($script:ContainerLogPath) {
            Add-Content -Path $script:ContainerLogPath -Value $_
        }
    }
    return $LASTEXITCODE
}

Export-ModuleMember -Function @(
    'Start-ContainerLog',
    'Write-ContainerLog',
    'Invoke-ContainerLoggedCommand'
)
