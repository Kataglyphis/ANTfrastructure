# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Reusable building blocks for a planner/executor agentic loop.
# Requires PowerShell 7+ (Core). Not compatible with PS 5.1's parser.
#
# Supports two engines:
#   opencode — invokes `opencode run --agent <role> --model <model>`
#   claude   — invokes `claude -p --model <model>` (Claude Code CLI) with a
#              role system prompt appended from a prompt file
#
# Engine selection: $env:AGENTIC_ENGINE > config .engine > 'opencode'.
# Model overrides:  $env:AGENTIC_PLANNER_MODEL / $env:AGENTIC_EXECUTOR_MODEL.

Set-StrictMode -Version Latest
#requires -Version 7.0


# -- Module state ---------------------------------------------------------
$script:AgenticLogFile = $null
$script:AgenticLogToConsole = $true
$script:AgenticExitCode = 0
# Seeded here, not only inside Invoke-AgenticLoop: consumers call
# Complete-AgenticLoop from a finally block, and its defaults read these. If
# Invoke-AgenticLoop throws BEFORE setting them (bad config, missing build
# matrix), StrictMode turns the teardown into "the variable
# $script:AgenticIterations cannot be retrieved", which masks the real error
# the user needs to see.
$script:AgenticIterations = 0
$script:AgenticTasksCompleted = 0
$script:AgenticStartTime = $null
$script:AgenticDryRun = $false
$script:AgenticTimeoutSeconds = $null

# -- Logging --------------------------------------------------------------
function Write-AgenticLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    if ($script:AgenticLogFile) { Add-Content -Path $script:AgenticLogFile -Value $line }
    if ($script:AgenticLogToConsole) { Write-Host $line }
    # A FATAL must survive into the process exit code. Consumers call
    # Complete-AgenticLoop from a finally block, and it exits with
    # $script:AgenticExitCode - which stayed 0 even after a fatal config
    # error, so an unattended run reported success while having done nothing.
    if ($Level -eq 'FATAL') { $script:AgenticExitCode = 1 }
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
    param([string]$ConfigPath, [string]$RepoRoot = (Get-Location).Path, [switch]$DryRun, [int]$TimeoutSeconds = 0)
    $script:AgenticDryRun = $DryRun
    $script:AgenticExitCode = 0
    $script:AgenticStartTime = Get-Date
    if ($TimeoutSeconds -gt 0) { $script:AgenticTimeoutSeconds = $TimeoutSeconds }

    $logDir = Join-Path $RepoRoot 'logs/agentic-loop'
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $logging = Get-AgenticConfigValue $cfg 'logging' $null
            $cfgLogDir = Get-AgenticConfigValue $logging 'logDir' $null
            if ($cfgLogDir) { $logDir = Join-Path $RepoRoot $cfgLogDir }
        } catch { Write-Host "[AgenticLoop] Using default log dir" }
    }
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    $script:AgenticLogFile = Join-Path $logDir "agentic-loop_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
    Write-AgenticSection 'Agentic Loop Initialized'
    Write-AgenticLog "Log file: $script:AgenticLogFile"
    Write-AgenticLog "Dry run: $script:AgenticDryRun"
}

