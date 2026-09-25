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
| `opencode` | `opencode run --agent <role> --model <model>` | `.opencode/agents/<role>.md`, **generated** by the loop (resolved by opencode) | Configured in `opencode.json` |
| `claude` | `claude -p --model <model>` (Claude Code CLI) | `--append-system-prompt-file` from the composed prompt | Planner sandboxed via `--allowed-tools` (e.g. `Read Glob Grep Edit(BACKLOG.md)`); executor uses `permissionMode` (default `bypassPermissions` — intended for trusted repos/sandboxes) |

### Role prompts: one composition, both engines

Both "Role prompts" cells above hold the *same text* whenever a prompt is
configured. On every start the loop composes

```
shared/agentic-loop/system-prompts/<role>.md   the shared, engine-agnostic role prompt
      +  <your overlay>.md                     your project delta
```

and delivers it twice: to `claude` as a temp file behind
`--append-system-prompt-file`, and to `opencode` by **writing**
`<repo>/.opencode/agents/<role>.md` — opencode takes no prompt file on its
command line, so that file is its only channel.

`.opencode/agents/*.md` is therefore a **build artefact**. Add it to
`.gitignore`; the loop warns when you have not. It used to be hand-maintained
per consumer, which is precisely the failure `New-AgenticComposedPrompt`'s
docstring names — "which is how one consumer ended up with two full copies that
had drifted 271 lines apart". One such copy had silently lost the executor's
incident narrative, its `timeout: 600000` guidance and the `- [b]` commit step.

Point at your overlay with a top-level block — engine-agnostic, because the
prompt is:

```json
"promptOverlays": {
  "plannerPromptOverlayFile":  "scripts/agentic-loop/prompts/planner-overlay.md",
  "executorPromptOverlayFile": "scripts/agentic-loop/prompts/executor-overlay.md"
}
```

The older `engines.<engine>.<role>PromptOverlayFile` still works and is now
found whichever engine you run — it is read out of any engine block, not only
the selected one. Pinning that lookup to `engines.claude` is what left the
opencode side with no composed prompt at all and made the hand copy look
necessary. The legacy full-override `engines.<engine>.<role>PromptFile` also
still works: it replaces the shared prompt entirely and is mirrored into
`.opencode/agents/` verbatim. This module reads it from the selected engine's
block; the Bash twin reads `engines.claude.*` whatever the engine. Migrate it to
an overlay — the override shape is what makes a consumer copy the whole role
prompt in the first place.

With no prompt configuration at all, opencode gets the shared role prompt alone
and `claude` gets no role prompt. There is no configuration under which
opencode is left with nothing.

For `claude`, `engines.claude.plannerFallbackModel` maps to
`--fallback-model` so an overloaded planner model falls back automatically (the
config template: `claude-opus-5`, falling back to `claude-fable-5`).

Model resolution precedence: `$env:AGENTIC_PLANNER_MODEL` /
`$env:AGENTIC_EXECUTOR_MODEL` > `engines.<engine>.plannerModel/executorModel`
> legacy `models.planner/executor`.

Agent invocations retry with linear backoff (up to `agentRetries` retries, the
Nth after N × `agentRetryDelaySeconds`) and honor per-role timeouts
(`plannerTimeoutSeconds` / `executorTimeoutSeconds`, falling back to
`timeoutSeconds`; 0 = no timeout).

## Prerequisites

