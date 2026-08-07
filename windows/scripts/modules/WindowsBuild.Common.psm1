# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, ConvertTo-ParameterList, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# Guarded, WITHOUT -Force (repo-wide nested-import rule, 2026-08-04): a forced
# nested re-import rebinds the dependency into THIS module's private scope and
# unloads the caller's top-level import — the PS module-scoping trap that broke
# the BuildDriver test suite and forced build-gstreamer's import-Shared-twice
# workaround. Trade-off (accepted): a long-lived dev session that edits Shared
# must Remove-Module/reimport manually; containers always start fresh.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# -- Logging primitives (module-internal; formerly WindowsLogging.Common.psm1, whose
# only consumer was this module). Scripts use the Write-BuildLog* wrappers below. --

function New-LogContext {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$LogDir,
        [string]$LogFilePrefix = 'session'
    )

    $effectiveLogDir = if ([System.IO.Path]::IsPathRooted($LogDir)) { $LogDir } else { Join-Path $Workspace $LogDir }
    $logDirPath = Resolve-DirectoryPath -Path $effectiveLogDir
    $timestamp = New-Timestamp -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $logDirPath "$LogFilePrefix-$timestamp.log"

    [pscustomobject]@{
        Workspace = $Workspace
        LogPath   = $logPath
        StartedAt = (Get-Date).ToString('o')
        LogWriter = $null
    }
}