function Complete-AgenticLoop {
    # Defaults come from the counters Invoke-AgenticLoop maintains in script
    # scope, so argless callers still report the real totals.
    param(
        [int]$Iteration = [int]$script:AgenticIterations,
        [int]$TasksCompleted = [int]$script:AgenticTasksCompleted,
        [int]$ExitCode = $script:AgenticExitCode
    )
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

# -- Config helpers -------------------------------------------------------
function Get-AgenticConfigValue {
    <#
    .SYNOPSIS
      StrictMode-safe property lookup that works for both hashtables (tests)
      and PSCustomObjects (ConvertFrom-Json). Returns $Default when the key
      is absent or null.
    #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Get-AgenticBuildConfigs {
    <#
    .SYNOPSIS
      Resolve the per-platform build configuration list from the loop config.
      Prefers buildMatrix (richer: per-config sanitizer, testCommand,
      buildDir); falls back to legacy buildConfigurations (string arrays).
      Returns $null when neither is present.
    #>
    param($Config, [bool]$OnWindows = (Test-IsWindows))
    $platform = if ($OnWindows) { 'windows' } else { 'linux' }
    foreach ($key in @('buildMatrix', 'buildConfigurations')) {
        $section = Get-AgenticConfigValue $Config $key $null
        if ($section) {
            $configs = Get-AgenticConfigValue $section $platform $null
            # ',' keeps a single-entry list an array through return unrolling.
            if ($configs) { return ,@($configs) }
        }
    }
    return $null
}

function Resolve-AgenticEngine {
    <#
    .SYNOPSIS
      Resolve the engine configuration (opencode | claude) from the loop
      config into a flat hashtable consumed by Invoke-AgenticAgent.
      Precedence: -EngineOverride > $env:AGENTIC_ENGINE > config .engine.
      Models: env override > .engines.<engine>.* > legacy .models.*.
    #>
    param($Config, [string]$RepoRoot = (Get-Location).Path, [string]$EngineOverride = '')
    $engine = if ($EngineOverride) { $EngineOverride }
              elseif ($env:AGENTIC_ENGINE) { $env:AGENTIC_ENGINE }
              else { Get-AgenticConfigValue $Config 'engine' 'opencode' }
    if ($engine -notin @('opencode', 'claude')) {
        throw "Unknown agentic engine: '$engine' (expected opencode|claude)"
    }

    $engines = Get-AgenticConfigValue $Config 'engines' $null
    $engineCfg = if ($engines) { Get-AgenticConfigValue $engines $engine $null } else { $null }
    $legacyModels = Get-AgenticConfigValue $Config 'models' $null

    $plannerModel = if ($env:AGENTIC_PLANNER_MODEL) { $env:AGENTIC_PLANNER_MODEL }
                    else { Get-AgenticConfigValue $engineCfg 'plannerModel' (Get-AgenticConfigValue $legacyModels 'planner' $null) }
    $executorModel = if ($env:AGENTIC_EXECUTOR_MODEL) { $env:AGENTIC_EXECUTOR_MODEL }
                     else { Get-AgenticConfigValue $engineCfg 'executorModel' (Get-AgenticConfigValue $legacyModels 'executor' $null) }
    if (-not $plannerModel -or -not $executorModel) {
        throw "No planner/executor model configured for engine '$engine' (need .engines.$engine.plannerModel/executorModel or legacy .models.*)"
    }

    # Prompt files are stored repo-relative in the config
    $plannerPromptFile = Get-AgenticConfigValue $engineCfg 'plannerPromptFile' $null
    $executorPromptFile = Get-AgenticConfigValue $engineCfg 'executorPromptFile' $null
    if ($plannerPromptFile -and -not [System.IO.Path]::IsPathRooted($plannerPromptFile)) {
        $plannerPromptFile = Join-Path $RepoRoot $plannerPromptFile
    }
    if ($executorPromptFile -and -not [System.IO.Path]::IsPathRooted($executorPromptFile)) {
        $executorPromptFile = Join-Path $RepoRoot $executorPromptFile
    }

    $intervals = Get-AgenticConfigValue $Config 'intervals' $null
    return @{
        Engine                 = $engine
        PlannerModel           = $plannerModel
        ExecutorModel          = $executorModel
        PlannerFallbackModel   = Get-AgenticConfigValue $engineCfg 'plannerFallbackModel' $null
        PlannerPromptFile      = $plannerPromptFile
        ExecutorPromptFile     = $executorPromptFile
        PermissionMode         = Get-AgenticConfigValue $engineCfg 'permissionMode' 'bypassPermissions'
        PlannerAllowedTools    = Get-AgenticConfigValue $engineCfg 'plannerAllowedTools' $null
        ExtraArgs              = Get-AgenticConfigValue $engineCfg 'extraArgs' $null
        StreamOutput           = [bool](Get-AgenticConfigValue $engineCfg 'streamOutput' $true)
        TimeoutSeconds         = [int](Get-AgenticConfigValue $intervals 'timeoutSeconds' 0)
        PlannerTimeoutSeconds  = [int](Get-AgenticConfigValue $intervals 'plannerTimeoutSeconds' 0)
        ExecutorTimeoutSeconds = [int](Get-AgenticConfigValue $intervals 'executorTimeoutSeconds' 0)
        AgentRetries           = [int](Get-AgenticConfigValue $intervals 'agentRetries' 2)
        AgentRetryDelaySeconds = [int](Get-AgenticConfigValue $intervals 'agentRetryDelaySeconds' 20)
        WaitForUsageLimitReset = [bool](Get-AgenticConfigValue $intervals 'waitForUsageLimitReset' $true)
    }
}

function Get-UsageLimitWaitSeconds {
    <#
    .SYNOPSIS
      Detect a Claude usage/session-limit failure in agent output and return
      how many seconds to sleep until the stated reset (plus a 2-minute
      buffer). Returns 0 when the output is not a usage-limit failure, and
      30 minutes when the limit is detected but the reset time can't be
      parsed. The reset time in the message ("resets 11pm (Europe/Berlin)")
      is interpreted in local time.
    #>
    param([string]$Output)
    if (-not $Output) { return 0 }
    if ($Output -notmatch "(?i)hit your (session|usage|weekly|5-hour) limit|usage limit reached") { return 0 }
    $m = [regex]::Match($Output, '(?i)resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)')
    if (-not $m.Success) { return 1800 }
    $hour = [int]$m.Groups[1].Value
    $minute = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
    $ampm = $m.Groups[3].Value.ToLowerInvariant()
    if ($ampm -eq 'pm' -and $hour -ne 12) { $hour += 12 }
    if ($ampm -eq 'am' -and $hour -eq 12) { $hour = 0 }
    $now = Get-Date
    $reset = Get-Date -Hour $hour -Minute $minute -Second 0 -Millisecond 0
    if ($reset -le $now) { $reset = $reset.AddDays(1) }
    return [int](($reset - $now).TotalSeconds) + 120
}

function Get-AgentTimeoutForRole {
    param([hashtable]$EngineConfig, [string]$Role)
    if ($Role -eq 'planner' -and $EngineConfig.PlannerTimeoutSeconds -gt 0) { return $EngineConfig.PlannerTimeoutSeconds }
    if ($Role -ne 'planner' -and $EngineConfig.ExecutorTimeoutSeconds -gt 0) { return $EngineConfig.ExecutorTimeoutSeconds }
    return $EngineConfig.TimeoutSeconds
}

# -- Generic agent process runner -----------------------------------------
function Invoke-AgentProcess {
    <#
    .SYNOPSIS
      Run a CLI agent process with the prompt piped via stdin. Stdout and
      stderr are streamed to the console AND the agentic log file in real
      time. Returns @{ ExitCode; Output }.  TimeoutSeconds 0 = no timeout.
    #>
    # PSSA false positive: the thread-job scriptblocks receive these variables
    # via -ArgumentList + param() (the documented pattern for Start-ThreadJob);
    # $using: is the alternative, not a requirement.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'vars passed via -ArgumentList/param')]
    param([string]$Executable, [string[]]$ArgumentList, [string]$Message,
          [int]$TimeoutSeconds = 0, [string]$Label = 'agent', [switch]$RenderClaudeStream)
    $cmdInfo = Get-Command $Executable -ErrorAction SilentlyContinue
    if (-not $cmdInfo) {
        Write-AgenticLog "$Executable not found on PATH." 'FATAL'
        $script:AgenticExitCode = 1
        return @{ ExitCode = 127; Output = '' }
    }
    $logFile = $script:AgenticLogFile
    $exitCode = 0; $outStr = ''
    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmdInfo.Source
        foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $p.Start() | Out-Null

        # Feed stdin
        $stdin = $p.StandardInput
        $stdin.Write($Message)
        $stdin.Close()

        # Read stdout + stderr concurrently via Start-ThreadJob to avoid deadlock.
        $outLines = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
        $errLines = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
        $renderStream = [bool]$RenderClaudeStream
        $stdoutJob = Start-ThreadJob -Name "agent-stdout-$Label" -ArgumentList $p, $logFile, $outLines, $renderStream -ScriptBlock {
            param($p, $logFile, $outLines, $renderStream)
            # Emit a line to console + log. [Console]::Out (not Write-Host):
            # thread-job host output is buffered until Receive-Job, which
            # would defeat live streaming in the terminal.
            $emit = { param($text) [Console]::Out.WriteLine($text); if ($logFile) { Add-Content $logFile -Value $text } }
            $r = $p.StandardOutput
            try {
                while ($null -ne ($line = $r.ReadLine())) {
                    $outLines.Add($line)
                    if ($renderStream -and $line.StartsWith('{')) {
                        # Render claude stream-json events as compact progress lines
                        # Per-line JSON probe: non-JSON lines are expected and
                        # fall through to the plain-text emit below.
                        $evt = $null
                        try { $evt = $line | ConvertFrom-Json } catch { $evt = $null }
                        if ($evt -and $evt.PSObject.Properties['type']) {
                            switch ($evt.type) {
                                'system' {
                                    if ($evt.subtype -eq 'init') { & $emit "[claude] session started (model: $($evt.model))" }
                                }
                                'assistant' {
                                    foreach ($c in @($evt.message.content)) {
                                        if ($c.type -eq 'tool_use') {
                                            $detail = $c.input.file_path
                                            if (-not $detail) { $detail = $c.input.command }
                                            if (-not $detail) { $detail = $c.input.pattern }
                                            if (-not $detail) { $detail = $c.input.description }
                                            if (-not $detail) { $detail = $c.input.prompt }
                                            $detail = "$detail" -replace "`r?`n", ' '
                                            if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) + '...' }
                                            & $emit "  -> $($c.name): $detail"
                                        } elseif ($c.type -eq 'text' -and $c.text) {
                                            & $emit $c.text
                                        }
                                    }
                                }
                                'user' {
                                    foreach ($c in @($evt.message.content)) {
                                        if ($c.type -eq 'tool_result' -and $c.is_error) {
                                            $txt = "$($c.content)" -replace "`r?`n", ' '
                                            if ($txt.Length -gt 200) { $txt = $txt.Substring(0, 200) + '...' }
                                            & $emit "  !! tool error: $txt"
                                        }
                                    }
                                }
                                'result' {
                                    $dur = [math]::Round(($evt.duration_ms / 1000), 1)
                                    $cost = [math]::Round(($evt.total_cost_usd), 4)
                                    & $emit "[claude] result: $($evt.num_turns) turns, ${dur}s, `$$cost"
                                    if ($evt.result) { & $emit $evt.result }
                                }
                            }
                            continue
                        }
                    }
                    & $emit $line
                }
            } catch { Write-Verbose "stdout stream closed: $($_.Exception.Message)" }
        }
        $stderrJob = Start-ThreadJob -Name "agent-stderr-$Label" -ArgumentList $p, $logFile, $errLines -ScriptBlock {
            param($p, $logFile, $errLines)
            $r = $p.StandardError
            try {
                while ($null -ne ($line = $r.ReadLine())) {
                    $errLines.Add($line)
                    [Console]::Error.WriteLine($line)
                    if ($logFile) { Add-Content $logFile -Value $line }
                }
            } catch { Write-Verbose "stderr stream closed: $($_.Exception.Message)" }
        }

        if ($TimeoutSeconds -gt 0) {
            $completed = $p.WaitForExit($TimeoutSeconds * 1000)
            if (-not $completed) {
                $p.Kill($true)
                Write-AgenticLog "$Label timed out after ${TimeoutSeconds}s" 'ERROR'
                $exitCode = -1
            } else { $exitCode = $p.ExitCode }
        } else {
            $p.WaitForExit()
            $exitCode = $p.ExitCode
        }

        # Drain readers
        Receive-Job -Job $stdoutJob -Wait -ErrorAction SilentlyContinue | Out-Null
        Receive-Job -Job $stderrJob -Wait -ErrorAction SilentlyContinue | Out-Null

        $outStr = $outLines -join "`n"
        $errStr = $errLines -join "`n"
        if ($errStr) {
            Write-AgenticLog "$Label had stderr output" 'WARN'
            if ($logFile) { Add-Content $logFile -Value '--- stderr ---'; Add-Content $logFile -Value $errStr; Add-Content $logFile -Value '--- stderr end ---' }
        }
    } catch {
        Write-AgenticLog "$Label failed: $($_.Exception.Message)" 'ERROR'
        $exitCode = 1
    } finally {
        if ($p -and -not $p.HasExited) { $p.Kill($true) }
        if ($p) { $p.Dispose() }
    }
    Write-AgenticLog "${Label}: $($outStr.Length) chars, exit $exitCode"
    return @{ ExitCode = $exitCode; Output = $outStr }
}