- [OpenCode](https://opencode.ai) CLI and/or
  [Claude Code](https://claude.com/claude-code) CLI installed and authenticated
  (`opencode auth login`; run `claude` once interactively)
- PowerShell 7+ (cross-platform)
- A `BACKLOG.md` file in the repository root (task format: `- [ ] Title` for actionable tasks, `- [b] Title` for blocked/parked ones the executor must skip)
- `jq` on Linux (for config parsing in the Bash equivalent,
  `linux/scripts/lib/agentic-loop.sh`, whose engine half
  `agentic-engines.sh` mirrors this module's engine support)

## Installation

Place the module in your repository's module path, then import it:

```pwsh
# If using ANTfrastructure as a submodule:
$modulePath = Resolve-Path 'third_party/ANTfrastructure/windows/scripts/modules/WindowsAgenticLoop.Common.psm1'
Import-Module $modulePath -Force
```

Do not vendor a copy into the consumer repo — resolve it ANTfrastructure-first
(the template wrapper tries `third_party/ANTfrastructure` before a vendored
`modules/` fallback); vendored duplicates are exactly the drift the 2026-08-02
dedup pass removed.

## Quick Start

Create a `Invoke-AgenticLoop.ps1` script in your project. The copy-and-edit
version, with flags and a `finally` around the loop, is
`shared/agentic-loop/templates/Invoke-AgenticLoop.ps1`; this is its core:

```pwsh
# scripts/agentic-loop/Invoke-AgenticLoop.ps1
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$configPath = Join-Path $PSScriptRoot 'AgenticLoop.config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

Import-Module (Join-Path $repoRoot 'third_party/ANTfrastructure/windows/scripts/modules/WindowsAgenticLoop.Common.psm1') -Force

Initialize-AgenticLoop -ConfigPath $configPath -RepoRoot $repoRoot

Invoke-AgenticLoop -Config $config -RepoRoot $repoRoot

Complete-AgenticLoop
```

Nothing else is needed: build configs are selected from the config's
platform-appropriate `buildMatrix` (legacy `buildConfigurations` fallback)
and the planner / refactor-planner / executor task prompts default to the
shared prompt files (see [Default Task Prompts](#default-task-prompts)).
Pass `-BuildConfigs` / `-PlannerPrompt` / `-ExecutorPrompt` /
`-RefactorPlannerPrompt` only to override.

## Module API

### Initialization & Lifecycle

| Function | Purpose |
|----------|---------|
| `Initialize-AgenticLoop [-ConfigPath <path>] [-RepoRoot <path>] [-DryRun] [-TimeoutSeconds <int>]` | Reset the run state and open a timestamped log under `<RepoRoot>/<logging.logDir>` (default `logs/agentic-loop`). `-TimeoutSeconds` > 0 overrides every opencode timeout. Returns nothing. |
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
| `Resolve-AgenticEngine -Config <object> [-RepoRoot <path>] [-EngineOverride <string>]` | Resolve engine + models + prompt files + timeouts into a flat hashtable; writes `.opencode/agents/<role>.md` on the way. |
| `Invoke-AgenticAgent -Role <planner\|executor\|fixer> -Message <string> -EngineConfig <hashtable>` | Engine dispatcher with retry + linear backoff. Returns `$true` on success. |
| `Invoke-OpenCode -Agent <string> -Model <string> -Message <string> [-TimeoutSeconds <int>]` | Passes message via stdin to `opencode run`. Returns its stdout, `$null` when opencode is missing. |
| `Invoke-ClaudeCode -Role <string> -Model <string> -Message <string> -EngineConfig <hashtable>` | Headless `claude -p` run with role system prompt, tool sandbox, and fallback model. |
| `Invoke-AgentProcess -Executable <string> -ArgumentList <string[]> -Message <string> [-TimeoutSeconds <int>]` | Low-level process runner (stdin prompt, streamed stdout/stderr, timeout). |
| `Invoke-BuildFixer -ConfigurationName <string> -EngineConfig <hashtable>` | Dispatch the fixer role with the tail of the loop log after a build failure. |
| `Get-AgenticConfigValue -Object <object> -Name <string> [-Default <object>]` | StrictMode-safe config lookup (hashtable or PSCustomObject). |
| `Get-AgenticConfigKey -Object <object>` | The key names of a config node (hashtable or PSCustomObject); empty array for `$null`. |
| `Get-AgenticBuildConfigs -Config <object> [-OnWindows <bool>]` | The platform's `buildMatrix` entries, else legacy `buildConfigurations`, else `$null`. |
| `Get-AgentTimeoutForRole -EngineConfig <hashtable> -Role <string>` | Per-role timeout resolution. |

### Role-Prompt Composition

What [Role prompts: one composition, both engines](#role-prompts-one-composition-both-engines)
describes. `Resolve-AgenticEngine` calls these for both roles on every start.

| Function | Purpose |
|----------|---------|
| `Get-AgenticSystemPromptPath -Role <planner\|executor> [-AllowMissing]` | Path of the shared role prompt under `shared/agentic-loop/system-prompts/`. |
| `Get-AgenticPromptOverlayPath -Config <object> -EngineConfig <object> -Key <string>` | Overlay path: `promptOverlays` first, then the selected engine's block, then any other engine block (with a WARN). |
| `Resolve-AgenticRolePromptFile -Role <planner\|executor> [-PromptFile <path>] [-OverlayPath <path>] [-RepoRoot <path>]` | Picks overlay, full override or neither; returns the file for `claude` (`$null` for neither) and writes the opencode agent file. |
| `New-AgenticComposedPrompt -Role <planner\|executor> -OverlayPath <path> [-RepoRoot <path>]` | Shared role prompt + overlay into one temp file; returns its path. With `-RepoRoot` it also writes the opencode agent file. |
| `Get-AgenticOpenCodeAgentPath -Role <planner\|executor> -RepoRoot <path>` | `<RepoRoot>/.opencode/agents/<role>.md`. |
| `Write-AgenticOpenCodeAgentFile -Role <planner\|executor> -RepoRoot <path> -Body <string> [-SourceLabel <string>]` | Writes that file with its DO-NOT-EDIT header, only when the content changed. |

### Default Task Prompts

The per-phase TASK prompts (the message piped to each agent invocation —
not the role prompts, which are composed from
`shared/agentic-loop/system-prompts/` and the project overlay) are
single-sourced as Markdown files in this repository:

```
shared/agentic-loop/prompts/planner.md
shared/agentic-loop/prompts/refactor-planner.md
shared/agentic-loop/prompts/executor.md
```

| Function | Purpose |
|----------|---------|
| `Get-AgenticDefaultPrompt -Role <planner\|refactor-planner\|executor>` | Read the shared default prompt for a role (throws if the file is missing). |
| `Get-AgenticDefaultPromptPath -Role <planner\|refactor-planner\|executor>` | That file's resolved path (same throw). |

`Invoke-AgenticLoop`'s `-PlannerPrompt`, `-RefactorPlannerPrompt`, and
`-ExecutorPrompt` parameters are optional and default to these files, so
project wrappers do not need to hard-code prompt text. The Bash library's
`default_planner_prompt` / `default_refactor_planner_prompt` /
`default_executor_prompt` (in `linux/scripts/lib/agentic-loop.sh`) read the
same files, keeping both platforms in lockstep — edit the prompt file once
and both loops pick it up.

### Utility

| Function | Purpose |
|----------|---------|
| `Get-UncheckedTaskCount [-BacklogPath <path>]` | Count actionable `- [ ]` lines in BACKLOG.md (blocked `- [b]` entries excluded). |
| `Get-BlockedTaskCount [-BacklogPath <path>]` | Count blocked `- [b]` lines in BACKLOG.md. |
| `Remove-CheckedBacklogTasks [-BacklogPath <path>]` | Delete completed `- [x]` task blocks (title line plus indented body); returns how many. Bash counterpart: `remove_checked_tasks [backlog]`. |
| `Get-UsageLimitWaitSeconds -Output <string>` | Detect a Claude usage/session-limit failure and return seconds to sleep until the stated reset (0 = not a limit failure). |
| `Invoke-GitAutoCommit -Message <string> [-RepoRoot <path>] [-Enabled <bool>]` | `git add -A && git commit` with a message. Bash counterpart: `invoke_git_auto_commit <message> [repo_root] [enabled]`. |

### Build / Test / Quality Wrappers

| Function | Purpose |
|----------|---------|
| `Invoke-BuildCommand -Command <string> [-Configuration <string>]` | Execute a build command, log output, return `$true`/`$false`. |
| `Invoke-TestCommand -Command <string> [-RepoRoot <path>]` | Execute a test command, log output, return `$true`/`$false`. |
| `Invoke-QualityCommand -Command <string> [-RepoRoot <path>]` | Execute a quality gate, log output. Its result never fails the loop. |

All three run the command string in a child `pwsh -NoProfile -Command`, so it
is PowerShell syntax and cannot change the loop's own session.

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
| `Invoke-AgenticLoop -Config <object> [-PlannerPrompt <string>] [-ExecutorPrompt <string>] [-BuildConfigs <array>] [...]` | Full planner/executor loop with build matrix cycling, sanitizer-aware tests, full matrix sweeps, and quality gates. |

## `Invoke-AgenticLoop` Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `Config` | `[object]` | Configuration object (`ConvertFrom-Json` of the config file; keys below) |
| `Engine` | `[string]` | Engine override (`claude` / `opencode`); empty = config `engine` / `$env:AGENTIC_ENGINE` |
| `PlannerPrompt` | `[string]` | Optional prompt message for the planner agent; defaults to the shared `planner.md` (see [Default Task Prompts](#default-task-prompts)) |
| `RefactorPlannerPrompt` | `[string]` | Optional prompt for refactor-focus iterations; defaults to the shared `refactor-planner.md`, or to `-PlannerPrompt` when only that one is passed |
| `ExecutorPrompt` | `[string]` | Optional prompt message for the executor agent; defaults to the shared `executor.md` |
| `BuildConfigs` | `[array]` | Build matrix entries (string[] or object[] with name, sanitizer, testCommand, buildDir, buildType); optional — defaults to the platform's `buildMatrix` entries from `Config` |
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
| `promptOverlays.plannerPromptOverlayFile` | `[string]` | — | Repo-relative project overlay composed onto the shared planner role prompt (preferred shape) |
| `promptOverlays.executorPromptOverlayFile` | `[string]` | — | The same for executor/fixer |
| `engines.<engine>.plannerPromptFile` | `[string]` | — | Legacy full override (repo-relative) replacing the shared planner role prompt; read from the selected engine's block |
| `engines.<engine>.executorPromptFile` | `[string]` | — | The same for executor/fixer |
| `engines.claude.plannerAllowedTools` | `[string]` | — | Space-separated `--allowed-tools` list sandboxing the planner |
| `engines.claude.permissionMode` | `[string]` | `bypassPermissions` | Executor permission mode (`bypassPermissions` maps to `--dangerously-skip-permissions`) |
| `engines.claude.extraArgs` | `[string]` | — | Extra CLI args appended to every claude invocation |
| `engines.claude.streamOutput` | `[bool]` | `true` | Stream live progress (tool calls, per-turn text, final cost) via `stream-json`; `false` = silent until completion |
| `models.planner` | `[string]` | — | Legacy fallback model ID for the planner agent. No model at all is FATAL |
| `models.executor` | `[string]` | — | Legacy fallback model ID for the executor agent |
| `intervals.buildEveryNTasks` | `[int]` | 3 | Build after every N completed tasks |
| `intervals.qualityEveryNTasks` | `[int]` | 5 | Quality gate every M tasks |
| `intervals.refactorEveryNIterations` | `[int]` | 3 | Refactor focus every R iterations |
| `intervals.fullMatrixEveryNIterations` | `[int]` | 0 | Full matrix sweep every N iterations (0 = disabled) |
| `intervals.maxIterations` | `[int]` | 0 | Max loop iterations (0 = unlimited) |
| `intervals.maxExecutorRetries` | `[int]` | 3 | Executor runs without progress before the queue drain gives up for this iteration |
| `intervals.loopDelaySeconds` | `[int]` | 0 | Delay between loop iterations |
| `intervals.timeoutSeconds` | `[int]` | 0 | Generic agent invocation timeout (0 = none) |
| `intervals.plannerTimeoutSeconds` | `[int]` | 0 | Planner timeout override |
| `intervals.executorTimeoutSeconds` | `[int]` | 0 | Executor/fixer timeout override |
| `intervals.agentRetries` | `[int]` | 2 | Retries per agent invocation (linear backoff) |
| `intervals.agentRetryDelaySeconds` | `[int]` | 20 | Base backoff delay between agent retries |
| `intervals.fixBuildFailures` | `[bool]` | `true` | Dispatch the fixer agent after a failed build, then rebuild once |
| `intervals.maxConsecutiveBuildFailures` | `[int]` | 3 | Stop the loop after N consecutive failed build phases |
| `intervals.waitForUsageLimitReset` | `[bool]` | `true` | When an agent fails because the Claude usage/session limit was hit, sleep until the reset time stated in the message (+2 min) and retry without burning a retry attempt (capped at 10 waits per invocation) |
| `buildMatrix.windows` | `[array]` | — | Windows build matrix entries (objects with name, sanitizer, buildDir, buildType, testCommand) |
| `buildMatrix.linux` | `[array]` | — | Linux build matrix entries |
| `build.windowsScript` | `[string]` | `scripts/windows/Build-Windows-Container.ps1` | Repo-relative Windows build script, called with `-Configurations <name> -SkipTests` |
| `build.linuxScript` | `[string]` | `scripts/linux/cmake-configure-build.sh` | Repo-relative Linux build script, called with `--preset <name> --build-dir <buildDir>` (no default in the Bash loop) |
| `build.windowsTestCommand` | `[string]` | — | Fallback test command for Windows |
| `build.linuxTestCommand` | `[string]` | — | Fallback test command for Linux |
| `build.windowsQualityCommand` | `[string]` | — | Quality command for Windows |
| `build.linuxQualityCommand` | `[string]` | — | Quality command for Linux |
| `git.autoCommit` | `[bool]` | `true` | Auto-commit after each completed task |
| `git.commitPrefix` | `[string]` | `agentic-loop` | Prefix for auto-commit messages |
| `backlog.skipPlannerWhenTasksPending` | `[bool]` | `true` | Skip the planner phase while `BACKLOG.md` still has actionable `- [ ]` tasks. Blocked `- [b]` entries don't count, and a zero-progress iteration forces the planner to run next iteration (starvation guard); if the planner ran and the executor still made no progress, the loop stops |
| `backlog.deleteCompletedTasks` | `[bool]` | `true` | Prune completed (`- [x]`) task blocks from `BACKLOG.md` after each task (history lives in git) |
| `logging.logDir` | `[string]` | `logs/agentic-loop` | Repo-relative log directory, read by `Initialize-AgenticLoop` (the Bash loop always uses the default) |

The config template also carries `intervals.testAfterBuild` and
`logging.logToConsole`; nothing reads either.

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
Invoke-AgenticLoop -Config $cfg -RepoRoot $repoRoot
```

### Planner only (add tasks without executing)

```pwsh
Invoke-AgenticLoop -Config $cfg -RepoRoot $repoRoot -PlannerOnly
```

### Executor only (drain existing queue)

```pwsh
Invoke-AgenticLoop -Config $cfg -RepoRoot $repoRoot -ExecutorOnly
```
