#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Invoke-MesonBuildSubprojectPatch over a fixture copy of the meson 1.12.0
# Interpreter lines it rewrites (mesonbuild/interpreter/interpreter.py, verbatim:
# the two disabled_subproject(subp_name, exception=e) sites in do_subproject and
# the two configure_file lines that use self.subdir). The patch is load-bearing
# on the arm64 cross lane -- without it a failed glib(build) overwrites the HOST
# glib holder and libnice/webrtc/nice vanish (runs 25-27, 2026-08-26) -- so the
# regexes must (a) hit the real 1.12.0 layout, (b) rewrite exactly those lines,
# (c) be idempotent per fix, and (d) THROW on layout drift rather than warn.
# The function lives in build-gstreamer-from-source.ps1 (NOT a module: the
# mounted module set is one shared closure -- `buildmods`' six .psm1, which the
# classic lane also COPYs into `common`, every BK compile stage's ancestor --
# so a module edit re-keys all branches on both lanes; #134 splits that).
# Lifted out of the script's AST.

Describe 'Invoke-MesonBuildSubprojectPatch' {

    BeforeAll {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-meson-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null

        # meson 1.12.0 interpreter.py excerpts, LF line endings as pip installs them.
        $script:fixture = @(
            '            if not required:',
            '                mlog.log(e)',
            "                mlog.log(*msg, '(disabling)')",
            '                return self.disabled_subproject(subp_name, exception=e)',
            '            mlog.error(*msg)',
            '            raise e',
            '',
            '        except Exception as e:',
            '            if not required:',
            "                mlog.log('\nSubproject', mlog.bold(subdir), 'is buildable:', mlog.red('NO'), '(disabling)')",
            '                return self.disabled_subproject(subp_name, exception=e)',
            '            raise e',
            '',
            '        ofile_rpath = os.path.join(self.subdir, build_subdir, output)',
            '        if ofile_rpath in self.configure_file_outputs:',
            '            pass',
            '        return mesonlib.File.from_built_file(self.subdir, output)',
            '',
            '    def current_build_project(self) -> build.BuildProject:'
        ) -join "`n"
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'rewrites both disabled_subproject sites and both configure_file lines, nothing else' {
        $f = Join-Path $script:tmp 'interpreter.py'
        [IO.File]::WriteAllText($f, $script:fixture)
        $r = Invoke-MesonBuildSubprojectPatch -InterpreterPath $f
        Assert-True $r 'first call reports patched'
        $out = [IO.File]::ReadAllText($f)
        $lines = $out -split "`n"
        Assert-Equal (($script:fixture -split "`n").Count) $lines.Count 'no lines added or removed'
        # EndsWith, not -like: the marker's [brackets] would be a wildcard character class.
        $keyLine = 'disabled_subproject(subp_name, exception=e, for_machine=for_machine)  # [kataglyphis meson build-subproject machine-key fix]'
        $keySites = @($lines | Where-Object { $_.EndsWith($keyLine) })
        Assert-Equal 2 $keySites.Count 'both failure paths pass for_machine'
        Assert-True ($lines -contains '        ofile_rpath = os.path.join(self.current_build_project().prefix + self.subdir, build_subdir, output)  # [kataglyphis meson build-subproject configure_file fix]') 'configure_file output path carries the project prefix'
        Assert-True ($lines -contains '        return mesonlib.File.from_built_file(self.current_build_project().prefix + self.subdir, output)  # [kataglyphis meson build-subproject configure_file fix]') 'configure_file return File carries the project prefix'
        Assert-False ($out -match 'disabled_subproject\(subp_name, exception=e\)\s*$') 'no unpatched failure path left'
        Assert-True ($out -notmatch "`r") 'LF endings preserved'
        Assert-True ($lines[0] -eq '            if not required:' -and $lines[-1] -eq '    def current_build_project(self) -> build.BuildProject:') 'surrounding lines untouched'
    }

    It 'is idempotent: a second call reports applied and changes nothing' {
        $f = Join-Path $script:tmp 'interpreter.py'
        $before = [IO.File]::ReadAllText($f)
        $r = Invoke-MesonBuildSubprojectPatch -InterpreterPath $f
        Assert-True $r 'second call reports applied'
        Assert-Equal $before ([IO.File]::ReadAllText($f)) 'byte-identical after second call'
    }

    It 'throws when the disabled_subproject site count is not exactly two (layout drift)' {
        $f = Join-Path $script:tmp 'drift-key.py'
        $one = $script:fixture -replace "(?m)^                return self\.disabled_subproject\(subp_name, exception=e\)\n            mlog\.error", "                return self.disabled_subproject(subp_name, exception=e, for_machine=for_machine)`n            mlog.error"
        [IO.File]::WriteAllText($f, $one)
        $threw = $false
        try { Invoke-MesonBuildSubprojectPatch -InterpreterPath $f | Out-Null } catch { $threw = $true }
        Assert-True $threw 'one site instead of two must throw'
    }

    It 'throws when a configure_file line is missing (layout drift)' {
        $f = Join-Path $script:tmp 'drift-cf.py'
        [IO.File]::WriteAllText($f, ($script:fixture -replace 'return mesonlib\.File\.from_built_file\(self\.subdir, output\)', 'return self._cf_file(output)'))
        $threw = $false
        try { Invoke-MesonBuildSubprojectPatch -InterpreterPath $f | Out-Null } catch { $threw = $true }
        Assert-True $threw 'missing configure_file return line must throw'
    }

    It 'throws when the interpreter file is missing' {
        $threw = $false
        try { Invoke-MesonBuildSubprojectPatch -InterpreterPath (Join-Path $script:tmp 'absent.py') | Out-Null } catch { $threw = $true }
        Assert-True $threw 'missing file must throw'
    }
}
