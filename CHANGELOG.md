# Changelog

## 2026-07-30 — Agentic loop: live streaming output

- **Claude engine streams by default**: `claude -p` now runs with
  `--output-format stream-json --verbose` (config
  `engines.claude.streamOutput`, default `true`) and both libraries render
  the events live to console + log: session start, one line per tool call,
  assistant text per turn, tool errors, and a final
  `turns / duration / cost` summary. Set `streamOutput: false` to return to
  the silent text mode.
- **Bash opencode invocation streams too**: output is echoed line-by-line to
  console + log as it arrives instead of being buffered until exit (the
  PowerShell module already streamed).

## 2026-07-30 — Agentic loop: Claude Code engine + robustness

- **Engine abstraction** in both agentic-loop libraries
  (`linux/scripts/lib/agentic-loop.sh`,
  `windows/scripts/modules/WindowsAgenticLoop.Common.psm1`): `opencode` and
  `claude` (Claude Code CLI, headless `claude -p`) backends behind a single
  dispatcher (`invoke_agent` / `Invoke-AgenticAgent`). Selection via config
  `engine`, `AGENTIC_ENGINE`, or runner flag; model overrides via
  `AGENTIC_PLANNER_MODEL` / `AGENTIC_EXECUTOR_MODEL`.
- **Claude engine**: role system prompts via `--append-system-prompt-file`,
  planner sandboxed with `--allowed-tools`, executor permission mode
  configurable (default `bypassPermissions`), planner `--fallback-model`
  support.
- **Robustness**: retry with linear backoff per agent invocation, per-role
  timeouts (`plannerTimeoutSeconds` / `executorTimeoutSeconds`), build-failure
  fixer phase (executor-tier model gets the build log tail, then one rebuild),
  consecutive-build-failure cap that stops the loop, dry-run stall guard.
- **Shared loop features moved into the libraries**: planner-only /
  executor-only modes, max-iteration override, default phase prompts.
- PowerShell module: new exports `Resolve-AgenticEngine`, `Invoke-ClaudeCode`,
  `Invoke-AgenticAgent`, `Invoke-AgentProcess`, `Invoke-BuildFixer`,
  `Get-AgenticConfigValue`, `Get-AgentTimeoutForRole`; module version 1.1.0.
  Fixed the refactor planning cycle erroneously reusing the executor prompt.
- Pester suite extended to 38 tests (engine resolution, dispatcher, claude
  dry-run, engine-override loop smoke tests).
