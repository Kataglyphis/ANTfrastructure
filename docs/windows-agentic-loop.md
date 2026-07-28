# Agentic Loop Module (`WindowsAgenticLoop.Common.psm1`)

A reusable PowerShell module for the OpenCode-based planner/executor agentic
loop pattern. Lets any project set up an autonomous coding loop with:

1. A **planner** (expensive model, e.g. GLM 5.2) that analyzes the codebase
   and writes tasks to `BACKLOG.md`.
2. An **executor** (cheap model, e.g. DeepSeek v4 Flash) that drains the queue
   one task at a time, building and testing as it goes.
3. Builds, tests, and quality gates on configurable intervals, cycling through
   different build configurations.

## Prerequisites

- [OpenCode](https://opencode.ai) CLI installed and authenticated
- PowerShell 5.1+ (Windows) or PowerShell 7+ (Linux/macOS)
- A `BACKLOG.md` file in the repository root (task format: `- [ ] Title`)
- `jq` on Linux (for config parsing in the Bash equivalent)

## Installation

Place the module in your repository's module path, then import it:

```pwsh
# If using Kataglyphis-ContainerHub as a submodule:
$modulePath = Resolve-Path 'ExternalLib/Kataglyphis-ContainerHub/windows/scripts/modules/WindowsAgenticLoop.Common.psm1'
Import-Module $modulePath -Force
```

Or vendor it directly into `Scripts/Windows/modules/` and import by name.

## Quick Start

Create a `Run-AgenticLoop.ps1` script in your project:

```pwsh
# Scripts/AgenticLoop/Run-AgenticLoop.ps1
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$configPath = Join-Path $PSScriptRoot 'AgenticLoop.config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

Import-Module (Join-Path $repoRoot 'ExternalLib/Kataglyphis-ContainerHub/windows/scripts/modules/WindowsAgenticLoop.Common.psm1') -Force

Initialize-AgenticLoop -ConfigPath $configPath -RepoRoot $repoRoot

# Project-specific build/test/quality commands
$onWindows = Test-IsWindows
$buildConfigs = if ($onWindows) { $config.buildConfigurations.windows } else { $config.buildConfigurations.linux }

$buildFunc = {
    param($configName)
    if (Test-IsWindows) {
        "pwsh -ExecutionPolicy Bypass -File `"$repoRoot\Scripts\Windows\Build-Windows-Container.ps1`" -Configurations `"$configName`" -SkipTests"
    } else {
        "bash `"$repoRoot/Scripts/Linux/cmake-configure-build.sh`" --preset `"$configName`" --build-dir build"
    }
}

Invoke-AgenticLoop `
    -Config @{
        plannerModel = $config.models.planner
        executorModel = $config.models.executor
        buildEveryNTasks = $config.intervals.buildEveryNTasks
        qualityEveryNTasks = $config.intervals.qualityEveryNTasks
        refactorEveryNIterations = $config.intervals.refactorEveryNIterations
        maxIterations = $config.intervals.maxIterations
        maxExecutorRetries = $config.intervals.maxExecutorRetries
        loopDelaySeconds = $config.intervals.loopDelaySeconds
        buildConfigurations = $buildConfigs
        autoCommit = $config.git.autoCommit
        commitPrefix = $config.git.commitPrefix
    } `
    -PlannerPrompt "Analyze the codebase and add tasks to BACKLOG.md..." `
    -ExecutorPrompt "Read BACKLOG.md, execute the next unchecked task..." `
    -BuildCommandFunc $buildFunc `
    -TestCommand (if ($onWindows) { $config.build.windowsTestCommand } else { $config.build.linuxTestCommand }) `
    -RepoRoot $repoRoot

