<#
.SYNOPSIS
    Headless GStreamer installer for Windows.

.DESCRIPTION
    Thin orchestration script that reuses generic installer/logging helpers from
    modules/WindowsInstaller.Common.psm1.
#>
param(
    [string]$Url = '',
    [string]$Version = '',
    [string]$Arch = '',
    [string]$Flavor = '',
    [string]$InstallDir = 'C:\gstreamer',
    [string]$LogDir = 'C:\temp',
    [switch]$ForceInteractiveOnFail,   # if set, run interactive installer if silent attempts fail
    [switch]$SkipPathUpdate,           # if set, do not attempt to update machine PATH
    [switch]$AutoRemoveInstaller       # if set, remove the installer file after successful install
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $env:GST_VERSION
}

if ([string]::IsNullOrWhiteSpace($Arch)) {
    $Arch = $env:ARCH
}

if ([string]::IsNullOrWhiteSpace($Flavor)) {
    $Flavor = $env:FLAVOR
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = '1.28.3'
}

if ([string]::IsNullOrWhiteSpace($Arch)) {
    $Arch = 'x86_64'
}

if ([string]::IsNullOrWhiteSpace($Flavor)) {
    $Flavor = 'msvc'
}

if ([string]::IsNullOrWhiteSpace($Url)) {
    $base = 'https://gstreamer.freedesktop.org/data/pkg/windows/{0}/{1}/' -f $Version, $Flavor
    $exeInstaller = 'gstreamer-1.0-{0}-{1}-{2}.exe' -f $Flavor, $Arch, $Version
    $Url = $base + $exeInstaller
}

$logContext = New-StructuredLogContext -LogDir $LogDir -Prefix 'gstreamer-install'
Start-StructuredLogging -Context $logContext

# Main execution
try {
    Write-StructuredLogEntry -Context $logContext -Text 'START - GStreamer headless installer script'
    Write-StructuredLogEntry -Context $logContext -Text "URL: $Url"
    Write-StructuredLogEntry -Context $logContext -Text "InstallDir: $InstallDir"
    Write-StructuredLogEntry -Context $logContext -Text "LogDir: $LogDir"
    Write-StructuredLogEntry -Context $logContext -Text "TranscriptFile: $($logContext.TranscriptFile)"
    Write-StructuredLogEntry -Context $logContext -Text "StructuredLogFile: $($logContext.StructuredLogFile)"

    $fileName = [System.IO.Path]::GetFileName($Url)
    if (-not $fileName) { throw "Cannot determine filename from URL: $Url" }
    $dst = Join-Path $env:TEMP $fileName
    Write-StructuredLogEntry -Context $logContext -Text "Target download path: $dst"

    Enable-Tls12ForDownloads
    Invoke-WebDownloadWithFallback -Context $logContext -Url $Url -DestinationPath $dst
    Write-DownloadArtifactDetails -Context $logContext -Path $dst

    $installResult = Invoke-SilentInstallWithStrategies -Context $logContext -InstallerPath $dst -InstallDir $InstallDir
    $installSucceeded = $installResult.Succeeded
    $installAttempts = $installResult.Attempts

    # Interactive fallback (if requested)
    if (-not $installSucceeded -and $ForceInteractiveOnFail.IsPresent) {
        Write-StructuredLogEntry -Context $logContext -Text 'Silent install attempts failed; launching interactive installer due to -ForceInteractiveOnFail.'
        Start-Process -FilePath $dst -Wait
        Start-Sleep -Seconds 2
        if (Test-Path (Join-Path $InstallDir 'bin')) {
            Write-StructuredLogEntry -Context $logContext -Text 'Interactive install likely succeeded (bin exists).'
            $installSucceeded = $true
        } else {
            Write-StructuredLogEntry -Context $logContext -Text 'Interactive install did not create expected files.'
        }
    }

    # Summarize attempts
    Write-StructuredLogEntry -Context $logContext -Text 'Installation attempts summary:'
    foreach ($a in $installAttempts) {
        $method = $a.Method
        $parameters = if ($a.Parameters -is [array]) { $a.Parameters -join ' ' } else { $a.Parameters }
        $code = $a.ExitCode
        Write-StructuredLogEntry -Context $logContext -Text "  $method  Parameters: $parameters  -> ExitCode: $code"
    }

    if ($installSucceeded) {
        Write-StructuredLogEntry -Context $logContext -Text 'INSTALL SUCCESS'

        # PATH update (if desired)
        if (-not $SkipPathUpdate.IsPresent) {
            $gstBin = Join-Path $InstallDir 'bin'
            Add-MachinePathEntryIfMissing -Context $logContext -PathEntry $gstBin
        }

        if ($AutoRemoveInstaller.IsPresent -and (Test-Path $dst)) {
            try {
                Remove-Item -Path $dst -Force
                Write-StructuredLogEntry -Context $logContext -Text "Removed installer: $dst"
            } catch {
                Write-StructuredLogEntry -Context $logContext -Text "Could not remove installer ($dst): $($_.Exception.Message)"
            }
        }

        Write-StructuredLogEntry -Context $logContext -Text 'END - script completed successfully.'
        exit 0
    } else {
        Write-StructuredLogEntry -Context $logContext -Text 'INSTALL FAILED: No silent install succeeded.'
        Write-StructuredLogEntry -Context $logContext -Text "See structured log: $($logContext.StructuredLogFile)"
        Write-StructuredLogEntry -Context $logContext -Text "See transcript (if any): $($logContext.TranscriptFile)"
        throw 'InstallFailed'
    }
} catch {
    Write-StructuredLogEntry -Context $logContext -Text "FATAL ERROR: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        Write-StructuredLogEntry -Context $logContext -Text "Inner: $($_.Exception.InnerException.Message)"
    }
    Write-StructuredLogEntry -Context $logContext -Text "See structured log: $($logContext.StructuredLogFile)"
    Write-StructuredLogEntry -Context $logContext -Text "See transcript (if any): $($logContext.TranscriptFile)"
    exit 2
} finally {
    Stop-StructuredLogging -Context $logContext
}
