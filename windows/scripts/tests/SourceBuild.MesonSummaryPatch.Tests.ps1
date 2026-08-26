#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Invoke-MesonBuildSubprojectSummaryPatch over a fixture copy of meson 1.12.0's
# Interpreter.summary_impl (mesonbuild/interpreter/interpreter.py:1482-1486,
# verbatim). The patch is load-bearing on the arm64 cross lane -- without it
# glib(build) throws "Summary section 'Build environment' already have key
# 'host cpu'" and libnice/webrtc/nice vanish (run 25, 2026-08-26) -- so the
# regex must (a) hit the real 1.12.0 layout byte-for-byte, (b) insert at the
# right Python indentation, (c) be idempotent, and (d) THROW on layout drift
# rather than warn. Pure fixture; no meson, no python needed.
#
# The function lives in build-gstreamer-from-source.ps1 (NOT a module: the
# whole modules dir is bind-mounted into every media RUN, so a module edit
# re-keys all branches on both lanes). The suite lifts it out of the script's
# AST instead of running the script -- same function text, no build.

Describe 'Invoke-MesonBuildSubprojectSummaryPatch' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Patches.psm1') -Force -DisableNameChecking
        $gstScript = Join-Path $root 'scripts\build\build-gstreamer-from-source.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($gstScript, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) { throw "parse errors in $gstScript : $($parseErrors[0].Message)" }
        $fnAst = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Invoke-MesonBuildSubprojectSummaryPatch' }, $true)) | Select-Object -First 1
        if (-not $fnAst) { throw "Invoke-MesonBuildSubprojectSummaryPatch not defined in $gstScript" }
        . ([scriptblock]::Create($fnAst.Extent.Text))
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-meson-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null

        # meson 1.12.0 interpreter.py, the four lines around summary_impl, LF line
        # endings exactly as pip installs them. The surrounding lines pin that the
        # patch touches nothing else.
        $script:fixture = @(
            '        self.summary_impl(values=values, **kwargs)',
            '',
            '    def summary_impl(self, section: str, values: dict[str, mlog.TV_Loggable | mlog.TV_LoggableList], bool_yn: bool, list_sep: str | None) -> None:',
            '        if self.subproject not in self.summary:',
            '            self.summary[self.subproject] = Summary(self.active_projectname, self.project_version)',
            '        self.summary[self.subproject].add_section(',
            '            section, values, bool_yn, list_sep, self.subproject)',
            '',
            '    def _print_subprojects(self, for_machine: MachineChoice) -> None:'
        ) -join "`n"
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'inserts the build-machine early return directly under the def line, at 8/12-space indentation' {
        $f = Join-Path $script:tmp 'interpreter.py'
        [IO.File]::WriteAllText($f, $script:fixture)
        $r = Invoke-MesonBuildSubprojectSummaryPatch -InterpreterPath $f
        Assert-True $r 'first call reports patched'
        $lines = [IO.File]::ReadAllText($f) -split "`n"
        $defIdx = [array]::IndexOf($lines, ($lines | Where-Object { $_ -like '    def summary_impl(*' } | Select-Object -First 1))
        Assert-True ($defIdx -ge 0) 'def line preserved'
        Assert-Equal '        if self.subproject and self.build.for_machine is MachineChoice.BUILD:' $lines[$defIdx + 1] 'guard line at 8 spaces'
        Assert-True ($lines[$defIdx + 2] -match '^            return  # \[kataglyphis meson build-subproject summary fix\]$') 'return at 12 spaces with marker'
        Assert-Equal '        if self.subproject not in self.summary:' $lines[$defIdx + 3] 'original first statement follows unchanged'
        # Parenthesised on purpose: `(...).Count + 2` in argument mode splits into
        # THREE arguments (the `+ positional` trap in docs/windows-build-invariants.md).
        Assert-Equal (($script:fixture -split "`n").Count + 2) $lines.Count 'exactly two lines added'
        Assert-True (([IO.File]::ReadAllText($f)) -notmatch "`r") 'LF endings preserved (no CR introduced)'
    }

    It 'is idempotent: a second call reports applied and changes nothing' {
        $f = Join-Path $script:tmp 'interpreter.py'
        $before = [IO.File]::ReadAllText($f)
        $r = Invoke-MesonBuildSubprojectSummaryPatch -InterpreterPath $f
        Assert-True $r 'second call reports applied'
        Assert-Equal ([IO.File]::ReadAllText($f)) $before 'byte-identical after second call'
    }

    It 'throws (does not warn) when summary_impl no longer has the expected first statement' {
        $f = Join-Path $script:tmp 'drift.py'
        # A future meson that keys the summary differently: the def line is still
        # there, the first statement is not. The patch must refuse loudly.
        [IO.File]::WriteAllText($f, ($script:fixture -replace 'if self\.subproject not in self\.summary:', 'key = self.summary_key()'))
        $threw = $false
        try { Invoke-MesonBuildSubprojectSummaryPatch -InterpreterPath $f 3>$null | Out-Null } catch { $threw = $true }
        Assert-True $threw 'layout drift must throw'
    }

    It 'throws when the interpreter file is missing' {
        $threw = $false
        try { Invoke-MesonBuildSubprojectSummaryPatch -InterpreterPath (Join-Path $script:tmp 'absent.py') | Out-Null } catch { $threw = $true }
        Assert-True $threw 'missing file must throw'
    }
}
