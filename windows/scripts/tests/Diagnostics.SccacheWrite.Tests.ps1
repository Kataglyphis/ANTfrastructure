#requires -Version 7.0
# Stubbed sccache commands verify probe orchestration, not real cache writes or BuildKit mounts.

function Get-SccacheProbeFixtureSource {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../diagnostics/Test-SccacheWrite.ps1'))
    $renderer = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsDiagnostics.Common.psm1' -FunctionName Write-DiagnosticResult).ToString()
    return $source + "`n" + $renderer
}

function Invoke-SccacheProbeFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Find = '', [string]$Replace = '', [string]$Expected = '')
    $text = Get-SccacheProbeFixtureSource
    $functions = @('Write-DiagnosticResult', 'Write-SccacheRenameProbe', 'Write-SccacheProbeEntries', 'Stop-SccacheProbeServer', 'Start-SccacheProbeServer', 'Get-SccacheProbeStats', 'Write-SccacheProbeSource', 'Invoke-SccacheProbeCompile')
    $recipe = @{ Text = $text; FunctionName = $functions; BodyArgumentList = @($Body) }
    $exercise = { param($caseBody)
        Invoke-InTestDir { param($dir)
            $callback = $caseBody
            $fake = Join-Path $dir 'sccache.ps1'
            [IO.File]::WriteAllText($fake, @'
param([string]$Command, [Parameter(ValueFromRemainingArguments)][string[]]$OtherArgs)
Add-Content $env:WBT_PROBE_CALLS "$Command|$((Get-Location).Path)$(if ($OtherArgs) { '|' + ($OtherArgs -join '|') })"
if ($Command -eq '--start-server') {
    if ($env:WBT_PROBE_THROW) { throw 'fixture start failed' }
    'Listening on test port'; 'error: fixture message'; 'irrelevant chatter'
}
if ($Command -eq '--stop-server') { 'Stopping fixture'; 'error: stop fixture'; 'irrelevant stop' }
if ($Command -eq '--show-stats' -and $env:WBT_PROBE_STATS) { Get-Content $env:WBT_PROBE_STATS }
if ($Command -eq 'clang-cl') { 'DEBUG noise'; 'TRACE detail'; 'compiler warning' }
$global:LASTEXITCODE = if ($env:WBT_PROBE_EXIT) { [int]$env:WBT_PROBE_EXIT } else { 17 }
'@)
            Invoke-WithEnv @{ WBT_PROBE_CALLS = (Join-Path $dir 'calls.txt'); WBT_PROBE_STATS = (Join-Path $dir 'stats.txt'); WBT_PROBE_THROW = $null; WBT_PROBE_EXIT = $null } {
                & $callback $fake $dir
            }.GetNewClosure()
        }.GetNewClosure()
    }
    if ($Expected) { Invoke-TestFunctionMutations -ModuleArguments $recipe -Find $Find -Replace $Replace -Expected $Expected -Body $exercise }
    else { Invoke-WithFunctionModule @recipe -Body $exercise }
}