# -- OpenCode invocation --------------------------------------------------
function Invoke-OpenCode {
    <#
    .SYNOPSIS
      Invoke opencode with a prompt via stdin. Returns the captured stdout
      string ($null when opencode is missing).
    #>
    param([string]$Agent, [string]$Model, [string]$Message, [int]$TimeoutSeconds = 300)
    if ($script:AgenticTimeoutSeconds -gt 0) { $TimeoutSeconds = $script:AgenticTimeoutSeconds }
    if ($script:AgenticDryRun) { Write-AgenticLog "[DRY RUN] opencode run --agent $Agent --model $Model"; return '[DRY RUN]' }
    Write-AgenticLog "Invoking opencode: agent=$Agent model=$Model (timeout=${TimeoutSeconds}s)"
    $result = Invoke-AgentProcess -Executable 'opencode' `
        -ArgumentList @('run', '--agent', $Agent, '--model', $Model) `
        -Message $Message -TimeoutSeconds $TimeoutSeconds -Label "opencode-$Agent"
    if ($result.ExitCode -eq 127) { return $null }
    if ($result.ExitCode -ne 0) { Write-AgenticLog "opencode exited with code $($result.ExitCode) (agent=$Agent)" 'WARN' }
    return $result.Output
}

# -- Claude Code invocation -----------------------------------------------
function Invoke-ClaudeCode {
    <#
    .SYNOPSIS
      Headless Claude Code run (`claude -p`) with the task message via stdin
      and the role system prompt appended from a file. The planner is
      sandboxed via --allowed-tools; the executor runs with the configured
      permission mode (default bypassPermissions — intended for trusted
      repos / sandboxes). Returns @{ ExitCode; Output }.
    #>
    param([string]$Role, [string]$Model, [string]$Message, [hashtable]$EngineConfig)
    $timeoutSeconds = Get-AgentTimeoutForRole -EngineConfig $EngineConfig -Role $Role
    if ($script:AgenticDryRun) {
        Write-AgenticLog "[DRY RUN] claude -p --model $Model (role=$Role)"
        return @{ ExitCode = 0; Output = '[DRY RUN]' }
    }

    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@('-p', '--model', $Model))
    if ($EngineConfig.StreamOutput) {
        # stream-json emits an event per assistant turn / tool call, so the
        # console and log show live progress instead of silence-until-done.
        $argList.AddRange([string[]]@('--output-format', 'stream-json', '--verbose'))
    } else {
        $argList.AddRange([string[]]@('--output-format', 'text'))
    }

    $promptFile = if ($Role -eq 'planner') { $EngineConfig.PlannerPromptFile } else { $EngineConfig.ExecutorPromptFile }
    if ($promptFile) {
        if (Test-Path $promptFile) { $argList.AddRange([string[]]@('--append-system-prompt-file', $promptFile)) }
        else { Write-AgenticLog "Prompt file not found: $promptFile (continuing without role prompt)" 'WARN' }
    }

    if ($Role -eq 'planner' -and $EngineConfig.PlannerAllowedTools) {
        # Planner sandbox: only the listed tools are allowed; everything else
        # is denied in -p mode (no interactive prompt to approve).
        $argList.Add('--allowed-tools')
        foreach ($tool in ($EngineConfig.PlannerAllowedTools -split '\s+' | Where-Object { $_ })) { $argList.Add($tool) }
    } elseif ($EngineConfig.PermissionMode -eq 'bypassPermissions') {
        $argList.Add('--dangerously-skip-permissions')
    } else {
        $argList.AddRange([string[]]@('--permission-mode', $EngineConfig.PermissionMode))
    }

    if ($Role -eq 'planner' -and $EngineConfig.PlannerFallbackModel) {
        $argList.AddRange([string[]]@('--fallback-model', $EngineConfig.PlannerFallbackModel))
    }

    if ($EngineConfig.ExtraArgs) {
        foreach ($extra in ($EngineConfig.ExtraArgs -split '\s+' | Where-Object { $_ })) { $argList.Add($extra) }
    }

    Write-AgenticLog "Invoking claude: role=$Role model=$Model (timeout=${timeoutSeconds}s)"
    $result = Invoke-AgentProcess -Executable 'claude' -ArgumentList $argList.ToArray() `
        -Message $Message -TimeoutSeconds $timeoutSeconds -Label "claude-$Role" `
        -RenderClaudeStream:$EngineConfig.StreamOutput
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 127) {
        Write-AgenticLog "claude exited with code $($result.ExitCode) (role=$Role)" 'WARN'
        if ($result.Output -match '(?i)not logged in|invalid api key') {
            Write-AgenticLog "Authentication error. Run 'claude' interactively once to log in." 'ERROR'
        }
    }
    return $result
}

