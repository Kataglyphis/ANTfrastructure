# Agentic Loop Module (`WindowsAgenticLoop.Common.psm1`)

A reusable PowerShell module for the planner/executor agentic loop pattern.
Lets any project set up an autonomous coding loop with:

1. A **planner** (expensive model, e.g. Claude Fable 5 or GLM 5.2) that
   analyzes the codebase and writes tasks to `BACKLOG.md`.
2. An **executor** (cheaper model, e.g. Claude Sonnet or DeepSeek v4 Flash)
   that drains the queue one task at a time, building and testing as it goes.
3. Builds, tests, and quality gates on configurable intervals, cycling through
   different build configurations.
4. A **build fixer**: when a periodic build fails, the executor-tier model is
   dispatched with the build log tail to fix it, and the loop stops after N
   consecutive unfixable failures.

## Engines

Two agent CLI backends are supported; select via config `engine`,
`$env:AGENTIC_ENGINE`, or the `-Engine` parameter of `Invoke-AgenticLoop`:

| Engine | Invocation | Role prompts | Permissions |
|--------|-----------|--------------|-------------|
| `opencode` | `opencode run --agent <role> --model <model>` | `.opencode/agents/<role>.md` (resolved by opencode) | Configured in `opencode.json` |
| `claude` | `claude -p --model <model>` (Claude Code CLI) | `--append-system-prompt-file` from config `engines.claude.<role>PromptFile` | Planner sandboxed via `--allowed-tools` (e.g. `Read Glob Grep Edit(BACKLOG.md)`); executor uses `permissionMode` (default `bypassPermissions` — intended for trusted repos/sandboxes) |

For `claude`, `engines.claude.plannerFallbackModel` maps to
`--fallback-model` so an overloaded planner model (e.g. `claude-fable-5`)
falls back automatically (e.g. to `claude-opus-4-8`).

Model resolution precedence: `$env:AGENTIC_PLANNER_MODEL` /
`$env:AGENTIC_EXECUTOR_MODEL` > `engines.<engine>.plannerModel/executorModel`
> legacy `models.planner/executor`.

Agent invocations retry with linear backoff (`agentRetries` ×
`agentRetryDelaySeconds`) and honor per-role timeouts
(`plannerTimeoutSeconds` / `executorTimeoutSeconds`, falling back to
`timeoutSeconds`; 0 = no timeout).

## Prerequisites