Complete-AgenticLoop -Iteration $iteration -TasksCompleted $tasksCompleted
```

## Module API

### Initialization & Lifecycle

| Function | Purpose |
|----------|---------|
| `Initialize-AgenticLoop -ConfigPath <path> [-DryRun]` | Set up logging, platform detection, global trap. Returns context hashtable. |
| `Complete-AgenticLoop [-Iteration <int>] [-TasksCompleted <int>] [-ExitCode <int>]` | Write final summary and exit with the accumulated exit code. |

### Logging

| Function | Purpose |
|----------|---------|
| `Write-AgenticLog -Message <string> [-Level <string>]` | Timestamped log to file + console. |
| `Write-AgenticSection -Title <string>` | Decorated section header. |
| `Get-AgenticLogFile` | Returns the current log file path. |

### Platform Detection

| Function | Purpose |
|----------|---------|
| `Get-AgenticPlatform` | Returns `'windows'` or `'linux'`. Safe in PS 5.1 (no `$PSVersionTable.Platform`). |
| `Test-IsWindows` | `$true` on Windows, `$false` otherwise. |

### OpenCode Invocation

| Function | Purpose |
|----------|---------|
| `Invoke-OpenCode -Agent <string> -Model <string> -Message <string>` | Passes message via stdin to `opencode run`. Avoids `2>&1` (crash in PS 5.1). Captures stdout. |

### Utility

| Function | Purpose |
|----------|---------|
| `Get-UncheckedTaskCount [-BacklogPath <path>]` | Count `- [ ]` lines in BACKLOG.md. |
| `Invoke-GitAutoCommit -Message <string> [-RepoRoot <path>] [-Enabled <bool>]` | `git add -A && git commit` with a message. |

### Build / Test / Quality Wrappers

| Function | Purpose |
|----------|---------|
| `Invoke-BuildCommand -Command <string> [-Configuration <string>]` | Execute a build command, log output, return `$true`/`$false`. |
| `Invoke-TestCommand -Command <string> [-RepoRoot <path>]` | Execute a test command, log output, return `$true`/`$false`. |
| `Invoke-QualityCommand -Command <string> [-RepoRoot <path>]` | Execute a quality gate, log output. |

### High-Level Loop

| Function | Purpose |
|----------|---------|
| `Invoke-AgenticLoop -Config <hashtable> -PlannerPrompt <string> -ExecutorPrompt <string> -BuildCommandFunc <scriptblock> [...]` | Full planner/executor loop with build cycling, tests, and quality gates. See detailed docs below. |

## `Invoke-AgenticLoop` Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `Config` | `[hashtable]` | Configuration values (models, intervals, etc.) |
| `PlannerPrompt` | `[string]` | Prompt message for the planner agent |
| `ExecutorPrompt` | `[string]` | Prompt message for the executor agent |
| `BuildCommandFunc` | `[scriptblock]` | `{ param($configName) return "command string" }` |
| `TestCommand` | `[string]` | Shell command to run tests |
| `QualityCommand` | `[string]` | Shell command to run quality gates |
| `RepoRoot` | `[string]` | Repository root directory |
| `BacklogPath` | `[string]` | Path to BACKLOG.md |
| `MaxIterations` | `[int]` | Override max iterations (0 = unlimited) |
| `SkipBuild` | `[switch]` | Skip builds |
| `SkipTests` | `[switch]` | Skip tests |
| `SkipQuality` | `[switch]` | Skip quality gates |
| `PlannerOnly` | `[switch]` | Run planner once and exit |
| `ExecutorOnly` | `[switch]` | Drain the queue and exit |

### Config Hashtable Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `plannerModel` | `[string]` | `opencode-go/glm-5.2` | Model ID for the planner agent |
| `executorModel` | `[string]` | `opencode-go/deepseek-v4-flash` | Model ID for the executor agent |
| `buildEveryNTasks` | `[int]` | 3 | Build after every N completed tasks |
| `qualityEveryNTasks` | `[int]` | 5 | Quality gate every M tasks |
| `refactorEveryNIterations` | `[int]` | 3 | Refactor focus every R iterations |
| `maxIterations` | `[int]` | 0 | Max loop iterations (0 = unlimited) |
| `maxExecutorRetries` | `[int]` | 3 | Retries before skipping a stuck task |
| `loopDelaySeconds` | `[int]` | 10 | Delay between loop iterations |
| `buildConfigurations` | `[string[]]` | `['clangcl-debug']` | Array of build configs to cycle through |
| `autoCommit` | `[bool]` | `$true` | Auto-commit after each completed task |
| `commitPrefix` | `[string]` | `agentic-loop` | Prefix for auto-commit messages |

## Known PS 5.1 Issues

### `2>&1` + `$ErrorActionPreference='Stop'` = Crash

In Windows PowerShell 5.1, merging stderr into stdout with `2>&1` while
`$ErrorActionPreference='Stop'` is active causes a silent crash (empty
exception message). The stderr bytes from external processes are converted
to `ErrorRecord` objects by the redirection; under `'Stop'`, these become
terminating errors.

**The module avoids this entirely** by never using `2>&1`. Instead,
`Invoke-OpenCode` writes the message to a temp file and pipes it through
stdin, capturing stdout only. Stderr output from opencode is not captured
(this is acceptable because opencode sends its responses to stdout).

### `$PSVersionTable.Platform`

PowerShell 5.1 does not have the `Platform` property on `$PSVersionTable`.
The module uses `$env:OS -eq 'Windows_NT'` instead, which works on all
Windows versions.

## Usage Examples

### Basic loop (with config file)

```pwsh
Import-Module WindowsAgenticLoop.Common -Force
Initialize-AgenticLoop -ConfigPath 'AgenticLoop.config.json'
# ... configure and call Invoke-AgenticLoop ...
Complete-AgenticLoop
```

### Dry run to test configuration

```pwsh
Initialize-AgenticLoop -ConfigPath 'AgenticLoop.config.json' -DryRun
Invoke-AgenticLoop -Config $cfg -PlannerPrompt "..." -ExecutorPrompt "..." -BuildCommandFunc $buildFunc
```

### Planner only (add tasks without executing)

```pwsh
Invoke-AgenticLoop -Config $cfg -PlannerPrompt "..." -ExecutorPrompt "..." -PlannerOnly
```

### Executor only (drain existing queue)

```pwsh
Invoke-AgenticLoop -Config $cfg -PlannerPrompt "..." -ExecutorPrompt "..." -ExecutorOnly
```
