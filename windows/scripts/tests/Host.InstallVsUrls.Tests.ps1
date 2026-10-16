#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Every base build of 2026-10-16 fetched HTML from aka.ms/vs/18/release/ three times before the fallback; VS 18's channel is stable.

$installVs = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\host\Install-Vs.ps1'))

Describe 'Install-Vs.ps1: the bootstrapper URLs' {

    It 'tries the major-pinned stable channel first, then release for older majors, then the floating alias' {
        $stable = $installVs.IndexOf('"https://aka.ms/vs/$script:VsMajor/stable/vs_buildtools.exe"')
        $release = $installVs.IndexOf('"https://aka.ms/vs/$script:VsMajor/release/vs_buildtools.exe"')
        $floating = $installVs.IndexOf('        $vsFloatingUrl' + [Environment]::NewLine)
        if ($floating -lt 0) { $floating = $installVs.IndexOf("        `$vsFloatingUrl`n") }
        Assert-True ($stable -gt 0 -and $release -gt $stable -and $floating -gt $release) "order stable $stable, release $release, floating $floating"
        Assert-True $installVs.Contains("`$vsFloatingUrl = 'https://aka.ms/vs/stable/vs_buildtools.exe'") 'the floating alias is named once'
    }

    It 'warns about the floating channel only for the floating alias, not for the pinned stable one' {
        Assert-True $installVs.Contains('if ($vsUrl -eq $vsFloatingUrl) {') 'the warning compares with the floating alias'
        Assert-False $installVs.Contains("`$vsUrl -match 'stable'") 'a pattern match would call the pinned stable URL floating'
    }
}
