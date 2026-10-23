#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Child transport fixtures do not validate real uv, interpreter or wheel behavior.

function New-PythonCiFixtureTools {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string[]]$UvBody,
        [string[]]$PythonBody = @())
    $fake = Join-Path $Dir 'fake'
    $null = New-Item -ItemType Directory -Force -Path $fake
    New-FakeToolShim -Dir $fake -Tool uv, python
    Set-Content -LiteralPath (Join-Path $fake 'fake-uv.ps1') -Encoding utf8 -Value $UvBody
    Set-Content -LiteralPath (Join-Path $fake 'fake-python.ps1') -Encoding utf8 -Value (@(
        'if ($args[2] -eq "declares") { if ($env:FAKE_DECLARES) { "Free Threading"; exit 0 }; "no classifier"; exit 1 }'
    ) + $PythonBody)
    return $fake
}

function Invoke-PythonCiFixtureDriver {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][hashtable]$Environment, [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path)
    $log = Join-Path $Dir 'calls.log'
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $vars = $Environment.Clone()
    $vars.FAKE_LOG = $log
    $output = Invoke-WithEnv $vars {
        Push-Location -LiteralPath $WorkingDirectory
        try { & pwsh -NoProfile -File $Script @Arguments 2>&1 | ForEach-Object { "$_" } } finally { Pop-Location }
    }
    $code = $LASTEXITCODE
    $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
    # Child error views insert ANSI escapes and continuation gutters into assertion messages.
    $text = ($output -join "`n") -replace '\x1b\[[0-9;]*m', '' -replace '\s*\n\s*(\|\s*)*', ' '
    return [pscustomobject]@{ Code = $code; Calls = $calls; Text = $text }
}

Export-ModuleMember -Function New-PythonCiFixtureTools, Invoke-PythonCiFixtureDriver
