Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, ConvertTo-ParameterList, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

# Import logging helpers (New-LogContext, Write-ContextLog, etc.)
$loggingPath = Join-Path $PSScriptRoot 'WindowsLogging.Common.psm1'
Import-Module $loggingPath -Force

function New-BuildContext {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$LogDir,
        [switch]$StopOnError
    )

    $baseContext = New-LogContext -Workspace $Workspace -LogDir $LogDir -LogFilePrefix 'build-windows'
    $summaryPath = $baseContext.LogPath -replace 'build-windows-', 'build-summary-' -replace '\.log$', '.json'

    [pscustomobject]@{
        Workspace   = $baseContext.Workspace
        LogPath     = $baseContext.LogPath
        SummaryPath = $summaryPath
        StartedAt   = $baseContext.StartedAt
        LogWriter   = $baseContext.LogWriter
        SuppressConsoleOutput = $false
        StopOnError = [bool]$StopOnError
        Results     = @{
            Succeeded = New-Object System.Collections.Generic.List[string]
            Failed    = New-Object System.Collections.Generic.List[string]
            Errors    = @{}
            Durations = [ordered]@{}
        }
    }
}

function Open-BuildLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    Open-LogWriter -Context $Context
}

function Close-BuildLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    Close-LogWriter -Context $Context
}

function Write-BuildLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Info
}

function Write-BuildLogWarning {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Warning
}

function Write-BuildLogError {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Error
}

function Write-BuildLogSuccess {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Success
}

function Invoke-BuildExternal {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$File,
        [object]$Parameters,
        [switch]$IgnoreExitCode
    )

    $parameterList = ConvertTo-ParameterList -Value $Parameters

    # Coerce to an array to ensure .Count property exists even when ConvertTo-ParameterList
    # returns a scalar or unexpected type. This prevents errors like "The property
    # 'Count' cannot be found on this object." when callers pass strings.
    $parameterList = @($parameterList)

    $cmdLine = if ($parameterList -and $parameterList.Count) { "$File $($parameterList -join ' ')" } else { $File }
    Write-BuildLog -Context $Context -Message "CMD: $cmdLine"

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0

    try {
        $capturedOutput = @()
        if ($parameterList -and $parameterList.Count -gt 0) {
            & $File @parameterList 2>&1 | ForEach-Object {
                $line = $_.ToString()
                $capturedOutput += $line
                if (-not [String]::IsNullOrWhiteSpace($line)) { Write-BuildLog -Context $Context -Message $line }
            }
        } else {
            & $File 2>&1 | ForEach-Object {
                $line = $_.ToString()
                $capturedOutput += $line
                if (-not [String]::IsNullOrWhiteSpace($line)) { Write-BuildLog -Context $Context -Message $line }
            }
        }

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
            $outputText = if ($capturedOutput) { ($capturedOutput -join "`n") } else { '<no output>' }
            throw "Command failed with exit code $($exitCode): $cmdLine`n--- OUTPUT ---`n$outputText"
        }

        return $exitCode
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-BuildOptional {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [scriptblock]$Script,
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        & $Script
    } catch {
        Write-BuildLogWarning -Context $Context -Message "$Name failed, continuing. Details: $($_.Exception.Message)"
    }
}

function Invoke-BuildStep {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$StepName,
        [Parameter(Mandatory)]
        [scriptblock]$Script,
        [switch]$Critical
    )

    Write-BuildLog -Context $Context -Message ""
    Write-BuildLog -Context $Context -Message ">>> Starting: $StepName"
    Write-BuildLog -Context $Context -Message ("=" * 60)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        & $Script
        $stopwatch.Stop()
        $Context.Results.Succeeded.Add($StepName) | Out-Null
        Write-BuildLogSuccess -Context $Context -Message "<<< Completed: $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
        
        # Add a diagnostic entry to the JSON summary tracking the duration of this step
        if ($null -eq $Context.Results.Durations) {
            $Context.Results.Durations = [ordered]@{}
        }
        $Context.Results.Durations[$StepName] = $stopwatch.Elapsed.TotalSeconds
        
        return $true
    } catch {
        $stopwatch.Stop()
        $errorMessage = $_.Exception.Message
        $Context.Results.Failed.Add($StepName) | Out-Null
        if ($null -eq $Context.Results.Durations) {
            $Context.Results.Durations = [ordered]@{}
        }
        $Context.Results.Durations[$StepName] = $stopwatch.Elapsed.TotalSeconds
        $Context.Results.Errors[$StepName] = $errorMessage
        Write-BuildLogError -Context $Context -Message "<<< FAILED: $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
        Write-BuildLogError -Context $Context -Message "    Error: $errorMessage"


        if ($_.ScriptStackTrace) {
            Write-BuildLog -Context $Context -Message "    Stack: $($_.ScriptStackTrace)"
        }

        if ($Context.StopOnError -and $Critical) {
            throw "Critical step '$StepName' failed: $errorMessage"
        }

        return $false
    }
}