# -- Engine dispatcher with retry/backoff ---------------------------------
function Invoke-AgenticAgent {
    <#
    .SYNOPSIS
      Dispatch a role (planner | executor | fixer) to the configured engine
      with retry + linear backoff. The fixer role uses the executor model.
      Returns $true on success.
    #>
    param([string]$Role, [string]$Message, [hashtable]$EngineConfig)
    $model = if ($Role -eq 'planner') { $EngineConfig.PlannerModel } else { $EngineConfig.ExecutorModel }
    $retries = $EngineConfig.AgentRetries
    $delay = $EngineConfig.AgentRetryDelaySeconds
    $attempt = 0
    $limitWaits = 0
    while ($true) {
        $exitCode = 0
        $outputText = ''
        switch ($EngineConfig.Engine) {
            'claude' {
                $result = Invoke-ClaudeCode -Role $Role -Model $model -Message $Message -EngineConfig $EngineConfig
                $exitCode = $result.ExitCode
                $outputText = $result.Output
            }
            'opencode' {
                $ocAgent = if ($Role -eq 'fixer') { 'executor' } else { $Role }
                $timeoutSeconds = Get-AgentTimeoutForRole -EngineConfig $EngineConfig -Role $Role
                $out = Invoke-OpenCode -Agent $ocAgent -Model $model -Message $Message -TimeoutSeconds $timeoutSeconds
                $exitCode = if ($null -eq $out) { 1 } else { 0 }
                $outputText = "$out"
            }
            default { Write-AgenticLog "Unknown engine: $($EngineConfig.Engine)" 'FATAL'; return $false }
        }
        if ($exitCode -eq 0) { return $true }
        # Usage/session-limit failures are not real errors: sleep until the
        # stated reset and try again without burning a retry. Capped so a
        # stuck limit can't spin forever (each pass sleeps >= 30 min anyway).
        $limitWait = Get-UsageLimitWaitSeconds -Output $outputText
        if ($limitWait -gt 0 -and $EngineConfig.WaitForUsageLimitReset -and $limitWaits -lt 10 -and -not $script:AgenticDryRun) {
            $limitWaits++
            $until = (Get-Date).AddSeconds($limitWait).ToString('HH:mm')
            Write-AgenticLog "Usage limit hit (role=$Role). Waiting $([math]::Round($limitWait/60,1)) min until reset (~$until, wait $limitWaits/10) — not counted against retries." 'WARN'
            Start-Sleep -Seconds $limitWait
            continue
        }
        $attempt++
        if ($attempt -gt $retries) {
            Write-AgenticLog "Agent failed after $attempt attempt(s) (role=$Role, exit=$exitCode)" 'ERROR'
            return $false
        }
        $sleepS = $delay * $attempt
        Write-AgenticLog "Agent failed (exit=$exitCode). Retry $attempt/$retries in ${sleepS}s..." 'WARN'
        if (-not $script:AgenticDryRun) { Start-Sleep -Seconds $sleepS }
    }
}

