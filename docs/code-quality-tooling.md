<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Code Quality Tooling (clang-format, clang-tidy, cmake-format)

The commands, the traps and the cadence — everything that is true for any
Kataglyphis C++ project. Adopted here 2026-08-07 from a consumer that had it all
in its own `docs/code-quality.md`; what stayed behind there is that project's
measured drift figures and its own build-script wiring.

The configs these tools read (`.clang-format`, `.clang-tidy`, `gcovr.cfg`) are
owned by this repo too — see [`shared/config/README.md`](../shared/config/README.md)
for why they are copied into consumers rather than referenced.

## Where the tools are

LLVM is commonly installed on Windows hosts but **not on `PATH`**:

```pwsh
$CF = 'C:\Program Files\LLVM\bin\clang-format.exe'
$CT = 'C:\Program Files\LLVM\bin\clang-tidy.exe'
```

On Linux the wrapper `linux/scripts/lib/code-quality.sh` resolves them for you
and additionally runs `cmake-format`, provisioning it through `uv` +
`requirements.txt` when absent.

## clang-format

Works on the host with no build directory — it needs only the source and
`.clang-format`.

**Scope matters.** `git ls-files '*.cpp'` from a repo root also matches vendored
third-party code under `ExternalLib/`, which is not yours to reformat. Always
scope to your own sources:

```pwsh
$own = git ls-files 'Src/*.cpp' 'Src/*.hpp' 'Src/*.ixx' 'Test/*.cpp' 'Test/*.hpp'
```

**Check only** (CI-style, writes nothing, non-zero exit on drift):

```pwsh
$dirty = @()
foreach ($f in $own) {
  & $CF --dry-run --Werror $f 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { $dirty += $f }
}
"$($dirty.Count) / $($own.Count) files need formatting"
```

**Apply in place:**

```pwsh
foreach ($f in $own) { & $CF -i $f }
```

**Only what you touched** — the low-risk everyday version. Reformatting a whole
tree at once buries real changes in noise:

```pwsh
git diff --name-only HEAD -- 'Src/*' 'Test/*' |
  Where-Object { $_ -match '\.(cpp|hpp|ixx|h)$' } |
  ForEach-Object { & $CF -i $_ }
```

## clang-tidy

Needs `compile_commands.json`. Two traps that cost real time:

1. **Container paths.** A database generated *inside* a build container records
   the container's workspace root (e.g. `C:/ws`). Running host clang-tidy
   against it fails with `LLVM ERROR: Cannot chdir into "C:/ws/<build-dir>"`.
   Rewriting the paths into a scratch copy gets it running:

   ```pwsh
   $db = "$env:TEMP\tidydb"; New-Item -ItemType Directory -Force $db | Out-Null
   (Get-Content <build-dir>\compile_commands.json -Raw) `
     -replace '<container-workspace>', '<host-repo-root>' |
     Set-Content "$db\compile_commands.json" -NoNewline
   & $CT -p $db --quiet <a-source-file>
   ```

2. **C++23 modules.** Even with paths fixed, translation units that `import` a
   module fail (`cannot open file '...X.ixx'`) because module BMIs still
   reference the container layout. A project's clang-tidy wrapper should
   therefore **skip files using module syntax**. What remains checkable is the
   non-module surface — still worthwhile:
   `cppcoreguidelines-special-member-functions`,
   `modernize-use-trailing-return-type` and friends fire on real code.

The clean alternative is to let the build run clang-tidy, where paths are
consistent by construction.

## Suggested cadence

- **Per change:** format the files you touched (the `git diff` variant).
- **Weekly / before a PR:** full check across your own sources; fix what is
  yours.
- **Periodically:** a clang-tidy pass over the non-module TUs, plus
  `linux/scripts/lib/code-quality.sh` on Linux — it adds `scan-build` static
  analysis on top.

## The failure mode to watch for

A clang-format check that **reports** a deviating count without **failing** the
build lets drift grow indefinitely while every build stays green. One consumer
went from 72 to 142 deviating files that way. If you wire the check into a build,
decide explicitly whether it gates — and if it does not, track the number
somewhere a test can assert on, so the growth is at least visible.

Reformatting a large accumulated drift is a **decision, not a chore**: it
touches most of the tree in one commit and collides with in-flight work. Do it
deliberately, ideally right after a merge point, and add the commit to
`.git-blame-ignore-revs` so history stays readable.