function Write-BuildSummary {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    Write-BuildLog -Context $Context -Message ""
    Write-BuildLog -Context $Context -Message ("=" * 60)
    Write-BuildLog -Context $Context -Message "=== BUILD PIPELINE SUMMARY ==="
    Write-BuildLog -Context $Context -Message ("=" * 60)
    Write-BuildLog -Context $Context -Message ""

    if ($Context.Results.Succeeded.Count -gt 0) {
        Write-BuildLogSuccess -Context $Context -Message "SUCCEEDED ($($Context.Results.Succeeded.Count)):"
        foreach ($step in $Context.Results.Succeeded) {
            Write-BuildLogSuccess -Context $Context -Message "  [OK] $step"
        }
    }

    Write-BuildLog -Context $Context -Message ""

    if ($Context.Results.Failed.Count -gt 0) {
        Write-BuildLogError -Context $Context -Message "FAILED ($($Context.Results.Failed.Count)):"
        foreach ($step in $Context.Results.Failed) {
            Write-BuildLogError -Context $Context -Message "  [X] $step"
            Write-BuildLogError -Context $Context -Message "      Error: $($Context.Results.Errors[$step])"
        }
    }

    Write-BuildLog -Context $Context -Message ""
    $total = $Context.Results.Succeeded.Count + $Context.Results.Failed.Count
    $successRate = if ($total -gt 0) { [math]::Round(($Context.Results.Succeeded.Count / $total) * 100, 1) } else { 0 }
    Write-BuildLog -Context $Context -Message "Total: $total steps, $($Context.Results.Succeeded.Count) succeeded, $($Context.Results.Failed.Count) failed ($($successRate)% success rate)"

    if ($null -ne $Context.Results.Durations -and $Context.Results.Durations.Count -gt 0) {
        Write-BuildLog -Context $Context -Message ""
        Write-BuildLog -Context $Context -Message "=== STEP DURATIONS ==="
        $Context.Results.Durations.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-BuildLog -Context $Context -Message ("  {0,-50} : {1:N2}s" -f $_.Key, $_.Value)
        }
    }

    if ($Context.Results.Failed.Count -gt 0) {
        Write-BuildLog -Context $Context -Message ""
        Write-BuildLog -Context $Context -Message ("=" * 60)
        Write-BuildLogError -Context $Context -Message "=== ERROR DETAILS ==="
        Write-BuildLog -Context $Context -Message ("=" * 60)
        $errorIndex = 1
        foreach ($step in $Context.Results.Failed) {
            Write-BuildLogError -Context $Context -Message ""
            Write-BuildLogError -Context $Context -Message "[$errorIndex/$($Context.Results.Failed.Count)] $step"
            Write-BuildLogError -Context $Context -Message "    $($Context.Results.Errors[$step])"
            $errorIndex++
        }
        Write-BuildLog -Context $Context -Message ""
    }

    if ($Context.LogPath) {
        Write-BuildLog -Context $Context -Message "Full log available at: $($Context.LogPath)"
    }

    if ($Context.Results.Failed.Count -gt 0) {
        Write-BuildLogWarning -Context $Context -Message "Pipeline completed with errors!"
    } else {
        Write-BuildLogSuccess -Context $Context -Message "Pipeline completed successfully!"
    }

    try {
        $summary = [ordered]@{
            startedAt = $Context.StartedAt
            finishedAt = (Get-Date).ToString('o')
            workspace = $Context.Workspace
            logPath = $Context.LogPath
            summaryPath = $Context.SummaryPath
            totals = [ordered]@{
                total = $total
                succeeded = $Context.Results.Succeeded.Count
                failed = $Context.Results.Failed.Count
                successRate = $successRate
            }
            succeededSteps = @($Context.Results.Succeeded)
            failedSteps = @($Context.Results.Failed)
            errors = $Context.Results.Errors
            durations = $Context.Results.Durations
        }

        $summaryJson = $summary | ConvertTo-Json -Depth 8
        Set-Content -Path $Context.SummaryPath -Value $summaryJson -Encoding UTF8
        Write-BuildLog -Context $Context -Message "Machine-readable summary available at: $($Context.SummaryPath)"
    } catch {
        Write-BuildLogWarning -Context $Context -Message "Failed to write JSON summary: $($_.Exception.Message)"
    }
}