# -- Default phase prompts ------------------------------------------------
# Single source of truth shared with linux/scripts/lib/agentic-loop.sh:
# shared/agentic-loop/prompts/*.md at the repo root.
function Get-AgenticDefaultPrompt {
    param([Parameter(Mandatory)][ValidateSet('planner', 'refactor-planner', 'executor')][string]$Role)
    $path = Join-Path $PSScriptRoot "..\..\..\shared\agentic-loop\prompts\$Role.md"
    if (-not (Test-Path $path)) {
        Write-AgenticLog "Default agentic prompt missing: $path" 'FATAL'
        throw "Default agentic prompt missing: $path"
    }
    (Get-Content $path -Raw).Trim()
}

# -- BACKLOG helpers ------------------------------------------------------
function Get-UncheckedTaskCount {
    param([string]$BacklogPath = (Join-Path (Get-Location).Path 'BACKLOG.md'))
    if (-not (Test-Path $BacklogPath)) { return 0 }
    $content = Get-Content $BacklogPath -Raw
    return [regex]::Matches($content, '(?m)^- \[ \]').Count
}

function Get-BlockedTaskCount {
    <#
    .SYNOPSIS
      Count blocked (- [b]) tasks. Blocked tasks are deliberately excluded
      from Get-UncheckedTaskCount so a backlog containing only blocked
      entries reads as an empty queue and lets the planner run again.
    #>
    param([string]$BacklogPath = (Join-Path (Get-Location).Path 'BACKLOG.md'))
    if (-not (Test-Path $BacklogPath)) { return 0 }
    $content = Get-Content $BacklogPath -Raw
    return [regex]::Matches($content, '(?m)^- \[[bB]\]').Count
}

function Remove-CheckedBacklogTasks {
    <#
    .SYNOPSIS
      Remove completed (- [x]) task blocks from the backlog: the checked
      title line plus its indented / blank body lines, up to the next
      non-indented line (next task, heading, or plain text). Completed work
      stays visible in git history instead of accumulating in the file.
      Returns the number of removed task blocks.
    #>
    param([string]$BacklogPath = (Join-Path (Get-Location).Path 'BACKLOG.md'))
    if (-not (Test-Path $BacklogPath)) { return 0 }
    $lines = @(Get-Content $BacklogPath)
    $checked = @($lines | Where-Object { $_ -match '^- \[[xX]\]' }).Count
    if ($checked -eq 0) { return 0 }
    if ($script:AgenticDryRun) {
        Write-AgenticLog "[DRY RUN] would remove $checked completed task(s) from $(Split-Path -Leaf $BacklogPath)"
        return 0
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $skip = $false
    foreach ($line in $lines) {
        if ($line -match '^- \[[xX]\]') { $skip = $true; continue }
        if ($skip) {
            if ($line -match '^\s' -or $line -match '^\s*$') { continue }
            $skip = $false
        }
        $out.Add($line)
    }
    Set-Content -Path $BacklogPath -Value $out
    Write-AgenticLog "Removed $checked completed task(s) from $(Split-Path -Leaf $BacklogPath)"
    return $checked
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
# One logged-execution core for the three wrappers (was three copies of the
# same body around Invoke-Expression). The config-supplied command string runs
# in a CHILD pwsh instead of in-process eval: same expressiveness for the
# config author, cleaner exit-code semantics, no in-session state mutation.
function Invoke-LoggedAgenticCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Label
    )
    $logFile = Get-AgenticLogFile
    Write-Host "--- $Label output ---"
    & pwsh -NoProfile -Command $Command 2>&1 | ForEach-Object {
        Write-Host $_
        if ($logFile) { Add-Content $logFile -Value $_ }
    }
    Write-Host "--- $Label end ---"
    if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -eq '') { return 0 }
    return $LASTEXITCODE
}

function Invoke-BuildCommand {
    param([string]$Command, [string]$Configuration = 'default')
    Write-AgenticSection "BUILD: $Configuration"
    Write-AgenticLog "Command: $Command"
    if ($script:AgenticDryRun) { return $true }
    $ec = Invoke-LoggedAgenticCommand -Command $Command -Label 'build'
    if ($ec -ne 0) { Write-AgenticLog "BUILD FAILED (exit $ec)" 'ERROR'; return $false }
    Write-AgenticLog 'BUILD PASSED'; return $true
}

function Invoke-TestCommand {
    param([string]$Command, [string]$RepoRoot)
    Write-AgenticSection 'TESTS'
    Write-AgenticLog "Command: $Command"
    if ($script:AgenticDryRun) { return $true }
    Push-Location $RepoRoot
    try {
        $ec = Invoke-LoggedAgenticCommand -Command $Command -Label 'test'
        if ($ec -ne 0) { Write-AgenticLog "TESTS FAILED (exit $ec)" 'ERROR'; return $false }
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
        [void](Invoke-LoggedAgenticCommand -Command $Command -Label 'quality')
    } finally { Pop-Location }
}

# -- Build-failure fixer --------------------------------------------------
function Invoke-BuildFixer {
    <#
    .SYNOPSIS
      Hand the tail of the loop log (which contains the build output) to the
      executor-tier model with a focused "fix the build" prompt.
    #>
    param([string]$ConfigurationName, [hashtable]$EngineConfig, [int]$LogTailLines = 150)
    Write-AgenticSection "BUILD FIXER: $ConfigurationName"
    $logTail = ''
    $logFile = Get-AgenticLogFile
    if ($logFile -and (Test-Path $logFile)) {
        $logTail = (Get-Content $logFile -Tail $LogTailLines) -join "`n"
    }
    $message = @"
The build for preset '$ConfigurationName' just failed in the agentic loop. Diagnose the failure from the build log below, fix the root cause in the code or build system, and rebuild with the same preset to verify the fix. Do not delete tests or disable warnings to force a green build. Commit the fix once the build passes.

--- build log (last $LogTailLines lines) ---
$logTail
--- end build log ---
"@
    return Invoke-AgenticAgent -Role 'fixer' -Message $message -EngineConfig $EngineConfig
}