function Open-LogWriter {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $parentDir = Split-Path -Parent $Context.LogPath
    if ($parentDir) {
        Resolve-DirectoryPath -Path $parentDir | Out-Null
    }

    $fileStream = New-Object System.IO.FileStream(
        $Context.LogPath,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )

    $writer = New-Object System.IO.StreamWriter($fileStream, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true
    $Context.LogWriter = $writer
}

function Close-LogWriter {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    if ($Context.LogWriter) {
        try {
            $Context.LogWriter.Flush()
            $Context.LogWriter.Dispose()
        } catch {
            # Best-effort: the writer may already be disposed on double-close.
            Write-Verbose "log writer dispose: $($_.Exception.Message)"
        } finally {
            $Context.LogWriter = $null
        }
    }
}

function Write-ContextLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $suppressConsoleOutput = $false
    if ($null -ne $Context.PSObject.Properties['SuppressConsoleOutput']) {
        $suppressConsoleOutput = [bool]$Context.SuppressConsoleOutput
    }

    if (-not $Message) {
        if (-not $suppressConsoleOutput) {
            Write-Host ''
        }
        if ($Context.LogWriter) {
            $Context.LogWriter.WriteLine('')
        }
        return
    }

    if (-not $suppressConsoleOutput) {
        switch ($Level) {
            'Warning' {
                Write-Warning $Message
            }
            'Error' {
                Write-Host $Message -ForegroundColor Red
            }
            'Success' {
                Write-Host $Message -ForegroundColor Green
            }
            default {
                Write-Host $Message
            }
        }
    }

    if ($Context.LogWriter) {
        $timestamp = Get-Date -Format 'HH:mm:ss'
        $prefix = switch ($Level) {
            'Warning' { 'WARNING: ' }
            'Error' { 'ERROR: ' }
            'Success' { 'SUCCESS: ' }
            default { '' }
        }

        $Context.LogWriter.WriteLine("[$timestamp] $prefix$Message")
    }
}

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
            Succeeded       = New-Object System.Collections.Generic.List[string]
            Failed          = New-Object System.Collections.Generic.List[string]
            # Steps that failed but were declared non-gating (Invoke-BuildStep -AllowFailure),
            # e.g. experimental toolchains. Reported in the summary but do NOT set exit 1.
            AllowedFailures = New-Object System.Collections.Generic.List[string]
            Errors          = @{}
            Durations       = [ordered]@{}
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
        [switch]$IgnoreExitCode,
        # Secret VALUES (passwords, tokens) that must never reach the log: any
        # parameter that exactly matches one of these strings is shown as
        # '<redacted>' in the logged/thrown command line. Execution is
        # unaffected - the real values are still passed to the process.
        # Optional and additive: existing callers are unchanged.
        [string[]]$RedactParameterValues
    )

    $parameterList = ConvertTo-ParameterList -Value $Parameters

    # Coerce to an array to ensure .Count property exists even when ConvertTo-ParameterList
    # returns a scalar or unexpected type. This prevents errors like "The property
    # 'Count' cannot be found on this object." when callers pass strings.
    $parameterList = @($parameterList)

    # Display copy of the parameter list for logging/error messages only.
    $logParameterList = $parameterList
    $secretValues = @($RedactParameterValues | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($secretValues.Count -gt 0) {
        $logParameterList = @($parameterList | ForEach-Object {
                if ($secretValues -ccontains $_) { '<redacted>' } else { $_ }
            })
    }

    $cmdLine = if ($logParameterList -and $logParameterList.Count) { "$File $($logParameterList -join ' ')" } else { $File }
    Write-BuildLog -Context $Context -Message "CMD: $cmdLine"

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    # Test-Path guard: before the first native call of a session LASTEXITCODE
    # does not exist, and reading it under StrictMode raises a noisy error.
    $previousLastExitCode = if (Test-Path variable:global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 }
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
        $global:LASTEXITCODE = $previousLastExitCode
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
        [switch]$Critical,
        # When set, a failure is recorded as a non-gating AllowedFailure (warning, not error) and
        # never throws -- for steps that are permitted to fail (e.g. experimental Python builds).
        [switch]$AllowFailure
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
        if ($null -eq $Context.Results.Durations) {
            $Context.Results.Durations = [ordered]@{}
        }
        $Context.Results.Durations[$StepName] = $stopwatch.Elapsed.TotalSeconds
        $Context.Results.Errors[$StepName] = $errorMessage

        if ($AllowFailure) {
            $Context.Results.AllowedFailures.Add($StepName) | Out-Null
            Write-BuildLogWarning -Context $Context -Message "<<< FAILED (allowed, non-gating): $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
            Write-BuildLogWarning -Context $Context -Message "    Error: $errorMessage"
            return $false
        }

        $Context.Results.Failed.Add($StepName) | Out-Null
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

    if ($null -ne $Context.Results.AllowedFailures -and $Context.Results.AllowedFailures.Count -gt 0) {
        Write-BuildLog -Context $Context -Message ""
        Write-BuildLogWarning -Context $Context -Message "ALLOWED FAILURES ($($Context.Results.AllowedFailures.Count)) -- non-gating (did not fail the run):"
        foreach ($step in $Context.Results.AllowedFailures) {
            Write-BuildLogWarning -Context $Context -Message "  [!] $step"
            Write-BuildLogWarning -Context $Context -Message "      Error: $($Context.Results.Errors[$step])"
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

function Get-PyprojectPackageName {
    # Package name for CI runs: pyproject.toml [project] name, falling back to
    # the repo-root leaf directory. Shared by the python CI entry scripts.
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [string]$Default = ''
    )

    if (-not [string]::IsNullOrEmpty($Default)) { return $Default }
    $pyproject = Join-Path $RepoRoot 'pyproject.toml'
    if (Test-Path $pyproject) {
        $content = Get-Content $pyproject -Raw
        if ($content -match 'name\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    return (Split-Path $RepoRoot -Leaf)
}

function New-UvBuildDelegates {
    # The three delegates every python CI entry script hands to
    # New-UvProjectEnvironment/Remove-UvProjectEnvironment, bound to one build
    # context. Defined HERE (not WindowsUv.Common) so the closures resolve
    # Invoke-BuildExternal/Write-BuildLog* in the module that owns them.
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    return @{
        CommandRunner = {
            param([string]$File, [string[]]$CommandArgs)
            Invoke-BuildExternal -Context $Context -File $File -Parameters $CommandArgs | Out-Null
        }.GetNewClosure()
        LogInfo    = { param([string]$Message); Write-BuildLog -Context $Context -Message $Message }.GetNewClosure()
        LogWarning = { param([string]$Message); Write-BuildLogWarning -Context $Context -Message $Message }.GetNewClosure()
    }
}

Export-ModuleMember -Function @(
    'Get-PyprojectPackageName',
    'New-UvBuildDelegates',
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
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList'
)

# --------------------------------------------------------------------------
# Restored from 04e1e07 (pre-refactor): functions still consumed by
# downstream Build-Windows.ps1 scripts (Kataglyphis-Inference-Engine).
# --------------------------------------------------------------------------
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
    
    # If sccache is present on PATH, enable compiler wrapper environment
    # variables globally so downstream CMake/configure steps will pick up
    # sccache without requiring explicit caller configuration. This can be
    # disabled by clearing the variables later or passing DisableSccache to
    # the specific build invocation.
    $sccacheCmd = Get-Command 'sccache' -ErrorAction SilentlyContinue
    if ($sccacheCmd) {
        $sccacheExe = $sccacheCmd.Source
        Write-BuildLog -Context $Context -Message "DEBUG: sccache found at: $sccacheExe. Enabling compiler cache."
        $env:CMAKE_C_COMPILER_LAUNCHER = $sccacheExe
        $env:CMAKE_CXX_COMPILER_LAUNCHER = $sccacheExe
        $env:RUSTC_WRAPPER = $sccacheExe
        $env:CC_WRAPPER = $sccacheExe
        $env:CXX_WRAPPER = $sccacheExe

        if (-not $env:SCCACHE_MAX_JOBS) {
            $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString()
            Write-BuildLog -Context $Context -Message "DEBUG: AUTO-SET SCCACHE_MAX_JOBS=$($env:SCCACHE_MAX_JOBS) (from Initialize-BuildCacheEnvironment)"
        }
    }
    return $fastLocalCache
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

function Show-SccacheStats {
    # The pipeline-step face of the shared sccache reader. Only the sink (a named
    # build step writing through Write-BuildLog) is local; the invocation is
    # Get-SccacheStatsText (WindowsScripts.Shared), shared with
    # WindowsSourceBuild.Common's Write-SccacheStats and WindowsCMake.Common's
    # pre/post-build dumps. Unlike the former Invoke-BuildExternal call, a
    # non-zero sccache exit no longer fails the step -- stats are diagnostics,
    # not a gate, which is what the other two call sites already assumed.
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context
    )

    if (Get-Command "sccache" -ErrorAction SilentlyContinue) {
        Invoke-BuildStep -Context $Context -StepName "Sccache Statistics" -Script {
            $statsLines = Get-SccacheStatsText
            if ($null -ne $statsLines) {
                foreach ($line in $statsLines) {
                    Write-BuildLog -Context $Context -Message $line
                }
            }
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

Export-ModuleMember -Function Initialize-BuildCacheEnvironment, Remove-BuildRoot, Show-SccacheStats, Assert-FlutterPluginsBuilt


