# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Reusable building blocks for an OpenCode agentic loop.
# Requires PowerShell 7+ (Core). Not compatible with PS 5.1's parser.
#
# PS 5.1 NOTE: The parser in Windows PowerShell 5.1 has trouble with certain
# string-interpolation patterns in scripts exceeding ~250 lines. This module
# works around that by running inside Import-Module's parser context.
# However, the CONSUMING script should be kept short (<200 lines) or run
# via pwsh (PowerShell 7).

Set-StrictMode -Version Latest
#requires -Version 7.0


# -- Module state ---------------------------------------------------------
$script:AgenticLogFile = $null
$script:AgenticLogToConsole = $true
$script:AgenticExitCode = 0
$script:AgenticStartTime = $null
$script:AgenticDryRun = $false

# -- Logging --------------------------------------------------------------
function Write-AgenticLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    if ($script:AgenticLogFile) { Add-Content -Path $script:AgenticLogFile -Value $line }
    if ($script:AgenticLogToConsole) { Write-Host $line }
}

function Write-AgenticSection {
    param([string]$Title)
    Write-AgenticLog ''
    Write-AgenticLog ('=' * 60)
    Write-AgenticLog $Title
    Write-AgenticLog ('=' * 60)
}

function Get-AgenticLogFile { return $script:AgenticLogFile }

# -- Initialization -------------------------------------------------------
function Initialize-AgenticLoop {
    param([string]$ConfigPath, [string]$RepoRoot = (Get-Location).Path, [switch]$DryRun)
    $script:AgenticDryRun = $DryRun
    $script:AgenticExitCode = 0
    $script:AgenticStartTime = Get-Date

    $logDir = Join-Path $RepoRoot 'logs/agentic-loop'
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($cfg.logging -and $cfg.logging.logDir) { $logDir = Join-Path $RepoRoot $cfg.logging.logDir }
        } catch { Write-Host "[AgenticLoop] Using default log dir" }
    }
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    $script:AgenticLogFile = Join-Path $logDir "agentic-loop_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
    Write-AgenticSection 'Agentic Loop Initialized'
    Write-AgenticLog "Log file: $script:AgenticLogFile"
    Write-AgenticLog "Dry run: $script:AgenticDryRun"
}

function Complete-AgenticLoop {
    param([int]$Iteration = 0, [int]$TasksCompleted = 0, [int]$ExitCode = $script:AgenticExitCode)
    $elapsed = if ($script:AgenticStartTime) { [math]::Round(((Get-Date) - $script:AgenticStartTime).TotalMinutes, 1) } else { 'N/A' }
    Write-AgenticSection 'Agentic Loop Finished'
    Write-AgenticLog "Exit code: $ExitCode"
    Write-AgenticLog "Total iterations: $Iteration"
    Write-AgenticLog "Total tasks completed: $TasksCompleted"
    Write-AgenticLog "Elapsed time: ${elapsed}min"
    Write-AgenticLog "Log file: $script:AgenticLogFile"
    if ($ExitCode -ne 0) {
        Write-AgenticLog 'The loop exited with errors.' 'WARN'
        Write-AgenticLog '  Check logs/agentic-loop/ for details.' 'WARN'
        Write-AgenticLog '  Run with -DryRun to test configuration.' 'WARN'
    }
    exit $ExitCode
}

# -- Platform -------------------------------------------------------------
function Get-AgenticPlatform { if ($env:OS -eq 'Windows_NT') { 'windows' } else { 'linux' } }
function Test-IsWindows { return (Get-AgenticPlatform) -eq 'windows' }

# -- OpenCode invocation --------------------------------------------------
function Invoke-OpenCode {
    param([string]$Agent, [string]$Model, [string]$Message)
    if ($script:AgenticDryRun) { Write-AgenticLog "[DRY RUN] opencode run --agent $Agent --model $Model"; return '[DRY RUN]' }
    if (-not (Get-Command 'opencode' -ErrorAction SilentlyContinue)) {
        Write-AgenticLog 'opencode not found on PATH.' 'FATAL'; $script:AgenticExitCode = 1; return $null
    }
    Write-AgenticLog "Invoking opencode: agent=$Agent model=$Model"
    $exit = 0; $output = $null
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmpFile, $Message, [System.Text.Encoding]::UTF8)
        $output = Get-Content $tmpFile -Raw | & opencode run --agent $Agent --model $Model
        $exit = $LASTEXITCODE
    } catch { Write-AgenticLog "opencode failed: $($_.Exception.Message)" 'ERROR'; $exit = 1
    } finally { if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force } }
    $outStr = $output -join "`n"
    $outLen = if ($outStr) { $outStr.Length } else { 0 }
    Write-AgenticLog "opencode: ${outLen} chars, exit $exit"
    if ($outLen -gt 0 -and $script:AgenticLogFile) {
        Add-Content $script:AgenticLogFile -Value '--- opencode output start ---'
        Add-Content $script:AgenticLogFile -Value $outStr
        Add-Content $script:AgenticLogFile -Value '--- opencode output end ---'
    }
    return $outStr
}