function Remove-BuildRoot {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-BuildLog -Context $Context -Message "Build root does not exist: $Path"
        return $true
    }

    Write-BuildLog -Context $Context -Message "Terminating potentially locking processes..."
    $processNames = @(
        "flutter", "dart",
        "msbuild", "devenv",
        "ninja", "cmake", "ctest",
        "cl", "link",
        "clang", "clang-cl", "lld-link",
        "vstest.console", "testhost",
        "cargo", "rustc"
    )

    foreach ($name in $processNames) {
        Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 3

    for ($i = 1; $i -le 8; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-BuildLog -Context $Context -Message "Build directory removed: $Path"
            return $true
        } catch {
            Write-BuildLogWarning -Context $Context -Message "Attempt $i/8 failed: $($_.Exception.Message)"

            foreach ($name in $processNames) {
                Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }

            if ($i -lt 8) { Start-Sleep -Seconds 2 }
        }
    }

    return $false
}

function Initialize-BuildCacheEnvironment {
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context,
        [string]$FastBuildDir = ""
    )

    $fastLocalCache = if (-not [string]::IsNullOrWhiteSpace($FastBuildDir)) {
        $FastBuildDir
    } elseif ($env:KATAGLYPHIS_FAST_BUILD_DIR) {
        $env:KATAGLYPHIS_FAST_BUILD_DIR
    } else {
        "C:\kataglyphis_fast_build"
    }

    $env:GLOBAL_CACHE_DIR = Join-Path $fastLocalCache ".cache"
    $env:SCCACHE_DIR      = Join-Path $env:GLOBAL_CACHE_DIR "sccache"
    $env:CARGO_HOME       = Join-Path $env:GLOBAL_CACHE_DIR "cargo"
    $env:PUB_CACHE        = Join-Path $env:GLOBAL_CACHE_DIR "pub-cache"

    foreach ($cachePath in @($env:SCCACHE_DIR, $env:CARGO_HOME, $env:PUB_CACHE)) {
        if (-not (Test-Path -LiteralPath $cachePath -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $cachePath | Out-Null
        }
    }

    $cargoBin = Join-Path $env:CARGO_HOME "bin"
    if ($env:PATH -notlike "*$cargoBin*") {
        $env:PATH = "$cargoBin;$env:PATH"
    }

    Write-BuildLog -Context $Context -Message "Initialized Fast Local Cache at: $fastLocalCache"
    return $fastLocalCache
}

function Sync-BuildArtifacts {
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context,
        [Parameter(Mandatory=$true)]
        [string]$Source,
        [Parameter(Mandatory=$true)]
        [string]$Destination,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @(),
        [switch]$ExcludeCommonRustAndCppCache
    )

    if ($ExcludeCommonRustAndCppCache) {
        $ExcludeFiles += @("*.obj", "*.tlog", "*.lastbuildstate", "*.idb", "*.ilk", "*.rlib", "*.rmeta", "*.d", "*.o", "*.pcm", "*.modmap", ".ninja_deps", ".ninja_log", "CMakeCache.txt")
        $ExcludeDirs += @("*.dir", ".fingerprint", "build", "deps", "incremental", "CMakeFiles", "vcpkg_installed", ".cmake")
    }

    Write-BuildLog -Context $Context -Message "Syncing artifacts from $Source to $Destination..."

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }

    $robocopyArgs = @(
        $Source,
        $Destination,
        "/E", "/MT:16", "/R:1", "/W:1", "/FFT", "/NOOFFLOAD"
    )

    if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) {
        $robocopyArgs += "/XF"
        $robocopyArgs += $ExcludeFiles
    }

    if ($ExcludeDirs -and $ExcludeDirs.Count -gt 0) {
        $robocopyArgs += "/XD"
        $robocopyArgs += $ExcludeDirs
    }

    $robocopyArgs += @("/NFL", "/NDL", "/NJH", "/NJS", "/nc", "/ns", "/np", "/LOG:nul")

    & robocopy.exe $robocopyArgs > $null 2>&1
    $exitCode = $LASTEXITCODE
    # Robocopy exit codes < 8 are considered success
    if ($exitCode -ge 8) {
        Write-BuildLogWarning -Context $Context -Message "Robocopy returned exit code $exitCode while syncing $Source to $Destination."
    }
}

