#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# THE OTHER DIRECTION FROM Modules.ReExport.Tests.ps1, and the one that keeps
# costing hours.
#
# ReExport asserts that every name in an Export-ModuleMember list resolves. It
# cannot see the inverse defect: a function that EXISTS in a nested module,
# is used happily inside the module graph, and is NEVER added to the re-export
# list -- while a build script calls it directly. Module-internal use never
# needs the export list; a direct script call does.
#
# That defect is invisible on a dev box (the whole modules dir is on disk and
# earlier imports pollute the session), invisible to the linter, and invisible
# to every existing suite. It surfaces as a bare CommandNotFoundException
# inside a container, typically well into a compile stage. It has now happened
# twice:
#   * #113 / verify12 -- two names used directly by Build-GstreamerFromSource.ps1
#     threw CommandNotFound at compile start.
#   * #134 / arm64 run 37 -- Resolve-BuildMachineMsvcTool was promoted into
#     WindowsTargetArch.Common and exported THERE, but not added to
#     WindowsSourceBuild.Common's re-export list. media-core, media-litert and
#     media-tvm all built; the merge stage then died two hours in at
#     "PHASE: 6. meson setup".
#
# So: for every build script, take the module-defined functions it actually
# CALLS, and prove they resolve in a FRESH pwsh that imports only the modules
# that script imports. Fresh child process on purpose -- this session's earlier
# imports are exactly the pollution being tested for.

Describe 'build scripts can resolve every module function they call (cold import)' {

    BeforeAll {
        $script:repoRoot  = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
        $script:moduleDir = Join-Path $script:repoRoot 'windows\scripts\modules'
        $script:buildDir  = Join-Path $script:repoRoot 'windows\scripts\build'

        # Every function name any module DEFINES. Only these are checked: a call
        # to a cmdlet, a native exe or a script-local function is not our problem.
        $script:moduleFunctions = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@(Get-ChildItem -Path $script:moduleDir -Filter '*.psm1' -File | ForEach-Object {
                [regex]::Matches([System.IO.File]::ReadAllText($_.FullName), '(?m)^function\s+([A-Za-z]+(?:-[A-Za-z0-9]+)+)') |
                    ForEach-Object { $_.Groups[1].Value }
            }),
            [System.StringComparer]::OrdinalIgnoreCase)
    }

    It 'every module function a build script calls is exported by the modules it imports' {
        Assert-True ($script:moduleFunctions.Count -ge 100) `
            "parsed only $($script:moduleFunctions.Count) module function definitions — the scan broke and this gate is checking air"

        $scripts = @(Get-ChildItem -Path $script:buildDir -Filter '*.ps1' -File)
        Assert-True ($scripts.Count -ge 10) "found only $($scripts.Count) build scripts — layout moved"

        $checked = 0
        $bad = @()
        foreach ($s in $scripts) {
            $text = [System.IO.File]::ReadAllText($s.FullName)

            # Modules this script imports, by the two idioms in the tree:
            # a `modules\X.psm1` path, or a bare 'X.psm1' in a foreach list.
            $wanted = @([regex]::Matches($text, '(?i)modules[\\/]([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value })
            $wanted += @([regex]::Matches($text, "(?i)'(Windows[A-Za-z0-9._]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value })
            $wanted = @($wanted | Sort-Object -Unique | Where-Object { Test-Path (Join-Path $script:moduleDir "$_.psm1") })
            if (-not $wanted) { continue }

            # Functions the script defines itself never need an export.
            $local = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@([regex]::Matches($text, '(?m)^\s*function\s+([A-Za-z]+(?:-[A-Za-z0-9]+)+)') | ForEach-Object { $_.Groups[1].Value }),
                [System.StringComparer]::OrdinalIgnoreCase)

            # Called commands, via the AST (a regex over call sites would also
            # match the names inside comments and error strings -- and this file
            # is full of both).
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

            $needed = @($calls | Sort-Object -Unique |
                Where-Object { $script:moduleFunctions.Contains($_) -and -not $local.Contains($_) })
            if (-not $needed) { continue }
            $checked++

            $importLines = ($wanted | ForEach-Object { "Import-Module '$(Join-Path $script:moduleDir "$_.psm1")' -DisableNameChecking" }) -join "`n"
            $probe = @"
`$ErrorActionPreference = 'Stop'
$importLines
`$missing = @('$($needed -join "','")') | Where-Object { -not (Get-Command `$_ -ErrorAction SilentlyContinue) }
if (`$missing) { `$missing -join ','; exit 1 }
exit 0
"@
            $out = & pwsh -NoProfile -NonInteractive -Command $probe 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $bad += "$($s.Name) calls but cannot resolve: $($out.Trim())  [imports: $($wanted -join ', ')]"
            }
        }

        Assert-True ($checked -ge 5) "only $checked script(s) had any module call to check — the AST/import scan broke"
        Assert-True ($bad.Count -eq 0) ("a build script calls a module function that no module it imports EXPORTS. " +
            "Module-internal use never needs the export list; a direct script call does. Add the name to the owning " +
            "module's Export-ModuleMember, and — if it reaches the script through WindowsSourceBuild.Common — to that " +
            "module's re-export list too:`n  " + ($bad -join "`n  "))
    }
}