Describe 'Sccache write probe shared lifecycle' {
    It 'writes different compiled tokens and forwards source/object paths with the existing compiler and log policies' {
        Invoke-SccacheProbeFixture { param($fake, $dir)
            $source = Join-Path $dir 'source with spaces.cpp'
            Write-MutSccacheProbeSource -Path $source -Value 42
            $first = [IO.File]::ReadAllText($source)
            Write-MutSccacheProbeSource -Path $source -Value 42
            $second = [IO.File]::ReadAllText($source)
            Assert-False ($first -eq $second)
            Assert-Match 'int probe_value_[0-9a-f]{32}\(\) \{ return 42; \}' $second
            $object = Join-Path $dir 'object with spaces.obj'
            $location = (Get-Location).Path
            Invoke-WithEnv @{ WBT_PROBE_EXIT = '0' } {
                $records = @(Invoke-MutSccacheProbeCompile -SccachePath $fake -Source $source -Object $object 6>&1)
                Assert-True $records[-1]
                $output = $records[0..($records.Count - 2)] | Out-String
                Assert-Match 'compiler warning' $output
                Assert-Match 'TRACE detail' $output
                Assert-False ($output.Contains('DEBUG noise'))
            }.GetNewClosure()
            $records = @(Invoke-MutSccacheProbeCompile -SccachePath $fake -Source $source -Object $object -IgnoredPattern 'DEBUG|INFO |TRACE' 6>&1)
            Assert-False $records[-1]
            Assert-False (($records | Out-String).Contains('TRACE detail'))
            Assert-Equal $location (Get-Location).Path
            Assert-Equal ("clang-cl|$dir|/c|/nologo|/EHsc|/Fo$object|$source") @(Get-Content $env:WBT_PROBE_CALLS)[0]
        }
    }

    It 'starts from the root, restores the caller location, and preserves absent, empty and configured levels' {
        Invoke-SccacheProbeFixture { param($fake, $dir)
            foreach ($chain in $null, '', 'disk,webdav') {
                Invoke-WithEnv @{ SCCACHE_MULTILEVEL_CHAIN = $chain } {
                    Push-Location $dir
                    try {
                        $output = Start-MutSccacheProbeServer -SccachePath $fake 6>&1 | Out-String
                        Assert-Equal $dir (Get-Location).Path
                    } finally { Pop-Location }
                    Assert-Equal 0 $global:LASTEXITCODE
                    Assert-Equal ($null -ne $chain) (Test-Path Env:SCCACHE_MULTILEVEL_CHAIN)
                    Assert-Equal $chain ([Environment]::GetEnvironmentVariable('SCCACHE_MULTILEVEL_CHAIN'))
                    Assert-Match 'start\| Listening' $output
                    Assert-Match 'start\| error:' $output
                    Assert-False ($output.Contains('irrelevant chatter'))
                }.GetNewClosure()
            }
            $calls = @(Get-Content $env:WBT_PROBE_CALLS)
            Assert-Equal 6 $calls.Count
            for ($i = 0; $i -lt $calls.Count; $i += 2) {
                Assert-Equal '--start-server|C:\' $calls[$i]
                Assert-Equal ("--zero-stats|$dir") $calls[$i + 1]
            }
            $output = Start-MutSccacheProbeServer -SccachePath $fake -Pattern 'Listening' 6>&1 | Out-String
            Assert-Match 'Listening' $output
            Assert-False ($output.Contains('error:'))
        }
    }

    It 'restores the caller location when startup throws before zeroing statistics' {
        Invoke-SccacheProbeFixture { param($fake, $dir)
            Invoke-WithEnv @{ WBT_PROBE_THROW = '1' } {
                Push-Location $dir
                try {
                    Assert-Throws { Start-MutSccacheProbeServer -SccachePath $fake } -MessagePattern 'fixture start failed'
                    Assert-Equal $dir (Get-Location).Path
                    Assert-Equal 1 @(Get-Content $env:WBT_PROBE_CALLS).Count
                } finally { Pop-Location }
            }.GetNewClosure()
        }
    }

    It 'stops with unchanged quiet or filtered output and resets native exit status' {
        Invoke-SccacheProbeFixture { param($fake, $dir)
            Assert-Equal 0 @(Stop-MutSccacheProbeServer -SccachePath $fake 6>&1).Count
            Assert-Equal 0 $global:LASTEXITCODE
            $lines = @(Stop-MutSccacheProbeServer -SccachePath $fake -Pattern 'Stopping|error' 6>&1 | ForEach-Object { "$_" })
            Assert-Equal '  stop| Stopping fixture|  stop| error: stop fixture' ($lines -join '|') 'filtered stop output retains exact order and prefixes'
            Assert-Equal 0 $global:LASTEXITCODE
            Assert-Equal ("--stop-server|$((Get-Location).Path)") @(Get-Content $env:WBT_PROBE_CALLS)[0]
        }
    }

    It 'retains first counters, missing-stat sentinels, size text and each mode display policy' {
        Invoke-SccacheProbeFixture { param($fake, $dir)
            [IO.File]::WriteAllLines($env:WBT_PROBE_STATS, @('Compile requests 8', 'Cache misses 7', 'Cache misses 90',
                'Cache write errors 3', 'Cache write errors 99', 'Cache size 12 MiB', 'Cache size 20 MiB', 'write failures: detail'))
            $records = @(Get-MutSccacheProbeStats -SccachePath $fake 6>&1)
            $stats = $records[-1]
            Assert-Equal 7 $stats.Misses
            Assert-Equal 3 $stats.WriteErrors
            Assert-Equal 'Cache size 12 MiB' $stats.CacheSize
            $display = $records[0..($records.Count - 2)] | Out-String
            Assert-Match 'write failures: detail' $display
            Assert-False ($display.Contains('Compile requests'))
            Assert-Equal 0 $global:LASTEXITCODE
            $records = @(Get-MutSccacheProbeStats -SccachePath $fake -Pattern 'Compile requests' 6>&1)
            Assert-Equal 2 $records.Count
            Assert-Match 'Compile requests 8' $records[0]
            Assert-Equal 1 @(Get-MutSccacheProbeStats -SccachePath $fake -Pattern '' 6>&1).Count
            [IO.File]::WriteAllText($env:WBT_PROBE_STATS, 'unrecognized stats')
            $stats = Get-MutSccacheProbeStats -SccachePath $fake
            Assert-Equal -1 $stats.Misses
            Assert-Equal -1 $stats.WriteErrors
            Assert-Equal '' $stats.CacheSize
        }
    }
}

