# Agentic Loop Build Matrix

The agentic loop cycles through a **build matrix** — a set of build
configurations that each define a preset, a sanitizer, a build directory,
and an optional test command. This ensures the loop doesn't only test one
build type but regularly exercises ASAN, TSan, profile, and release builds
across both Windows (Stevedore) and Linux (Rancher Desktop).

## Configuration

The build matrix is defined in the project's `AgenticLoop.config.json` under
the `buildMatrix` key. Each platform (`windows`, `linux`) has an array of
entries:

```json
{
  "buildMatrix": {
    "windows": [
      {
        "name": "clangcl-debug",
        "sanitizer": "asan",
        "buildDir": "build-clangcl-debug",
        "buildType": "Debug",
        "testCommand": "ctest --test-dir build-clangcl-debug --output-on-failure -C Debug"
      },
      {
        "name": "clangcl-profile",
        "sanitizer": "none",
        "buildDir": "build-clangcl-profile",
        "buildType": "RelWithDebInfo",
        "testCommand": "ctest --test-dir build-clangcl-profile --output-on-failure -C RelWithDebInfo"
      },
      {
        "name": "clangcl-release",
        "sanitizer": "none",
        "buildDir": "build-clangcl-release",
        "buildType": "Release",
        "testCommand": null
      }
    ],
    "linux": [
      {
        "name": "linux-debug-asan-clang",
        "sanitizer": "asan",
        "buildDir": "build-asan-clang",
        "buildType": "Debug",
        "testCommand": "ctest --test-dir build-asan-clang --output-on-failure -C Debug"
      },
      {
        "name": "linux-debug-tsan-clang",
        "sanitizer": "tsan",
        "buildDir": "build-tsan-clang",
        "buildType": "Debug",
        "testCommand": "ctest --test-dir build-tsan-clang --output-on-failure -C Debug"
      },
      {
        "name": "linux-profile-clang",
        "sanitizer": "none",
        "buildDir": "build-profile-clang",
        "buildType": "RelWithDebInfo",
        "testCommand": "ctest --test-dir build-profile-clang --output-on-failure -C RelWithDebInfo"
      },
      {
        "name": "linux-release-clang",
        "sanitizer": "none",
        "buildDir": "build-release-clang",
        "buildType": "Release",
        "testCommand": null
      }
    ]
  }
}
```

### Entry Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Build configuration name (maps to a CMake preset or `Build-Windows.config.psd1` entry) |
| `sanitizer` | `string` | `asan`, `tsan`, or `none` — controls env vars set before tests |
| `buildDir` | `string` | Build directory (used for Linux `--build-dir` and for `ctest --test-dir`) |
| `buildType` | `string` | CMake build type (`Debug`, `RelWithDebInfo`, `Release`) — used for `ctest -C` |
| `testCommand` | `string\|null` | Shell command for tests, or `null` to skip tests for this config |

### Backward Compatibility

The module also accepts the legacy `buildConfigurations` format (arrays of
strings). Strings are normalized to entries with `sanitizer: "none"` and no
per-config test command. This means existing configs keep working without
changes.

## Sanitizer-Aware Test Execution

When a matrix entry has `sanitizer: "asan"` or `sanitizer: "tsan"`, the
module automatically sets the appropriate environment variables before
running the test command, then restores the original environment:

| Sanitizer | Env Var | Value |
|-----------|---------|-------|
| `asan` | `ASAN_OPTIONS` | `detect_leaks=1:halt_on_error=1:abort_on_error=1:allocator_may_return_null=1` |
| `tsan` | `TSAN_OPTIONS` | `halt_on_error=1:abort_on_error=1:second_deadlock_stack=1` |
| `none` | — | No env vars set |

This ensures sanitizer-instrumented tests actually catch memory errors and
data races, rather than silently passing because the sanitizer was not
configured to halt on error.

### Windows ASAN Note

On Windows, the ASAN debug binary needs `clang_rt.asan_dynamic-x86_64.dll`
next to the executable. The build copies it automatically. The
`ASAN_OPTIONS` env var must use a **relative** `log_path` — an absolute
`C:\...` path breaks ASAN option parsing at the drive-letter colon. The
module's default `ASAN_OPTIONS` does not set `log_path`, avoiding this
issue.

## Full Matrix Sweep

In addition to cycling one config per build trigger, the loop supports a
**full matrix sweep** — every N iterations, it runs ALL configs in
sequence instead of just one. This ensures all configs are exercised
regularly, not just the one that happens to be next in the cycle.

Enable it in the config:

```json
{
  "intervals": {
    "fullMatrixEveryNIterations": 5
  }
}
```

- `0` = disabled (cycle one config per build trigger, the default)
- `5` = every 5th iteration, run all configs in sequence

## Build Matrix Cycling

Without a full sweep, the loop cycles through the matrix entries one at a
time. After every `buildEveryNTasks` completed tasks, the next entry in the
matrix is used:

