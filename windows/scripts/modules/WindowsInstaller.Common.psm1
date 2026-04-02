Set-StrictMode -Version Latest

# Ensure shared helpers are available (Get-MyLibraryModulesRoot etc.)
try {
    $sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
    if (Test-Path $sharedPath) { . $sharedPath }
} catch {}

Import-Module Kataglyphis.Scripts.Common -Force

function New-StructuredLogContext {
    param(
        [Parameter(Mandatory)]
        [string]$LogDir,
        [string]$Prefix = 'installer'
    )

    $resolvedLogDir = Resolve-DirectoryPath -Path $LogDir
    $timestamp = New-Timestamp -Format 'yyyy-MM-dd_HH-mm-ss'

    [pscustomobject]@{
        LogDir = $resolvedLogDir
        Prefix = $Prefix
        TranscriptFile = Join-Path $resolvedLogDir "$Prefix-$timestamp.transcript.log"
        StructuredLogFile = Join-Path $resolvedLogDir "$Prefix-$timestamp.log"
        TranscriptStarted = $false
    }
}

function Start-StructuredLogging {
    param([Parameter(Mandatory)][pscustomobject]$Context)

    try {
        Start-Transcript -Path $Context.TranscriptFile -Force | Out-Null
        $Context.TranscriptStarted = $true
    } catch {
        Write-Warning "Start-Transcript failed: $($_.Exception.Message). Continuing without transcript."
    }
}

function Stop-StructuredLogging {
    param([Parameter(Mandatory)][pscustomobject]$Context)

    if ($Context.TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
        }
    }
}

function Write-StructuredLogEntry {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Text
    )

    $entry = "$(Get-Date -Format u)`t$Text"
    Write-Host $entry

    try {
        Add-Content -Path $Context.StructuredLogFile -Value $entry -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to structured log ($($Context.StructuredLogFile)): $($_.Exception.Message)"
    }
}

function Enable-Tls12ForDownloads {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
    }
}

function Invoke-WebDownloadWithFallback {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $destinationDir = Split-Path -Parent $DestinationPath
    if ($destinationDir) {
        Resolve-DirectoryPath -Path $destinationDir | Out-Null
    }

    $downloaded = $false

    try {
        Write-StructuredLogEntry -Context $Context -Text 'Attempting download with BITS...'
        Start-BitsTransfer -Source $Url -Destination $DestinationPath -ErrorAction Stop
        Write-StructuredLogEntry -Context $Context -Text 'BITS download succeeded.'
        $downloaded = $true
    } catch {
        Write-StructuredLogEntry -Context $Context -Text "BITS download failed: $($_.Exception.Message)"
    }

    if (-not $downloaded) {
        $webClient = $null
        try {
            Write-StructuredLogEntry -Context $Context -Text 'Falling back to WebClient with browser User-Agent...'
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
            $webClient.DownloadFile($Url, $DestinationPath)
            Write-StructuredLogEntry -Context $Context -Text 'WebClient download succeeded.'
            $downloaded = $true
        } catch {
            Write-StructuredLogEntry -Context $Context -Text "WebClient download failed: $($_.Exception.Message)"
        } finally {
            if ($null -ne $webClient) {
                $webClient.Dispose()
            }
        }
    }

    if (-not $downloaded) {
        try {
            Write-StructuredLogEntry -Context $Context -Text 'Falling back to curl.exe...'
            $curlParameters = @('-L', '-f', '-A', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', '-o', $DestinationPath, $Url)
            $process = Start-Process -FilePath 'curl.exe' -ArgumentList $curlParameters -Wait -PassThru -NoNewWindow
            if ($process.ExitCode -eq 0) {
                Write-StructuredLogEntry -Context $Context -Text 'curl.exe download succeeded.'
                $downloaded = $true
            } else {
                Write-StructuredLogEntry -Context $Context -Text "curl.exe failed with exit code $($process.ExitCode)."
            }
        } catch {
            Write-StructuredLogEntry -Context $Context -Text "curl.exe download error: $($_.Exception.Message)"
        }
    }

    if (-not $downloaded) {
        throw 'DownloadFailed'
    }
}

function Invoke-InstallerProcess {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$FilePath,
        [object]$InstallerParameters
    )

    $parameterList = ConvertTo-ParameterList -Value $InstallerParameters
    $sanitized = @($parameterList | ForEach-Object { if ($null -eq $_) { $null } else { [string]$_ } } | Where-Object { $_ -ne $null -and $_ -ne '' })

    if ($sanitized.Count -gt 0) {
        Write-StructuredLogEntry -Context $Context -Text "Running installer: $FilePath  Parameters: $($sanitized -join ' ')"
    } else {
        Write-StructuredLogEntry -Context $Context -Text "Running installer: $FilePath  (no parameters)"
    }

    try {
        $process = if ($sanitized.Count -gt 0) {
            Start-Process -FilePath $FilePath -ArgumentList $sanitized -Wait -PassThru -NoNewWindow
        } else {
            Start-Process -FilePath $FilePath -Wait -PassThru -NoNewWindow
        }

        Write-StructuredLogEntry -Context $Context -Text "Installer exit code: $($process.ExitCode)"
        return [int]$process.ExitCode
    } catch {
        Write-StructuredLogEntry -Context $Context -Text "Installer run failed: $($_.Exception.Message)"
        return 9999
    }
}