# -- BACKLOG helpers ------------------------------------------------------
function Get-UncheckedTaskCount {
    param([string]$BacklogPath = (Join-Path (Get-Location).Path 'BACKLOG.md'))
    if (-not (Test-Path $BacklogPath)) { return 0 }
    $content = Get-Content $BacklogPath -Raw
    return [regex]::Matches($content, '(?m)^- \[ \]').Count
}

# -- Git helpers ----------------------------------------------------------
function Invoke-GitAutoCommit {
    param([string]$Message, [string]$RepoRoot = (Get-Location).Path, [bool]$Enabled = $true)
    if (-not $Enabled) { return }
    if ($script:AgenticDryRun) { Write-AgenticLog "[DRY RUN] git commit -m '$Message'"; return }
    Push-Location $RepoRoot
    try { & git add -A 2>&1 | Out-Null; & git commit -m $Message 2>&1 | Out-Null; Write-AgenticLog "Committed: $Message"
    } finally { Pop-Location }
}

# -- Build / Test / Quality wrappers --------------------------------------
function Invoke-BuildCommand {
    param([string]$Command, [string]$Configuration = 'default')
    Write-AgenticSection "BUILD: $Configuration"
    Write-AgenticLog "Command: $Command"
    if ($script:AgenticDryRun) { return $true }
    $output = Invoke-Expression $Command 2>&1
    $outStr = $output -join "`n"
    $logFile = Get-AgenticLogFile
    if ($logFile) { Add-Content $logFile -Value '--- build start ---'; Add-Content $logFile -Value $outStr; Add-Content $logFile -Value '--- build end ---' }
    if ($LASTEXITCODE -ne 0) { Write-AgenticLog "BUILD FAILED (exit $LASTEXITCODE)" 'ERROR'; return $false }
    Write-AgenticLog 'BUILD PASSED'; return $true
}

function Invoke-TestCommand {
    param([string]$Command, [string]$RepoRoot)
    Write-AgenticSection 'TESTS'
    Write-AgenticLog "Command: $Command"
    if ($script:AgenticDryRun) { return $true }
    Push-Location $RepoRoot
    try {
        $output = Invoke-Expression $Command 2>&1
        $outStr = $output -join "`n"
        $logFile = Get-AgenticLogFile
        if ($logFile) { Add-Content $logFile -Value '--- test start ---'; Add-Content $logFile -Value $outStr; Add-Content $logFile -Value '--- test end ---' }
        if ($LASTEXITCODE -ne 0) { Write-AgenticLog "TESTS FAILED (exit $LASTEXITCODE)" 'ERROR'; return $false }
        Write-AgenticLog 'TESTS PASSED'; return $true
    } finally { Pop-Location }
}

function Invoke-QualityCommand {
    param([string]$Command, [string]$RepoRoot)
    Write-AgenticSection 'QUALITY'
    Write-AgenticLog "Command: $Command"
    if ($script:AgenticDryRun) { return }
    Push-Location $RepoRoot
    try {
        $output = Invoke-Expression $Command 2>&1
        $logFile = Get-AgenticLogFile
        if ($logFile) { Add-Content $logFile -Value '--- quality start ---'; Add-Content $logFile -Value ($output -join "`n"); Add-Content $logFile -Value '--- quality end ---' }
    } finally { Pop-Location }
}