| Build # | Windows | Linux |
|---------|---------|-------|
| 1 | `clangcl-debug` (ASAN) | `linux-debug-asan-clang` (ASAN) |
| 2 | `clangcl-profile` | `linux-debug-tsan-clang` (TSan) |
| 3 | `clangcl-release` | `linux-profile-clang` |
| 4 | `clangcl-debug` (cycles back) | `linux-release-clang` |
| 5 | `clangcl-profile` | `linux-debug-asan-clang` (cycles back) |

This ensures that over multiple build triggers, every config is exercised.

## Cross-Platform Support

The same config file works on both Windows and Linux. The loop
automatically selects the `windows` or `linux` matrix based on the
platform it's running on:

- **Windows**: builds go through `Build-Windows-Container.ps1` (Stevedore
  container). The config name maps to a preset via
  `Build-Windows.config.psd1`.
- **Linux**: builds go through `cmake-configure-build.sh` (Rancher Desktop
  container or native). The config name is the CMake preset, and the
  `buildDir` field overrides the preset's `binaryDir` to ensure each
  config has its own build directory.

## Module API

### PowerShell (`WindowsAgenticLoop.Common.psm1`)

The PowerShell functions implementing this behaviour
(`Resolve-BuildMatrixEntry`, `Get-SanitizerEnvVars`,
`Invoke-SanitizerTestCommand`, and the high-level `Invoke-AgenticLoop`)
are documented in the module API reference,
[`windows-agentic-loop.md`](windows-agentic-loop.md).

### Bash (`agentic-loop.sh`)

| Function | Purpose |
|----------|---------|
| `get_sanitizer_env_vars <sanitizer>` | Echo env var assignment string for the sanitizer |
| `invoke_sanitizer_tests <cmd> <sanitizer>` | Set env vars, run tests, restore env |
| `resolve_build_matrix_entry <config_json> <index> <platform>` | Parse a matrix entry to globals `MATRIX_*` |
| `count_build_matrix <config_json> <platform>` | Count matrix entries for a platform |
| `get_matrix_entry_name <config_json> <index> <platform>` | Get entry name by index (backward-compatible) |
| `run_agentic_loop <config_json> <repo_root> <platform>` | Full loop with build matrix, sanitizer tests, quality gates |
### The two bash files

`agentic-loop.sh` is the only file a consumer sources; it sources
`agentic-engines.sh` from its own directory on load. The split follows the one
seam the file had: **which agent to run and how to talk to it** versus **what to
run it on**.

| File | Owns |
|------|------|
| `lib/agentic-engines.sh` | `_AGENTIC_JQ_PRELUDE`, `load_engine_config`, `agent_timeout_for_role`, `agent_stream_passthrough`, `claude_stream_render`, `invoke_opencode`, `invoke_claude`, `usage_limit_wait_seconds`, `invoke_agent` |
| `lib/agentic-loop.sh` | `LOG_FILE` and `log`/`section`, `init_agentic_loop`/`complete_agentic_loop`, the BACKLOG helpers, the build/test/quality phases, the matrix readers, the `_AL` loop state and `run_agentic_loop` |

The dependency points one way only. The engine half calls `log` and appends to
`LOG_FILE`, both defined by the loop half before it sources the engines — so
`agentic-engines.sh` is a half of one library, not a standalone one. It is
therefore skipped by `test-lib-modules.sh` for the same reason
`agentic-loop.sh` always was: neither is a `lib/` module that must reach
`01-core/logging.sh` and define `info`/`warn`/`err`. `test-lib-smoke.sh` still
covers both (parses, sources clean under `set -euo pipefail`, defines
functions), and `test-agentic-loop.sh` drives the seam from the loop side: it
sources `agentic-loop.sh` only, and its config-precedence and `invoke_agent`
cases land in the engine half through it.

Two engines are supported: `opencode` invokes
`opencode run --agent <role> --model <model>`; `claude` invokes
`claude -p --model <model>` with the role system prompt appended from the
configured prompt file.

### Environment overrides

All optional; each one beats the value in the config JSON.

| Variable | Effect |
|----------|--------|
| `AGENTIC_ENGINE` | `opencode` \| `claude` — overrides `.engine` |
| `AGENTIC_PLANNER_MODEL` | overrides the planner model id |
| `AGENTIC_EXECUTOR_MODEL` | overrides the executor model id |
| `DRY_RUN` | `true` = print actions without invoking anything |
| `SKIP_BUILD` / `SKIP_TESTS` / `SKIP_QUALITY` | skip that phase |
| `PLANNER_ONLY` / `EXECUTOR_ONLY` | single-phase mode |
| `MAX_ITERATIONS_OVERRIDE` | overrides `.intervals.maxIterations` |

Typical use from a project's `Run-AgenticLoop.sh`:

```bash
source "${SCRIPT_DIR}/lib/agentic-loop.sh"
init_agentic_loop "MyProject" "/path/to/repo"
run_agentic_loop "$config_json_path"
```