# -- Build matrix helpers -------------------------------------------------
function Resolve-BuildMatrixEntry {
    <#
    .SYNOPSIS
      Normalize a build config entry (string or object) to a hashtable with
      Name, Sanitizer, TestCommand, BuildDir, BuildType.
    #>
    param($Entry)
    if ($Entry -is [string]) {
        return @{ Name = $Entry; Sanitizer = 'none'; TestCommand = $null; BuildDir = $null; BuildType = $null }
    }
    return @{
        Name        = $Entry.name
        Sanitizer   = if ($Entry.sanitizer)   { $Entry.sanitizer }   else { 'none' }
        TestCommand = if ($Entry.testCommand) { $Entry.testCommand } else { $null }
        BuildDir    = if ($Entry.buildDir)    { $Entry.buildDir }    else { $null }
        BuildType   = if ($Entry.buildType)   { $Entry.buildType }   else { $null }
    }
}

function Get-SanitizerEnvVars {
    <#
    .SYNOPSIS
      Return a hashtable of environment variables for the given sanitizer type.
      Used to configure ASAN_OPTIONS / TSAN_OPTIONS before running tests.
    #>
    param([string]$Sanitizer)
    switch ($Sanitizer) {
        'asan' { return @{ ASAN_OPTIONS = 'detect_leaks=1:halt_on_error=1:abort_on_error=1:allocator_may_return_null=1' } }
        'tsan' { return @{ TSAN_OPTIONS = 'halt_on_error=1:abort_on_error=1:second_deadlock_stack=1' } }
        default { return @{} }
    }
}

function Invoke-SanitizerTestCommand {
    <#
    .SYNOPSIS
      Set sanitizer env vars, run the test command, then restore the original
      environment. If the sanitizer is 'none', behaves like Invoke-TestCommand.
    #>
    param([string]$Command, [string]$Sanitizer, [string]$RepoRoot)
    if ($Sanitizer -eq 'none' -or -not $Sanitizer) {
        return Invoke-TestCommand -Command $Command -RepoRoot $RepoRoot
    }
    $envVars = Get-SanitizerEnvVars -Sanitizer $Sanitizer
    $savedVars = @{}
    foreach ($key in $envVars.Keys) {
        $savedVars[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $envVars[$key])
    }
    Write-AgenticLog "Sanitizer: $Sanitizer — env vars set ($($envVars.Keys -join ', '))"
    try {
        return Invoke-TestCommand -Command $Command -RepoRoot $RepoRoot
    } finally {
        foreach ($key in $savedVars.Keys) {
            [Environment]::SetEnvironmentVariable($key, $savedVars[$key])
        }
    }
}