function Invoke-SilentInstallWithStrategies {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$InstallDir,
        [object[]]$StrategyList
    )

    Resolve-DirectoryPath -Path $InstallDir | Out-Null

    $StrategyList = @($StrategyList)
    $strategies = if ($StrategyList -and $StrategyList.Count -gt 0) {
        $StrategyList
    } else {
        @(
            [pscustomobject]@{ Method = 'Inno'; Parameters = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/DIR=' + "`"$InstallDir`"") },
            [pscustomobject]@{ Method = 'Inno2'; Parameters = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/DIR=' + $InstallDir) },
            [pscustomobject]@{ Method = 'NSIS'; Parameters = @('/S', "/D=$InstallDir") },
            [pscustomobject]@{ Method = 'Other'; Parameters = @('/SILENT', '/VERYSILENT', '/NORESTART') },
            [pscustomobject]@{ Method = 'Other'; Parameters = @('/S', '/VERYSILENT') },
            [pscustomobject]@{ Method = 'Other'; Parameters = @('--silent', '--no-ui') }
        )
    }

    $attempts = @()
    $succeeded = $false

    foreach ($strategy in $strategies) {
        $method = if ($null -ne $strategy.Method) { [string]$strategy.Method } else { 'Unknown' }
        $parameters = $strategy.Parameters

        $exitCode = Invoke-InstallerProcess -Context $Context -FilePath $InstallerPath -InstallerParameters $parameters
        $attempts += [pscustomobject]@{ Method = $method; Parameters = $parameters; ExitCode = $exitCode }

        if ($exitCode -eq 0) {
            $succeeded = $true
            break
        }
    }

    [pscustomobject]@{
        Succeeded = $succeeded
        Attempts = $attempts
    }
}

function Write-DownloadArtifactDetails {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Downloaded file not found at $Path"
    }

    $fileInfo = Get-Item $Path
    $sizeInMb = [math]::Round($fileInfo.Length / 1MB, 2)
    Write-StructuredLogEntry -Context $Context -Text "Downloaded file: $Path (Size: $sizeInMb MB)"

    try {
        $hash = Get-FileHash -Algorithm SHA256 -Path $Path
        Write-StructuredLogEntry -Context $Context -Text "SHA256: $($hash.Hash)"
    } catch {
        Write-StructuredLogEntry -Context $Context -Text "Could not compute SHA256: $($_.Exception.Message)"
    }
}

function Add-MachinePathEntryIfMissing {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$PathEntry
    )

    if (-not (Test-Path $PathEntry)) {
        Write-StructuredLogEntry -Context $Context -Text "Warning: expected folder not found at $PathEntry; skipping PATH update."
        return
    }

    try {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ([string]::IsNullOrWhiteSpace($machinePath)) {
            [Environment]::SetEnvironmentVariable('Path', $PathEntry, 'Machine')
            Write-StructuredLogEntry -Context $Context -Text "PATH initialized with: $PathEntry"
            return
        }

        if ($machinePath -notlike "*$PathEntry*") {
            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$PathEntry", 'Machine')
            Write-StructuredLogEntry -Context $Context -Text "Updating machine PATH to add: $PathEntry"
            Write-StructuredLogEntry -Context $Context -Text 'PATH updated. Restart shells for change to take effect.'
        } else {
            Write-StructuredLogEntry -Context $Context -Text 'Path entry already present in machine PATH.'
        }
    } catch {
        Write-StructuredLogEntry -Context $Context -Text "Could not update machine PATH (need elevation?): $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @(
    'New-StructuredLogContext',
    'Start-StructuredLogging',
    'Stop-StructuredLogging',
    'Write-StructuredLogEntry',
    'Enable-Tls12ForDownloads',
    'Invoke-WebDownloadWithFallback',
    'Invoke-InstallerProcess',
    'Invoke-SilentInstallWithStrategies',
    'Write-DownloadArtifactDetails',
    'Add-MachinePathEntryIfMissing'
)
