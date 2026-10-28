#requires -Version 7.0
# A real child supplies the exit status; Windows cmd transport is covered separately.

function New-CpythonPipFixture {
    param([string]$Dir)
    $child = Join-Path $Dir 'fake-python.ps1'
    Set-Content -LiteralPath $child -Value @(
        'param([string]$Marker)'
        '[IO.File]::WriteAllText($Marker, ''child ran'')'
        'Write-Output ''pip progress line'''
        'exit 7'
    )
    return @{
        ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Common.psm1'
        FunctionName = @('Invoke-CpythonPip')
        FixtureState = [pscustomobject]@{ Child = $child; Marker = (Join-Path $Dir 'child-marker.txt'); Exit = -1;
            Calls = [Collections.Generic.List[string]]::new() }
        Prelude = @'
function cmd.exe {
    param([string]$Mode, [string]$Line)
    if ($Mode -ne '/c') { throw "unexpected cmd mode: $Mode" }
    $State.Calls.Add($Line)
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $State.Child $State.Marker
    $State.Exit = $LASTEXITCODE
    $global:LASTEXITCODE = $State.Exit
}
'@
    }
}

function Assert-CpythonPipChild {
    param($State)
    Assert-Equal 7 $State.Exit 'the fake child must return its actual exit code'
    Assert-True (Test-Path -LiteralPath $State.Marker -PathType Leaf) 'the fake child must run'
    Assert-Equal 'child ran' ([IO.File]::ReadAllText($State.Marker))
    Assert-Match '-m pip install x 2>&1' $State.Calls[$State.Calls.Count - 1]
}

function Assert-CpythonPipPolicy {
    param($State)
    $python = @{ Exe = $State.Child }
    Assert-Throws { Invoke-MutCpythonPip -Python $python -Arguments @('install', 'x') } `
        -MessagePattern '^pip install x failed \(exit 7\)$'
    Assert-CpythonPipChild $State
    Remove-Item -LiteralPath $State.Marker -Force
    $State.Exit = -1
    $output = @(Invoke-MutCpythonPip -Python $python -Arguments @('install', 'x') -Optional 3>$null)
    Assert-Equal '' ($output -join '; ') 'pip output must stay off the output stream'
    Remove-Item -LiteralPath $State.Marker -Force
    $warnings = @(Invoke-MutCpythonPip -Python $python -Arguments @('install', 'x') -Optional 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    Assert-Equal 1 $warnings.Count 'optional failure must emit one warning'
    Assert-Match '^pip install x failed \(exit 7\) -- continuing$' $warnings[0]
    Assert-CpythonPipChild $State
    $calls = $State.Calls.Count
    Assert-Throws { Invoke-MutCpythonPip -Python @{ Exe = "$($State.Child).missing" } -Arguments @('install', 'x') } `
        -MessagePattern '^Source-built Python not found at '
    Assert-Equal $calls $State.Calls.Count 'a missing interpreter must not launch a child'
}

function Invoke-CpythonPipMutation {
    param([string]$Find, [string]$Replace, [string]$Expected)
    Invoke-TestFunctionMutations -ModuleArgumentsFactory ${function:New-CpythonPipFixture} -IncludeControl `
        -Find $Find -Replace $Replace -Expected $Expected -Body { param($state) Assert-CpythonPipPolicy $state }
}

Describe 'Invoke-CpythonPip' {
    It 'checks the real child exit for required, optional and missing interpreters' {
        Invoke-InTestDir { param($dir)
            $fixture = New-CpythonPipFixture $dir
            Invoke-WithFunctionModule @fixture -Body { param($state) Assert-CpythonPipPolicy $state }
        }
    }

    It 'detects a swallowed required failure (mutation)' {
        Invoke-CpythonPipMutation 'if ($exit -ne 0) {' 'if ($false) {' 'expected an exception but none was thrown'
    }

    It 'detects pip output leaking into the caller''s return value (mutation)' {
        Invoke-CpythonPipMutation '2>&1" | Out-Host' '2>&1"' 'pip output must stay off the output stream'
    }

    It 'detects a missing optional warning (mutation)' {
        Invoke-CpythonPipMutation 'if ($Optional) { Write-Warning "$msg -- continuing"; return }' 'if ($Optional) { return }' `
            'optional failure must emit one warning'
    }
}
