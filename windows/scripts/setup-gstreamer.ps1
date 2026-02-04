<#                                                   .SYNOPSIS
  Robust headless GStreamer exe downloader + installer with safe logging.
                                                     .DESCRIPTION
  - Downloads using BITS (preferred) and falls back to WebClient and curl.
  - Logs transcript and structured events to separate files.
  - Computes SHA256 and file size.
  - Attempts multiple common silent install modes (Inno, NSIS, others).
  - Defensively sanitizes installer arguments before calling Start-Process.                                 - Optional: interactive fallback on failure, machine PATH update, auto-removal of installer.                                                                 .USAGE
  PowerShell (Admin) .\install-gstreamer-headless-full.ps1
#>                                                   
param(
    [string]$Url = 'https://gstreamer.freedesktop.org/data/pkg/windows/1.28.0/msvc/gstreamer-1.0-msvc-x86_64-1.28.0.exe',
    [string]$InstallDir = 'C:\gstreamer',
    [string]$LogDir = 'C:\temp',
    [switch]$ForceInteractiveOnFail,   # if set, run interactive installer if silent attempts fail
    [switch]$SkipPathUpdate,           # if set, do not attempt to update machine PATH
    [switch]$AutoRemoveInstaller       # if set, remove the installer file after successful install
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure log directory
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# Timestamped filenames
$ts = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
$TranscriptFile = Join-Path $LogDir "gstreamer-install-$ts.transcript.log"
$StructuredLogFile = Join-Path $LogDir "gstreamer-install-$ts.log"

# Start transcript (capture everything) - transcript and structured log separate
try {
    Start-Transcript -Path $TranscriptFile -Force | Out-Null
} catch {
    Write-Warning "Start-Transcript failed: $($_.Exception.Message). Continuing without transcript."
}

function Write-StructuredLog {
    param([string]$Text)
    $entry = "$(Get-Date -Format u)`t$Text"
    # Print to console
    Write-Host $entry
    # Try to append to structured log; fail-safe (do not abort if logging fails)
    try {
        Add-Content -Path $StructuredLogFile -Value $entry -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to structured log ($StructuredLogFile): $($_.Exception.Message)"
    }
}

# Defensive installer invocation that sanitizes ArgumentList and avoids nulls
function Invoke-Installer {
    param(
        [Parameter(Mandatory=$true)] [string] $Path,
        [Parameter(Mandatory=$false)] [object] $Args
    )

    # Build flat array of args
    $raw = @()
    if ($null -ne $Args) {
        if ($Args -is [System.Collections.IEnumerable] -and -not ($Args -is [string])) {
            foreach ($a in $Args) { $raw += $a }
        } else {
            $raw += $Args
        }
    }
    # Convert to strings and remove null/empty
    $sanitized = $raw | ForEach-Object { if ($_ -eq $null) { $null } else { [string]$_ } } | Where-Object { $_ -ne $null -and $_ -ne '' }

    if ($sanitized.Count -gt 0) {
        Write-StructuredLog "Running installer: $Path  Args: $($sanitized -join ' ')"
    } else {
        Write-StructuredLog "Running installer: $Path  (no arguments)"
    }

    try {
        if ($sanitized.Count -gt 0) {
            $proc = Start-Process -FilePath $Path -ArgumentList $sanitized -Wait -PassThru -NoNewWindow
        } else {
            $proc = Start-Process -FilePath $Path -Wait -PassThru -NoNewWindow
        }
        Write-StructuredLog "Installer exit code: $($proc.ExitCode)"
        return $proc.ExitCode
    } catch {
        Write-StructuredLog "Installer run failed: $($_.Exception.Message)"
        return 9999
    }
}

# Main execution
try {
    Write-StructuredLog "START - GStreamer headless installer script"
    Write-StructuredLog "URL: $Url"
    Write-StructuredLog "InstallDir: $InstallDir"
    Write-StructuredLog "LogDir: $LogDir"
    Write-StructuredLog "TranscriptFile: $TranscriptFile"
    Write-StructuredLog "StructuredLogFile: $StructuredLogFile"

    # Determine file name from URL
    $fileName = [System.IO.Path]::GetFileName($Url)
    if (-not $fileName) { throw "Cannot determine filename from URL: $Url" }
    $dst = Join-Path $env:TEMP $fileName
    Write-StructuredLog "Target download path: $dst"

    # Ensure TLS 1.2
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Download attempts
    $downloaded = $false

    # 1) BITS (preferred)
    try {
        Write-StructuredLog "Attempting download with BITS..."
        if (-not (Test-Path (Split-Path $dst))) { New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null }
        Start-BitsTransfer -Source $Url -Destination $dst -ErrorAction Stop
        Write-StructuredLog "BITS download succeeded."
        $downloaded = $true
    } catch {
        Write-StructuredLog "BITS download failed: $($_.Exception.Message)"
    }

    # 2) WebClient fallback
    if (-not $downloaded) {
        try {
            Write-StructuredLog "Falling back to WebClient with browser User-Agent..."
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent','Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
            $wc.DownloadFile($Url, $dst)
            $wc.Dispose()
            Write-StructuredLog "WebClient download succeeded."
            $downloaded = $true
        } catch {
            Write-StructuredLog "WebClient download failed: $($_.Exception.Message)"
            if ($wc -ne $null) { $wc.Dispose() }
        }
    }

    # 3) curl.exe fallback
    if (-not $downloaded) {
        try {
            Write-StructuredLog "Falling back to curl.exe..."
            if (-not (Test-Path (Split-Path $dst))) { New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null }
            $curlArgs = @('-L','-f','-A',"Mozilla/5.0 (Windows NT 10.0; Win64; x64)",'-o',$dst,$Url)
            $p = Start-Process -FilePath 'curl.exe' -ArgumentList $curlArgs -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) {
                Write-StructuredLog "curl.exe download succeeded."
                $downloaded = $true
            } else {
                Write-StructuredLog "curl.exe failed with exit code $($p.ExitCode)."
            }
        } catch {
            Write-StructuredLog "curl.exe download error: $($_.Exception.Message)"
        }
    }

    if (-not $downloaded) {
        Write-StructuredLog "ERROR: All download attempts failed. Exiting."
        throw "DownloadFailed"
    }

    if (-not (Test-Path $dst)) { throw "Downloaded file not found at $dst" }
    $fi = Get-Item $dst
    $sizeMB = [math]::Round($fi.Length / 1MB, 2)
    Write-StructuredLog "Downloaded file: $dst (Size: $sizeMB MB)"

    try {
        $hash = Get-FileHash -Algorithm SHA256 -Path $dst
        Write-StructuredLog "SHA256: $($hash.Hash)"
    } catch {
        Write-StructuredLog "Could not compute SHA256: $($_.Exception.Message)"
    }

    # Silent install attempts
    $installSucceeded = $false
    $installAttempts = @()

    # Ensure InstallDir exists
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    # 1) Inno Setup style (quoted DIR)
    $innoArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/DIR=' + "`"$InstallDir`"")
    $ec = Invoke-Installer -Path $dst -Args $innoArgs
    $installAttempts += @{ Method='Inno'; Args=$innoArgs; ExitCode=$ec }
    if ($ec -eq 0) { $installSucceeded = $true }

    # 2) Inno without quoted DIR
    if (-not $installSucceeded) {
        $innoArgs2 = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/DIR=' + $InstallDir)
        $ec = Invoke-Installer -Path $dst -Args $innoArgs2
        $installAttempts += @{ Method='Inno2'; Args=$innoArgs2; ExitCode=$ec }
        if ($ec -eq 0) { $installSucceeded = $true }
    }

    # 3) NSIS style
    if (-not $installSucceeded) {
        $nsisArgs = @('/S', "/D=$InstallDir")
        $ec = Invoke-Installer -Path $dst -Args $nsisArgs
        $installAttempts += @{ Method='NSIS'; Args=$nsisArgs; ExitCode=$ec }
        if ($ec -eq 0) { $installSucceeded = $true }
    }

    # 4) Other common flags
    if (-not $installSucceeded) {
        $otherFlagsList = @(
            @('/SILENT','/VERYSILENT','/NORESTART'),
            @('/S','/VERYSILENT'),
            @('--silent','--no-ui')
        )
        foreach ($flags in $otherFlagsList) {
            $ec = Invoke-Installer -Path $dst -Args $flags
            $installAttempts += @{ Method='Other'; Args=$flags; ExitCode=$ec }
            if ($ec -eq 0) { $installSucceeded = $true; break }
        }
    }

    # Interactive fallback (if requested)
    if (-not $installSucceeded -and $ForceInteractiveOnFail.IsPresent) {
        Write-StructuredLog "Silent install attempts failed; launching interactive installer due to -ForceInteractiveOnFail."
        Start-Process -FilePath $dst -Wait
        Start-Sleep -Seconds 2
        if (Test-Path (Join-Path $InstallDir 'bin')) {
            Write-StructuredLog "Interactive install likely succeeded (bin exists)."
            $installSucceeded = $true
        } else {
            Write-StructuredLog "Interactive install did not create expected files."
        }
    }

    # Summarize attempts
    Write-StructuredLog "Installation attempts summary:"
    foreach ($a in $installAttempts) {
        $method = $a.Method
        $args = if ($a.Args -is [array]) { $a.Args -join ' ' } else { $a.Args }
        $code = $a.ExitCode
        Write-StructuredLog "  $method  Args: $args  -> ExitCode: $code"
    }

    if ($installSucceeded) {
        Write-StructuredLog "INSTALL SUCCESS"

        # PATH update (if desired)
        if (-not $SkipPathUpdate.IsPresent) {
            try {
                $gstBin = Join-Path $InstallDir 'bin'
                if (Test-Path $gstBin) {
                    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
                    if ($machinePath -notlike "*$gstBin*") {
                        Write-StructuredLog "Updating machine PATH to add: $gstBin"
                        $newPath = $machinePath + ';' + $gstBin
                        [Environment]::SetEnvironmentVariable('Path',$newPath,'Machine')
                        Write-StructuredLog "PATH updated. Restart shells for change to take effect."
                    } else {
                        Write-StructuredLog "GST bin path already present in machine PATH."
                    }
                } else {
                    Write-StructuredLog "Warning: expected bin folder not found at $gstBin; skipping PATH update."
                }
            } catch {
                Write-StructuredLog "Could not update machine PATH (need elevation?): $($_.Exception.Message)"
            }
        }
                                                             Write-StructuredLog "END - script completed successfully."
        exit 0
    } else {
        Write-StructuredLog "INSTALL FAILED: No silent install succeeded."
        Write-StructuredLog "See structured log: $StructuredLogFile"
        Write-StructuredLog "See transcript (if any): $TranscriptFile"
        throw "InstallFailed"
    }                                                
} catch {
    Write-StructuredLog "FATAL ERROR: $($_.Exception.Message)"                                                if ($_.Exception.InnerException) { Write-StructuredLog "Inner: $($_.Exception.InnerException.Message)" }
    Write-StructuredLog "See structured log: $StructuredLogFile"
    Write-StructuredLog "See transcript (if any): $TranscriptFile"
    exit 2                                           } finally {
    try { Stop-Transcript | Out-Null } catch {}      }