- [OpenCode](https://opencode.ai) CLI and/or
  [Claude Code](https://claude.com/claude-code) CLI installed and authenticated
- PowerShell 7+ (cross-platform)
- A `BACKLOG.md` file in the repository root (task format: `- [ ] Title` for actionable tasks, `- [b] Title` for blocked/parked ones the executor must skip)
- `jq` on Linux (for config parsing in the Bash equivalent,
  `linux/scripts/lib/agentic-loop.sh`, which mirrors this module's engine
  support)

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

# Select build matrix for this platform (prefers buildMatrix, falls back to buildConfigurations)
$onWindows = Test-IsWindows
$buildConfigs = if ($config.buildMatrix) {
    if ($onWindows) { $config.buildMatrix.windows } else { $config.buildMatrix.linux }
} elseif ($config.buildConfigurations) {
    if ($onWindows) { $config.buildConfigurations.windows } else { $config.buildConfigurations.linux }
} else { $null }

Invoke-AgenticLoop -Config $config -PlannerPrompt "Analyze the codebase and add tasks to BACKLOG.md..." -ExecutorPrompt "Read BACKLOG.md, execute the next unchecked task..." -BuildConfigs $buildConfigs -OnWindows $onWindows -RepoRoot $repoRoot

Complete-AgenticLoop
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
| `Get-AgenticPlatform` | Returns `'windows'` or `'linux'`. Works on all supported PowerShell versions. |
| `Test-IsWindows` | `$true` on Windows, `$false` otherwise. |

### Agent Invocation

| Function | Purpose |
|----------|---------|
| `Resolve-AgenticEngine -Config <object> [-RepoRoot <path>] [-EngineOverride <string>]` | Resolve engine + models + prompt files + timeouts into a flat hashtable. |
| `Invoke-AgenticAgent -Role <planner\|executor\|fixer> -Message <string> -EngineConfig <hashtable>` | Engine dispatcher with retry + linear backoff. Returns `$true` on success. |
| `Invoke-OpenCode -Agent <string> -Model <string> -Message <string>` | Passes message via stdin to `opencode run`. |
| `Invoke-ClaudeCode -Role <string> -Model <string> -Message <string> -EngineConfig <hashtable>` | Headless `claude -p` run with role system prompt, tool sandbox, and fallback model. |
| `Invoke-AgentProcess -Executable <string> -ArgumentList <string[]> -Message <string> [-TimeoutSeconds <int>]` | Low-level process runner (stdin prompt, streamed stdout/stderr, timeout). |
| `Invoke-BuildFixer -ConfigurationName <string> -EngineConfig <hashtable>` | Dispatch the fixer role with the tail of the loop log after a build failure. |
| `Get-AgenticConfigValue -Object <object> -Name <string> [-Default <object>]` | StrictMode-safe config lookup (hashtable or PSCustomObject). |
| `Get-AgentTimeoutForRole -EngineConfig <hashtable> -Role <string>` | Per-role timeout resolution. |

### Utility

| Function | Purpose |
|----------|---------|
| `Get-UncheckedTaskCount [-BacklogPath <path>]` | Count actionable `- [ ]` lines in BACKLOG.md (blocked `- [b]` entries excluded). |
| `Get-BlockedTaskCount [-BacklogPath <path>]` | Count blocked `- [b]` lines in BACKLOG.md. |
| `Invoke-GitAutoCommit -Message <string> [-RepoRoot <path>] [-Enabled <bool>]` | `git add -A && git commit` with a message. |

### Build / Test / Quality Wrappers

| Function | Purpose |
|----------|---------|
| `Invoke-BuildCommand -Command <string> [-Configuration <string>]` | Execute a build command, log output, return `$true`/`$false`. |
| `Invoke-TestCommand -Command <string> [-RepoRoot <path>]` | Execute a test command, log output, return `$true`/`$false`. |
| `Invoke-QualityCommand -Command <string> [-RepoRoot <path>]` | Execute a quality gate, log output. |

### Build Matrix & Sanitizer-Aware Testing

| Function | Purpose |
|----------|---------|
| `Resolve-BuildMatrixEntry -Entry <object>` | Normalize a string or JSON object to a hashtable with `Name`, `Sanitizer`, `TestCommand`, `BuildDir`, `BuildType`. |
| `Get-SanitizerEnvVars -Sanitizer <string>` | Return a hashtable of env vars for the given sanitizer (`asan`, `tsan`, or `none`). |
| `Invoke-SanitizerTestCommand -Command <string> -Sanitizer <string> -RepoRoot <string>` | Set sanitizer env vars, run tests, restore env. |

See [`agentic-loop-build-matrix.md`](agentic-loop-build-matrix.md) for the
full build matrix documentation.

### High-Level Loop

| Function | Purpose |
|----------|---------|
| `Invoke-AgenticLoop -Config <object> -PlannerPrompt <string> -ExecutorPrompt <string> -BuildConfigs <array> -OnWindows <bool> [...]` | Full planner/executor loop with build matrix cycling, sanitizer-aware tests, full matrix sweeps, and quality gates. |

## `Invoke-AgenticLoop` Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `Config` | `[object]` | Configuration object (from JSON: models, intervals, build, git, logging) |
| `PlannerPrompt` | `[string]` | Prompt message for the planner agent |
| `ExecutorPrompt` | `[string]` | Prompt message for the executor agent |
| `BuildConfigs` | `[array]` | Build matrix entries (string[] or object[] with name, sanitizer, testCommand, buildDir, buildType) |
| `OnWindows` | `[bool]` | `$true` on Windows, `$false` on Linux — selects build script and test command |
| `RepoRoot` | `[string]` | Repository root directory |
| `MaxIterations` | `[int]` | Override max iterations (-1 = use config, 0 = unlimited) |
| `SkipBuild` | `[switch]` | Skip builds |
| `SkipTests` | `[switch]` | Skip tests |
| `SkipQuality` | `[switch]` | Skip quality gates |
| `PlannerOnly` | `[switch]` | Run planner once and exit |
| `ExecutorOnly` | `[switch]` | Drain the queue and exit |

### Config JSON Keys

The config is read from `AgenticLoop.config.json`. Key sections:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `engine` | `[string]` | `opencode` | Agent CLI backend: `opencode` or `claude` |
| `engines.<engine>.plannerModel` | `[string]` | — | Model ID for the planner (per engine) |
| `engines.<engine>.executorModel` | `[string]` | — | Model ID for the executor (per engine) |
| `engines.claude.plannerFallbackModel` | `[string]` | — | `--fallback-model` for the planner (used when the primary is overloaded) |
| `engines.claude.plannerPromptFile` | `[string]` | — | Repo-relative role prompt appended via `--append-system-prompt-file` |
| `engines.claude.executorPromptFile` | `[string]` | — | Repo-relative role prompt for executor/fixer |
| `engines.claude.plannerAllowedTools` | `[string]` | — | Space-separated `--allowed-tools` list sandboxing the planner |
| `engines.claude.permissionMode` | `[string]` | `bypassPermissions` | Executor permission mode (`bypassPermissions` maps to `--dangerously-skip-permissions`) |
| `engines.claude.extraArgs` | `[string]` | — | Extra CLI args appended to every claude invocation |
| `engines.claude.streamOutput` | `[bool]` | `true` | Stream live progress (tool calls, per-turn text, final cost) via `stream-json`; `false` = silent until completion |
| `models.planner` | `[string]` | `opencode-go/glm-5.2` | Legacy fallback model ID for the planner agent |
| `models.executor` | `[string]` | `opencode-go/deepseek-v4-flash` | Legacy fallback model ID for the executor agent |
| `intervals.buildEveryNTasks` | `[int]` | 3 | Build after every N completed tasks |
| `intervals.qualityEveryNTasks` | `[int]` | 5 | Quality gate every M tasks |
| `intervals.refactorEveryNIterations` | `[int]` | 3 | Refactor focus every R iterations |
| `intervals.fullMatrixEveryNIterations` | `[int]` | 0 | Full matrix sweep every N iterations (0 = disabled) |
| `intervals.maxIterations` | `[int]` | 0 | Max loop iterations (0 = unlimited) |
| `intervals.maxExecutorRetries` | `[int]` | 3 | Retries before skipping a stuck task |
| `intervals.loopDelaySeconds` | `[int]` | 10 | Delay between loop iterations |
| `intervals.timeoutSeconds` | `[int]` | 0 | Generic agent invocation timeout (0 = none) |
| `intervals.plannerTimeoutSeconds` | `[int]` | 0 | Planner timeout override |
| `intervals.executorTimeoutSeconds` | `[int]` | 0 | Executor/fixer timeout override |
| `intervals.agentRetries` | `[int]` | 2 | Retries per agent invocation (linear backoff) |
| `intervals.agentRetryDelaySeconds` | `[int]` | 20 | Base backoff delay between agent retries |
| `intervals.fixBuildFailures` | `[bool]` | `true` | Dispatch the fixer agent after a failed build, then rebuild once |
| `intervals.maxConsecutiveBuildFailures` | `[int]` | 3 | Stop the loop after N consecutive failed build phases |
| `buildMatrix.windows` | `[array]` | — | Windows build matrix entries (objects with name, sanitizer, buildDir, buildType, testCommand) |
| `buildMatrix.linux` | `[array]` | — | Linux build matrix entries |
| `build.windowsTestCommand` | `[string]` | — | Fallback test command for Windows |
| `build.linuxTestCommand` | `[string]` | — | Fallback test command for Linux |
| `build.windowsQualityCommand` | `[string]` | — | Quality command for Windows |
| `build.linuxQualityCommand` | `[string]` | — | Quality command for Linux |
| `git.autoCommit` | `[bool]` | `true` | Auto-commit after each completed task |
| `git.commitPrefix` | `[string]` | `agentic-loop` | Prefix for auto-commit messages |
| `backlog.skipPlannerWhenTasksPending` | `[bool]` | `true` | Skip the planner phase while `BACKLOG.md` still has actionable `- [ ]` tasks. Blocked `- [b]` entries don't count, and a zero-progress iteration forces the planner to run next iteration (starvation guard); if the planner ran and the executor still made no progress, the loop stops |
| `backlog.deleteCompletedTasks` | `[bool]` | `true` | Prune completed (`- [x]`) task blocks from `BACKLOG.md` after each task (history lives in git) |

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
Invoke-AgenticLoop -Config $cfg -PlannerPrompt "..." -ExecutorPrompt "..." -BuildConfigs $buildConfigs -OnWindows $true -RepoRoot $repoRoot
```

### Planner only (add tasks without executing)

```pwsh
Invoke-AgenticLoop -Config $cfg -PlannerPrompt "..." -ExecutorPrompt "..." -BuildConfigs $buildConfigs -OnWindows $true -RepoRoot $repoRoot -PlannerOnly
```

### Executor only (drain existing queue)

```pwsh
Invoke-AgenticLoop -Config $cfg -PlannerPrompt "..." -ExecutorPrompt "..." -BuildConfigs $buildConfigs -OnWindows $true -RepoRoot $repoRoot -ExecutorOnly
```
