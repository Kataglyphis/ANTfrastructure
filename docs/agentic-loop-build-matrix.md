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

| Function | Purpose |
|----------|---------|
| `Resolve-BuildMatrixEntry -Entry <object>` | Normalize a string or JSON object to a hashtable with `Name`, `Sanitizer`, `TestCommand`, `BuildDir`, `BuildType` |
| `Get-SanitizerEnvVars -Sanitizer <string>` | Return a hashtable of env vars for the given sanitizer |
| `Invoke-SanitizerTestCommand -Command <string> -Sanitizer <string> -RepoRoot <string>` | Set sanitizer env vars, run tests, restore env |
| `Invoke-AgenticLoop -Config <object> -BuildConfigs <array> ...` | Full loop with build matrix cycling, sanitizer-aware tests, and full matrix sweeps |

### Bash (`agentic-loop.sh`)

| Function | Purpose |
|----------|---------|
| `get_sanitizer_env_vars <sanitizer>` | Echo env var assignment string for the sanitizer |
| `invoke_sanitizer_tests <cmd> <sanitizer>` | Set env vars, run tests, restore env |
| `resolve_build_matrix_entry <config_json> <index> <platform>` | Parse a matrix entry to globals `MATRIX_*` |
| `count_build_matrix <config_json> <platform>` | Count matrix entries for a platform |
| `get_matrix_entry_name <config_json> <index> <platform>` | Get entry name by index (backward-compatible) |
| `run_agentic_loop <config_json> <repo_root> <platform>` | Full loop with build matrix, sanitizer tests, quality gates |