function Show-SccacheStats {
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context
    )

    if (Get-Command "sccache" -ErrorAction SilentlyContinue) {
        Invoke-BuildStep -Context $Context -StepName "Sccache Statistics" -Script {
            Invoke-BuildExternal -Context $Context -File "sccache" -Parameters @("--show-stats")
        }
    }
}

function Assert-FlutterPluginsBuilt {
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context,
        [Parameter(Mandatory=$true)]
        [string]$CMakeFile,
        [Parameter(Mandatory=$true)]
        [string[]]$SearchDirectories
    )

    $expectedPlugins = @()
    if (Test-Path -LiteralPath $CMakeFile -PathType Leaf) {
        $cmakeContent = Get-Content $CMakeFile
        foreach ($line in $cmakeContent) {
            if ($line -match 'list\(APPEND FLUTTER_PLUGIN_LIST\s+"([^"]+)"\)') {
                $expectedPlugins += $matches[1]
            }
        }
        Write-BuildLog -Context $Context -Message "Expected Flutter plugins from generated CMake: $($expectedPlugins.Count)"
        foreach ($plugin in $expectedPlugins) {
            Write-BuildLog -Context $Context -Message "  - $plugin"
        }
    } else {
        Write-BuildLogWarning -Context $Context -Message "generated_plugins.cmake not found at '$CMakeFile'. Skipping expected plugin list."
    }

    $pluginArtifacts = @()
    foreach ($dir in $SearchDirectories) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $pluginArtifacts += Get-ChildItem -LiteralPath $dir -Recurse -File -Filter "*.dll"
        }
    }

    $pluginArtifacts = @($pluginArtifacts | Sort-Object -Property FullName -Unique)

    if ($pluginArtifacts.Count -eq 0) {
        Write-BuildLogWarning -Context $Context -Message "No plugin DLL artifacts found in search directories."
    } else {
        Write-BuildLog -Context $Context -Message "Built plugin DLL artifacts: $($pluginArtifacts.Count)"
        foreach ($artifact in $pluginArtifacts) {
            Write-BuildLog -Context $Context -Message "  - $($artifact.FullName)"
        }
    }

    if ($expectedPlugins.Count -gt 0 -and $pluginArtifacts.Count -gt 0) {
        foreach ($plugin in $expectedPlugins) {
            $matchedArtifact = $pluginArtifacts | Where-Object {
                $_.Name -like "$plugin*.dll" -or $_.FullName -like "*$plugin*"
            } | Select-Object -First 1

            if ($null -eq $matchedArtifact) {
                Write-BuildLogWarning -Context $Context -Message "Expected plugin '$plugin' has no matching DLL artifact name."
            } else {
                Write-BuildLog -Context $Context -Message "Plugin '$plugin' mapped to artifact: $($matchedArtifact.Name)"
            }
        }
    }
}

Export-ModuleMember -Function @(
    'New-BuildContext',
    'Open-BuildLog',
    'Close-BuildLog',
    'Write-BuildLog',
    'Write-BuildLogWarning',
    'Write-BuildLogError',
    'Write-BuildLogSuccess',
    'Invoke-BuildExternal',
    'Invoke-BuildOptional',
    'Invoke-BuildStep',
    'Write-BuildSummary',
    'Remove-BuildRoot',
    'Resolve-WorkspacePath',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'New-TimestampedFilePath',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList',
    'Initialize-BuildCacheEnvironment',
    'Sync-BuildArtifacts',
    'Show-SccacheStats',
    'Assert-FlutterPluginsBuilt'
)