# -- Main loop ------------------------------------------------------------
function Invoke-AgenticLoop {
    param(
        $Config, [string]$PlannerPrompt, [string]$ExecutorPrompt,
        [string[]]$BuildConfigs, [bool]$OnWindows, [string]$RepoRoot = (Get-Location).Path,
        [int]$MaxIterations = -1, [switch]$SkipBuild, [switch]$SkipTests, [switch]$SkipQuality,
        [switch]$PlannerOnly, [switch]$ExecutorOnly
    )
    $plannerModel = $Config.models.planner; $executorModel = $Config.models.executor
    $env:OPENCODE_PLANNER_MODEL = $plannerModel; $env:OPENCODE_EXECUTOR_MODEL = $executorModel

    $buildEveryN = $Config.intervals.buildEveryNTasks
    $qualityEveryN = $Config.intervals.qualityEveryNTasks
    $refactorEveryN = $Config.intervals.refactorEveryNIterations
    $maxIter = if ($MaxIterations -ge 0) { $MaxIterations } else { $Config.intervals.maxIterations }
    $maxRetries = $Config.intervals.maxExecutorRetries
    $loopDelay = $Config.intervals.loopDelaySeconds
    $autoCommit = if ($Config.git) { $Config.git.autoCommit } else { $true }
    $commitPrefix = if ($Config.git) { $Config.git.commitPrefix } else { 'agentic-loop' }

    $testCmd = if ($OnWindows) { $Config.build.windowsTestCommand } else { $Config.build.linuxTestCommand }
    $qualityCmd = if ($OnWindows) { $Config.build.windowsQualityCommand } else { $Config.build.linuxQualityCommand }

    $iteration = 0; $tasksDone = 0; $buildIdx = 0

    function LocalPlanner { param([switch]$Refactor)
        Write-AgenticSection 'PLANNER PHASE'
        Invoke-OpenCode -Agent 'planner' -Model $plannerModel -Message $(if ($Refactor) { $ExecutorPrompt } else { $PlannerPrompt })
        Write-AgenticLog 'Planner complete'
    }
    function LocalExecutor {
        Write-AgenticSection 'EXECUTOR PHASE'
        Invoke-OpenCode -Agent 'executor' -Model $executorModel -Message $ExecutorPrompt
        Write-AgenticLog 'Executor complete'
    }

    if ($PlannerOnly) { LocalPlanner -Refactor:$((($iteration+1) % $refactorEveryN -eq 0)); return }
    if ($ExecutorOnly) {
        $u = Get-UncheckedTaskCount
        while ($u -gt 0) { LocalExecutor; $tasksDone++; $u = Get-UncheckedTaskCount
            if (-not $SkipBuild -and ($tasksDone % $buildEveryN -eq 0)) { $cfg = $BuildConfigs[$buildIdx++ % $BuildConfigs.Count]; $ok = Invoke-BuildCommand -Command $(if ($OnWindows) { "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $RepoRoot 'Scripts/Windows/Build-Windows-Container.ps1')`" -Configurations `"$cfg`" -SkipTests" } else { "bash `"$(Join-Path $RepoRoot 'Scripts/Linux/cmake-configure-build.sh')`" --preset `"$cfg`" --build-dir build" }) -Configuration $cfg
                if ($ok -and (-not $SkipTests) -and $testCmd) { Invoke-TestCommand -Command $testCmd -RepoRoot $RepoRoot } }
            if (-not $SkipQuality -and ($qualityEveryN -gt 0) -and ($tasksDone % $qualityEveryN -eq 0) -and $qualityCmd) { Invoke-QualityCommand -Command $qualityCmd -RepoRoot $RepoRoot }
        }
        return
    }

    while ($true) {
        $iteration++
        Write-AgenticSection "ITERATION $iteration"
        if ($maxIter -gt 0 -and $iteration -gt $maxIter) { break }
        LocalPlanner -Refactor:$($iteration % $refactorEveryN -eq 0)

        $u = Get-UncheckedTaskCount; $retries = 0
        while ($u -gt 0) {
            LocalExecutor; $nu = Get-UncheckedTaskCount
            if ($nu -ge $u) { $retries++; if ($retries -ge $maxRetries) { break } } else {
                $retries = 0; $tasksDone++; $u = $nu
                Invoke-GitAutoCommit -Message "${commitPrefix}: task #${tasksDone}" -RepoRoot $RepoRoot -Enabled $autoCommit
                if (-not $SkipBuild -and ($tasksDone % $buildEveryN -eq 0)) {
                    $cfg = $BuildConfigs[$buildIdx++ % $BuildConfigs.Count]
                    $buildCmd = if ($OnWindows) { "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $RepoRoot 'Scripts/Windows/Build-Windows-Container.ps1')`" -Configurations `"$cfg`" -SkipTests" } else { "bash `"$(Join-Path $RepoRoot 'Scripts/Linux/cmake-configure-build.sh')`" --preset `"$cfg`" --build-dir build" }
                    $ok = Invoke-BuildCommand -Command $buildCmd -Configuration $cfg
                    if ($ok -and (-not $SkipTests) -and $testCmd) { Invoke-TestCommand -Command $testCmd -RepoRoot $RepoRoot }
                }
                if (-not $SkipQuality -and ($qualityEveryN -gt 0) -and ($tasksDone % $qualityEveryN -eq 0) -and $qualityCmd) { Invoke-QualityCommand -Command $qualityCmd -RepoRoot $RepoRoot }
            }
        }
        if ($loopDelay -gt 0 -and -not $script:AgenticDryRun) { Write-AgenticLog "Sleeping ${loopDelay}s..."; Start-Sleep $loopDelay }
    }
}
