#requires -Version 7.0
# Short children and stubbed server stops cover launch/configuration contracts; real sccache writes, mount inheritance and long-running timeouts remain diagnostic coverage.

function Assert-SccacheProcessInfo {
    $arguments = @('space value', '', 'quote"value', "apostrophe'value", 'semi;colon')
    $info = New-MutSccacheProbeProcessInfo -FilePath 'probe compiler.exe' -ArgumentList $arguments
    Assert-Equal 'probe compiler.exe' $info.FileName
    Assert-Equal ($arguments -join '|') ($info.ArgumentList -join '|') 'argument order is preserved without command-line flattening'
    Assert-Equal '' $info.WorkingDirectory 'spawned children inherit the working directory by default'
    Assert-False $info.UseShellExecute
    Assert-True $info.CreateNoWindow
    Assert-True $info.RedirectStandardOutput
    Assert-True $info.RedirectStandardError
    Assert-Equal 0 (New-MutSccacheProbeProcessInfo -FilePath empty -ArgumentList @()).ArgumentList.Count
    Invoke-InTestDir { param($dir)
        $script = Join-Path $dir 'arguments [child].ps1'
        [IO.File]::WriteAllText($script, @'
param([string]$First, [string]$Second)
[Console]::Out.Write(([pscustomobject]@{ First = $First; Second = $Second; Location = (Get-Location).Path } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii))
[Console]::Error.Write('fixture diagnostic')
exit 23
'@)
        $second = "apostrophe'value`nUnicode λ"
        $info = New-MutSccacheProbeProcessInfo -FilePath (Get-Process -Id $PID).Path -WorkingDirectory $dir `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script, 'space value', $second)
        Assert-Equal $dir $info.WorkingDirectory 'parallel compiles retain their explicit directory'
        $process = [Diagnostics.Process]::Start($info)
        try {
            # Fixed output stays below a pipe buffer, so this fixture needs no background drain tasks.
            Assert-True ($process.WaitForExit(15000)) 'the short fixture child must terminate'
            $data = $process.StandardOutput.ReadToEnd() | ConvertFrom-Json
            Assert-Equal 'space value' $data.First
            Assert-Equal $second $data.Second 'the real child receives quotes, Unicode and newlines intact'
            Assert-Equal $dir $data.Location
            Assert-Equal 'fixture diagnostic' ($process.StandardError.ReadToEnd())
            Assert-Equal 23 $process.ExitCode 'process status belongs to the caller'
        } finally {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        Assert-Throws {
            [Diagnostics.Process]::Start((New-MutSccacheProbeProcessInfo -FilePath (Join-Path $dir 'absent.exe')))
        } -MessagePattern 'absent.exe'
    }
}

function Assert-SccacheConfiguration {
    param($State)
    $State.Calls.Clear()
    Invoke-WithEnv @{ SCCACHE_MULTILEVEL_CHAIN = 'prior chain'; SCCACHE_WEBDAV_ENDPOINT = 'prior endpoint'; SCCACHE_DIR = 'prior directory' } {
        $global:LASTEXITCODE = 72
        Set-MutSccacheProbeConfiguration -SccachePath fixture-cache -Chain 'disk,webdav' -Endpoint ' ' -Directory 'cache directory'
        Assert-Equal 1 $State.Calls.Count 'the server stops before configuration changes'
        Assert-Equal 'fixture-cache|prior chain|prior endpoint|prior directory' $State.Calls[0] 'the server stops before configuration changes'
        Assert-Equal 'disk,webdav' $env:SCCACHE_MULTILEVEL_CHAIN
        Assert-Equal ' ' $env:SCCACHE_WEBDAV_ENDPOINT 'whitespace remains an explicit endpoint'
        Assert-Equal 'cache directory' $env:SCCACHE_DIR
        Assert-Equal 0 $global:LASTEXITCODE 'the existing stop helper owns native status reset'
        Set-MutSccacheProbeConfiguration -SccachePath fixture-cache -Directory 'plain directory'
        Assert-Equal 2 $State.Calls.Count
        Assert-False (Test-Path Env:SCCACHE_MULTILEVEL_CHAIN) 'an empty chain is removed'
        Assert-False (Test-Path Env:SCCACHE_WEBDAV_ENDPOINT) 'an empty endpoint is removed'
        Assert-Equal 'plain directory' $env:SCCACHE_DIR
    }.GetNewClosure()
}

function Assert-SccacheErrorLog {
    param($State)
    $State.Calls.Clear()
    Invoke-InTestDir { param($dir)
        $fixture = $State
        $path = Join-Path $dir 'errors log.txt'
        [IO.File]::WriteAllLines($path, @('existing first', 'existing second'))
        Invoke-WithEnv @{ SCCACHE_ERROR_LOG = $path } {
            $fixture.Append = $true
            $log = Read-MutSccacheProbeErrorLog -SccachePath fixture-cache -StopPattern 'Stopping|error'
            Assert-Equal 'existing first|existing second|flushed on stop' ($log.Lines -join '|') 'evidence reads after the server flushes'
            Assert-True $log.Found
            Assert-Equal $path $log.Path
            Assert-Equal 'fixture-cache|Stopping|error' $fixture.Calls[0]
            $fixture.Append = $false
            [IO.File]::WriteAllText($path, '')
            $log = Read-MutSccacheProbeErrorLog -SccachePath fixture-cache
            Assert-True $log.Found 'an empty log remains distinct from a missing log'
            Assert-Equal 0 $log.Lines.Count
            Assert-Equal 'fixture-cache|' $fixture.Calls[-1] 'the per-variant flush stays quiet'
            $env:SCCACHE_ERROR_LOG = Join-Path $dir absent.log
            Assert-False (Read-MutSccacheProbeErrorLog -SccachePath fixture-cache).Found
            $env:SCCACHE_ERROR_LOG = $null
            $log = Read-MutSccacheProbeErrorLog -SccachePath fixture-cache
            Assert-False $log.Found
            Assert-Equal 0 $log.Lines.Count
            Assert-Equal 4 $fixture.Calls.Count 'missing logs still stop the server'
        }.GetNewClosure()
    }.GetNewClosure()
}

Describe 'Sccache diagnostic child and backend setup' {
    It 'preserves detached launch settings, actual child streams/status and detects lost argv' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/diagnostics/Test-SccacheWrite.ps1' -FunctionName New-SccacheProbeProcessInfo `
            -Find '$info.ArgumentList.Add($argument)' -Replace '$null' -Expected 'argument order is preserved' -IncludeControl -Body { Assert-SccacheProcessInfo }
    }

    It 'stops before persistent backend changes and detects a configuration that reuses the old server' {
        $module = @{ ScriptPath = 'windows/scripts/diagnostics/Test-SccacheWrite.ps1'; FunctionName = @('Set-SccacheProbeConfiguration')
            FixtureState = (New-TestCallState); Prelude = @'
function Stop-SccacheProbeServer {
    param($SccachePath)
    $State.Calls.Add("$SccachePath|$env:SCCACHE_MULTILEVEL_CHAIN|$env:SCCACHE_WEBDAV_ENDPOINT|$env:SCCACHE_DIR")
    $global:LASTEXITCODE = 0
}
'@ }
        Invoke-TestFunctionMutations -ModuleArguments $module -IncludeControl -Find 'Stop-SccacheProbeServer -SccachePath $SccachePath' -Replace '' `
            -Expected 'the server stops before configuration changes' -Body { param($state) Assert-SccacheConfiguration $state }
    }

    It 'keeps caller launch directories and explicit versus disk-only configuration distinct' {
        $path = 'windows/scripts/diagnostics/Test-SccacheWrite.ps1'
        $launches = @(Get-TestScriptCommands -ScriptPath $path -Name New-SccacheProbeProcessInfo)
        Assert-Equal 2 $launches.Count
        Assert-False (Get-TestCommandArguments -Command $launches[0]).ContainsKey('WorkingDirectory')
        Assert-True (Get-TestCommandArguments -Command $launches[1]).ContainsKey('WorkingDirectory')
        $configurations = @(Get-TestScriptCommands -ScriptPath $path -Name Set-SccacheProbeConfiguration)
        Assert-Equal 2 $configurations.Count
        Assert-True (Get-TestCommandArguments -Command $configurations[0]).ContainsKey('Chain')
        Assert-True (Get-TestCommandArguments -Command $configurations[0]).ContainsKey('Endpoint')
        Assert-False (Get-TestCommandArguments -Command $configurations[1]).ContainsKey('Chain')
        Assert-False (Get-TestCommandArguments -Command $configurations[1]).ContainsKey('Endpoint')
    }

    It 'shares flushed log evidence without merging empty/missing policies and detects a skipped flush' {
        $module = @{ ScriptPath = 'windows/scripts/diagnostics/Test-SccacheWrite.ps1'; FunctionName = @('Read-SccacheProbeErrorLog')
            FixtureState = (New-TestCallState @{ Append = $false }); Prelude = @'
function Stop-SccacheProbeServer {
    param($SccachePath, $Pattern)
    $State.Calls.Add("$SccachePath|$Pattern")
    if ($State.Append) { Add-Content -LiteralPath $env:SCCACHE_ERROR_LOG -Value 'flushed on stop' }
    $global:LASTEXITCODE = 0
}
'@ }
        Invoke-TestFunctionMutations -ModuleArguments $module -IncludeControl `
            -Find 'Stop-SccacheProbeServer -SccachePath $SccachePath -Pattern $StopPattern' -Replace '' `
            -Expected 'evidence reads after the server flushes' -Body { param($state) Assert-SccacheErrorLog $state }
    }
}