# -- Main loop ------------------------------------------------------------
function Invoke-AgenticLoop {
    param(
        $Config, [string]$PlannerPrompt, [string]$ExecutorPrompt,
        $BuildConfigs = $null, [bool]$OnWindows = (Test-IsWindows), [string]$RepoRoot = (Get-Location).Path,
        [int]$MaxIterations = -1, [switch]$SkipBuild, [switch]$SkipTests, [switch]$SkipQuality,
        [switch]$PlannerOnly, [switch]$ExecutorOnly,
        [string]$RefactorPlannerPrompt = '', [string]$Engine = ''
    )
    $engineConfig = Resolve-AgenticEngine -Config $Config -RepoRoot $RepoRoot -EngineOverride $Engine
    if (-not $BuildConfigs) { $BuildConfigs = Get-AgenticBuildConfigs -Config $Config -OnWindows $OnWindows }
    if (-not $BuildConfigs) {
        Write-AgenticLog 'No build configs (need buildMatrix or buildConfigurations in config)' 'FATAL'
        throw 'No build configs (need buildMatrix or buildConfigurations in config)'
    }

    # Catch an unfinished copy of the config template. Without this the loop
    # starts happily and only fails later, deep in a build step, with an error
    # about a preset named "TODO-debug" - which reads like a broken toolchain
    # rather than "you did not fill in the template". Found by adopting the
    # templates into a scratch project and running them as a new user would.
    # '@(...)' around the whole pipeline is required, not cosmetic: a pipeline
    # yielding nothing returns $null, and $null.Count throws under StrictMode.
    $unfilled = @(@($BuildConfigs | ForEach-Object {
        $entryName = if ($_ -is [string]) { $_ } else { Get-AgenticConfigValue $_ 'name' '' }
        if ("$entryName" -match 'TODO') { "buildMatrix entry '$entryName'" }
    }) + @(
        foreach ($key in 'windowsTestCommand', 'linuxTestCommand', 'windowsQualityCommand', 'linuxQualityCommand') {
            $value = Get-AgenticConfigValue (Get-AgenticConfigValue $Config 'build' $null) $key ''
            if ("$value" -match 'TODO') { "build.$key" }
        }
    ) | Where-Object { $_ })
    if ($unfilled.Count -gt 0) {
        $message = "Config still contains template placeholders: $($unfilled -join ', '). " +
                   'Fill in the TODO values from shared/agentic-loop/templates/AgenticLoop.config.template.json.'
        Write-AgenticLog $message 'FATAL'
        throw $message
    }
    if (-not $PlannerPrompt) {
        $PlannerPrompt = Get-AgenticDefaultPrompt -Role 'planner'
        if (-not $RefactorPlannerPrompt) { $RefactorPlannerPrompt = Get-AgenticDefaultPrompt -Role 'refactor-planner' }
    }
    if (-not $ExecutorPrompt) { $ExecutorPrompt = Get-AgenticDefaultPrompt -Role 'executor' }
    if (-not $RefactorPlannerPrompt) { $RefactorPlannerPrompt = $PlannerPrompt }

    $intervals = Get-AgenticConfigValue $Config 'intervals' $null
    $buildEveryN = [int](Get-AgenticConfigValue $intervals 'buildEveryNTasks' 3)
    $qualityEveryN = [int](Get-AgenticConfigValue $intervals 'qualityEveryNTasks' 5)
    $refactorEveryN = [int](Get-AgenticConfigValue $intervals 'refactorEveryNIterations' 3)
    $cfgMaxIter = [int](Get-AgenticConfigValue $intervals 'maxIterations' 0)
    $maxIter = if ($MaxIterations -ge 0) { $MaxIterations } else { $cfgMaxIter }
    # Dry-run safety cap: when nothing was explicitly set, run at most 1 iteration
    if ($script:AgenticDryRun -and $MaxIterations -lt 0 -and $cfgMaxIter -eq 0) {
        $maxIter = 1
        Write-AgenticLog 'Dry-run: maxIterations capped to 1 (config had 0 = unlimited)' 'WARN'
    }
    $maxRetries = [int](Get-AgenticConfigValue $intervals 'maxExecutorRetries' 3)
    $loopDelay = [int](Get-AgenticConfigValue $intervals 'loopDelaySeconds' 0)
    $fixBuildFailures = [bool](Get-AgenticConfigValue $intervals 'fixBuildFailures' $true)
    $maxConsecutiveBuildFailures = [int](Get-AgenticConfigValue $intervals 'maxConsecutiveBuildFailures' 3)
    $gitCfg = Get-AgenticConfigValue $Config 'git' $null
    $autoCommit = [bool](Get-AgenticConfigValue $gitCfg 'autoCommit' $true)
    $commitPrefix = Get-AgenticConfigValue $gitCfg 'commitPrefix' 'agentic-loop'
    $backlogCfg = Get-AgenticConfigValue $Config 'backlog' $null
    $skipPlannerWhenPending = [bool](Get-AgenticConfigValue $backlogCfg 'skipPlannerWhenTasksPending' $true)
    $deleteCompleted = [bool](Get-AgenticConfigValue $backlogCfg 'deleteCompletedTasks' $true)

    $buildCfg = Get-AgenticConfigValue $Config 'build' $null
    $testCmd = if ($OnWindows) { Get-AgenticConfigValue $buildCfg 'windowsTestCommand' $null } else { Get-AgenticConfigValue $buildCfg 'linuxTestCommand' $null }
    $qualityCmd = if ($OnWindows) { Get-AgenticConfigValue $buildCfg 'windowsQualityCommand' $null } else { Get-AgenticConfigValue $buildCfg 'linuxQualityCommand' $null }
    $windowsBuildScript = Get-AgenticConfigValue $buildCfg 'windowsScript' 'Scripts/Windows/Build-Windows-Container.ps1'
    $linuxBuildScript = Get-AgenticConfigValue $buildCfg 'linuxScript' 'Scripts/Linux/cmake-configure-build.sh'

    # Full matrix sweep: every N iterations, run ALL configs instead of one.
    # 0 = disabled (cycle one config per build trigger).
    $fullMatrixEveryN = [int](Get-AgenticConfigValue $intervals 'fullMatrixEveryNIterations' 0)

    # Normalize build configs to matrix entries (supports both string[] and object[])
    $matrix = @()
    foreach ($entry in $BuildConfigs) { $matrix += Resolve-BuildMatrixEntry -Entry $entry }
    if ($matrix.Count -eq 0) { Write-AgenticLog 'No build configs in matrix' 'FATAL'; return }
    Write-AgenticLog "Engine: $($engineConfig.Engine)"
    Write-AgenticLog "Planner model: $($engineConfig.PlannerModel)"
    Write-AgenticLog "Executor model: $($engineConfig.ExecutorModel)"
    Write-AgenticLog "Build matrix: $($matrix.Count) entries — $($matrix.Name -join ', ')"
    if ($fullMatrixEveryN -gt 0) { Write-AgenticLog "Full matrix sweep every $fullMatrixEveryN iterations" }
    Write-AgenticLog "Build-failure fixing: $fixBuildFailures (stop after $maxConsecutiveBuildFailures consecutive failures)"

    $iteration = 0; $tasksDone = 0
    # Mirrored into script scope so Complete-AgenticLoop reports real totals
    $script:AgenticIterations = 0
    $script:AgenticTasksCompleted = 0
    $script:buildIdx = 0
    $script:consecutiveBuildFailures = 0

    # Helper: build + test for a single matrix entry. On build failure,
    # optionally dispatches the fixer agent and retries the build once.
    function Invoke-BuildAndTestForEntry {
        param($Entry)
        $cfg = $Entry.Name
        $buildCmd = if ($OnWindows) {
            "pwsh -ExecutionPolicy Bypass -File `"$(Join-Path $RepoRoot $windowsBuildScript)`" -Configurations `"$cfg`" -SkipTests"
        } else {
            $buildDir = if ($Entry.BuildDir) { $Entry.BuildDir } else { 'build' }
            "bash `"$(Join-Path $RepoRoot $linuxBuildScript)`" --preset `"$cfg`" --build-dir `"$buildDir`""
        }
        $ok = Invoke-BuildCommand -Command $buildCmd -Configuration $cfg
        if (-not $ok -and $fixBuildFailures -and -not $script:AgenticDryRun) {
            $null = Invoke-BuildFixer -ConfigurationName $cfg -EngineConfig $engineConfig
            $ok = Invoke-BuildCommand -Command $buildCmd -Configuration "$cfg (after fixer)"
        }
        if ($ok) {
            $script:consecutiveBuildFailures = 0
            if (-not $SkipTests) {
                $entryTestCmd = if ($Entry.TestCommand) { $Entry.TestCommand } else { $testCmd }
                if ($entryTestCmd) {
                    Invoke-SanitizerTestCommand -Command $entryTestCmd -Sanitizer $Entry.Sanitizer -RepoRoot $RepoRoot
                }
            }
        } else {
            $script:consecutiveBuildFailures++
            Write-AgenticLog "Consecutive build failures: $script:consecutiveBuildFailures/$maxConsecutiveBuildFailures" 'WARN'
        }
        return $ok
    }

    # Helper: run the build phase (single config or full matrix sweep)
    function Invoke-BuildPhase {
        if ($fullMatrixEveryN -gt 0 -and ($iteration % $fullMatrixEveryN -eq 0) -and $iteration -gt 0) {
            Write-AgenticSection "FULL MATRIX SWEEP (iteration $iteration)"
            foreach ($entry in $matrix) { $null = Invoke-BuildAndTestForEntry -Entry $entry }
        } else {
            $entry = $matrix[$script:buildIdx % $matrix.Count]
            $null = Invoke-BuildAndTestForEntry -Entry $entry
            $script:buildIdx++
        }
    }

    function Invoke-PlannerPhase { param([switch]$Refactor)
        Write-AgenticSection 'PLANNER PHASE'
        $msg = if ($Refactor) { $RefactorPlannerPrompt } else { $PlannerPrompt }
        $null = Invoke-AgenticAgent -Role 'planner' -Message $msg -EngineConfig $engineConfig
        Write-AgenticLog 'Planner complete'
    }
    function Invoke-ExecutorPhase {
        Write-AgenticSection 'EXECUTOR PHASE'
        $null = Invoke-AgenticAgent -Role 'executor' -Message $ExecutorPrompt -EngineConfig $engineConfig
        Write-AgenticLog 'Executor complete'
    }
    # Helper: after-task phases (commit, build, quality). Returns $false when
    # the consecutive-build-failure cap is hit.
    function Invoke-AfterTaskPhases {
        Invoke-GitAutoCommit -Message "${commitPrefix}: task #${tasksDone}" -RepoRoot $RepoRoot -Enabled $autoCommit
        if (-not $SkipBuild -and ($tasksDone % $buildEveryN -eq 0)) { Invoke-BuildPhase }
        if (-not $SkipQuality -and ($qualityEveryN -gt 0) -and ($tasksDone % $qualityEveryN -eq 0) -and $qualityCmd) { Invoke-QualityCommand -Command $qualityCmd -RepoRoot $RepoRoot }
        return ($script:consecutiveBuildFailures -lt $maxConsecutiveBuildFailures)
    }

    if ($PlannerOnly) { Invoke-PlannerPhase -Refactor:$((($iteration+1) % $refactorEveryN -eq 0)); return }
    if ($ExecutorOnly) {
        $backlogPath = Join-Path $RepoRoot 'BACKLOG.md'
        if ($deleteCompleted) { $null = Remove-CheckedBacklogTasks -BacklogPath $backlogPath }
        $u = Get-UncheckedTaskCount -BacklogPath $backlogPath
        $retries = 0
        while ($u -gt 0) {
            Invoke-ExecutorPhase
            $nu = Get-UncheckedTaskCount -BacklogPath $backlogPath
            if ($nu -ge $u) {
                $retries++
                if ($retries -ge $maxRetries -or $script:AgenticDryRun) { break }
            } else {
                $retries = 0; $tasksDone++; $u = $nu
                $script:AgenticTasksCompleted = $tasksDone
                if ($deleteCompleted) { $null = Remove-CheckedBacklogTasks -BacklogPath $backlogPath }
                if (-not (Invoke-AfterTaskPhases)) { Write-AgenticLog 'Too many consecutive build failures — stopping' 'ERROR'; break }
            }
        }
        return
    }

    $forcePlanner = $false
    while ($true) {
        $iteration++
        if ($maxIter -gt 0 -and $iteration -gt $maxIter) { break }
        $script:AgenticIterations = $iteration
        Write-AgenticSection "ITERATION $iteration"

        # Phase 1: Planner — skipped while the queue still has actionable
        # (- [ ]) tasks. Blocked (- [b]) tasks do not count, and the
        # starvation guard forces a planner run after a zero-progress
        # iteration, so a backlog of blocked entries cannot stall the loop.
        $backlogPath = Join-Path $RepoRoot 'BACKLOG.md'
        $pending = Get-UncheckedTaskCount -BacklogPath $backlogPath
        $blocked = Get-BlockedTaskCount -BacklogPath $backlogPath
        $plannerRan = $false
        if ($skipPlannerWhenPending -and $pending -gt 0 -and -not $forcePlanner) {
            Write-AgenticLog "Skipping planner: $pending actionable task(s) pending in BACKLOG.md ($blocked blocked)"
        } else {
            if ($forcePlanner) {
                Write-AgenticLog "Starvation guard: no progress last iteration — running planner despite $pending pending task(s) ($blocked blocked)" 'WARN'
            }
            Invoke-PlannerPhase -Refactor:$($iteration % $refactorEveryN -eq 0)
            $plannerRan = $true
        }

        if ($deleteCompleted) { $null = Remove-CheckedBacklogTasks -BacklogPath $backlogPath }
        $u = Get-UncheckedTaskCount -BacklogPath $backlogPath
        $retries = 0
        $stop = $false
        $iterTasks = 0
        while ($u -gt 0) {
            Invoke-ExecutorPhase
            $nu = Get-UncheckedTaskCount -BacklogPath $backlogPath
            if ($nu -ge $u) {
                $retries++
                if ($retries -ge $maxRetries -or $script:AgenticDryRun) { break }
            } else {
                $retries = 0; $tasksDone++; $iterTasks++; $u = $nu
                $script:AgenticTasksCompleted = $tasksDone
                # Prune any leftover checked entries before the auto-commit
                if ($deleteCompleted) { $null = Remove-CheckedBacklogTasks -BacklogPath $backlogPath }
                if (-not (Invoke-AfterTaskPhases)) {
                    Write-AgenticLog 'Too many consecutive build failures — stopping loop' 'ERROR'
                    $script:AgenticExitCode = 1
                    $stop = $true
                    break
                }
            }
        }
        if ($stop) { break }
        if ($iterTasks -eq 0) {
            if ($plannerRan) {
                Write-AgenticLog 'No executor progress even after running the planner — stopping loop (no actionable tasks left)' 'WARN'
                break
            }
            Write-AgenticLog 'No executor progress this iteration — planner will run next iteration' 'WARN'
            $forcePlanner = $true
        } else {
            $forcePlanner = $false
        }
        if ($loopDelay -gt 0 -and -not $script:AgenticDryRun) { Write-AgenticLog "Sleeping ${loopDelay}s..."; Start-Sleep $loopDelay }
    }
}