function Assert-SccacheRenameProbeFixture {
    param([string]$Command = 'Write-MutSccacheRenameProbe')
    Invoke-InTestDir { param($dir)
        $source = Join-Path $dir 'source [1].tmp'
        $destination = Join-Path $dir 'destination [1].bin'
        $output = & $Command -Source $source -Destination $destination -Name 'fixture move' 6>&1 | Out-String
        Assert-True (Test-Path -LiteralPath $destination) 'rename must move the file'
        Assert-False (Test-Path -LiteralPath $source)
        Assert-Equal 64 (Get-Item -LiteralPath $destination).Length
        Assert-Equal '1,64' (([IO.File]::ReadAllBytes($destination)[0,-1]) -join ',')
        Assert-Match '\[ OK \] fixture move' $output
        $missingDestination = Join-Path $dir 'absent/destination.bin'
        foreach ($cleanup in $false, $true) {
            $output = & $Command -Source $source -Destination $missingDestination -Name 'failed move' -CleanupSourceOnFailure:$cleanup 6>&1 | Out-String
            Assert-Match '\[FAIL\] failed move' $output
            Assert-Equal (-not $cleanup) (Test-Path -LiteralPath $source) 'only the system-temp probe removes a failed source'
        }
    }.GetNewClosure()
}

Describe 'Sccache raw rename evidence' {
    It 'preserves staged bytes, verdicts and distinct failure cleanup policies' {
        Invoke-SccacheProbeFixture { Assert-SccacheRenameProbeFixture }
    }

    It 'rejects skipped renames' {
        Invoke-SccacheProbeFixture -Find '[IO.File]::Move($Source, $Destination)' -Replace '' -Expected 'rename must move the file' -Body { Assert-SccacheRenameProbeFixture }
    }

    It 'rejects lost failure cleanup' {
        Invoke-SccacheProbeFixture -Find 'Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue' -Replace '' -Expected 'only the system-temp probe' -Body { Assert-SccacheRenameProbeFixture }
    }
}

Describe 'Sccache directory evidence rendering' {
    It 'preserves entry order, file sizes and directory markers without requiring directory length' {
        Invoke-SccacheProbeFixture {
            $entries = @(
                [pscustomobject]@{ PSIsContainer = $false; Name = 'first.bin'; Length = 3 }
                [pscustomobject]@{ PSIsContainer = $true; Name = 'folder' }
                [pscustomobject]@{ PSIsContainer = $false; Name = 'empty.bin'; Length = 0 }
            )
            $lines = @(Write-MutSccacheProbeEntries -Entry $entries 6>&1 | ForEach-Object { "$_" })
            Assert-Equal '    FILE first.bin (3 bytes)|    DIR  folder|    FILE empty.bin (0 bytes)' ($lines -join '|')
            Assert-Equal 0 @(Write-MutSccacheProbeEntries -Entry @() 6>&1).Count
        }
    }
}
