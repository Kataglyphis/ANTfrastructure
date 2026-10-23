#requires -Version 7.0
# Fake 7-Zip covers extraction order, policies and failures; it does not validate real archive contents.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsMigraphx.Common.psm1') -Force -DisableNameChecking

function Invoke-SourceArchiveFixture {
    param([Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][scriptblock]$Body)
    $action = $Body
    Invoke-InTestDir { param($dir)
        $destination = Join-Path $dir 'out tree'
        $null = New-Item -ItemType Directory -Path $destination
        $fixture = [pscustomobject]@{
            Archive = Join-Path $dir 'source archive.tar.gz'; Destination = $destination
            Tar = Join-Path $destination 'source.tar'; Source = Join-Path $destination 'source'
            Log = Join-Path $dir '7z.log'
        }
        $null = New-TestBatchTool -Directory $dir -Name '7z.bat' -Line @(
            'echo %~2>> "%WBT_ARCHIVE_LOG%"',
            'if "%WBT_ARCHIVE_MODE%"=="first-error" ( echo ERROR: Cannot open archive & exit /b 7 )',
            'if "%~x2"==".tar" goto tar',
            'if "%WBT_ARCHIVE_MODE%"=="zip" goto source',
            'echo tar > "%WBT_ARCHIVE_DEST%\source.tar"',
            'exit /b 0',
            ':tar',
            'if "%WBT_ARCHIVE_MODE%"=="second-error" ( echo ERROR: Data Error : bad.c & exit /b 2 )',
            'if "%WBT_ARCHIVE_MODE%"=="empty" exit /b 0',
            ':source',
            'mkdir "%WBT_ARCHIVE_DEST%\source"',
            'if "%WBT_ARCHIVE_MODE%"=="dangerous" ( echo ERROR: Dangerous link path was ignored : source\link : ..\target & exit /b 2 )',
            'if "%WBT_ARCHIVE_MODE%"=="mixed" ( echo ERROR: Dangerous link path was ignored : source\link : ..\target & echo ERROR: Data Error : bad.c & exit /b 2 )'
        )
        $fixtureAction = $action
        Invoke-WithEnv @{ PATH = "$dir;$env:PATH"; WBT_ARCHIVE_LOG = $fixture.Log; WBT_ARCHIVE_MODE = $Mode; WBT_ARCHIVE_DEST = $destination } {
            & $fixtureAction $fixture
        }.GetNewClosure()
    }.GetNewClosure()
}

function Assert-SourceArchiveFailure {
    param([string]$Command = 'Expand-SourceTarball', [string]$Mode, [string]$Pattern, [int]$Calls)
    Invoke-SourceArchiveFixture -Mode $Mode -Body {
        param($fixture)
        Assert-Throws { & $Command -Archive $fixture.Archive -Destination $fixture.Destination } -MessagePattern $Pattern
        Assert-Equal $Calls @(Get-Content -LiteralPath $fixture.Log).Count 'extraction stopped at the failed pass'
    }.GetNewClosure()
}

function Assert-SourceArchiveCleanup {
    param([string]$Command = 'Expand-SourceTarball')
    Invoke-SourceArchiveFixture -Mode tar -Body {
        param($fixture)
        $root = & $Command -Archive $fixture.Archive -Destination $fixture.Destination -RemoveIntermediateTar
        Assert-Equal $fixture.Source $root
        Assert-False (Test-Path -LiteralPath $fixture.Tar) 'the intermediate tar must be removed'
    }.GetNewClosure()
}

Describe 'Source archive extraction' {
    It 'extracts a zip once and returns only the source root' {
        Invoke-SourceArchiveFixture -Mode zip -Body {
            param($fixture)
            $root = @(Expand-SourceTarball -Archive $fixture.Archive -Destination $fixture.Destination)
            Assert-Equal 1 $root.Count
            Assert-Equal $fixture.Source $root[0]
            Assert-Equal $fixture.Archive (Get-Content -LiteralPath $fixture.Log)
        }
    }

    It 'extracts the inner tar second and preserves it by default' {
        Invoke-SourceArchiveFixture -Mode tar -Body {
            param($fixture)
            Assert-Equal $fixture.Source (Expand-SourceTarball -Archive $fixture.Archive -Destination $fixture.Destination)
            Assert-True (Test-Path -LiteralPath $fixture.Tar)
            Assert-Equal ($fixture.Archive + '|' + $fixture.Tar) ((Get-Content -LiteralPath $fixture.Log) -join '|')
        }
    }

    It 'removes the intermediate tar only when requested' { Assert-SourceArchiveCleanup }

    It 'fails immediately on either extraction pass and preserves its diagnostic' {
        Assert-SourceArchiveFailure -Mode first-error -Pattern '7z extraction.*exit 7.*Cannot open archive' -Calls 1
        Assert-SourceArchiveFailure -Mode second-error -Pattern '7z tar extraction.*exit 2.*Data Error' -Calls 2
    }

    It 'requires a source directory even after two clean extraction passes' {
        Assert-SourceArchiveFailure -Mode empty -Pattern 'Failed to locate extracted source directory' -Calls 2
    }

    It 'refuses dangerous links under the default strict policy' {
        Assert-SourceArchiveFailure -Mode dangerous -Pattern '7z tar extraction.*exit 2.*Dangerous link' -Calls 2
    }

    It 'lets the pinned policy skip only named dangerous links and warns once' {
        Invoke-SourceArchiveFixture -Mode dangerous -Body {
            param($fixture)
            $records = @(Expand-PinnedArchive -Archive $fixture.Archive -Destination $fixture.Destination 3>&1)
            Assert-Equal 2 $records.Count
            Assert-True ($records[0] -is [Management.Automation.WarningRecord])
            Assert-Match '1 in-tree link.*source\\link' $records[0].Message
            Assert-Equal $fixture.Source $records[1]
            Assert-False (Test-Path -LiteralPath $fixture.Tar)
        }
    }

    It 'keeps mixed errors fatal even under the pinned policy' {
        Assert-SourceArchiveFailure -Command Expand-PinnedArchive -Mode mixed -Pattern 'Data Error : bad.c' -Calls 2
        Assert-SourceArchiveFailure -Command Expand-PinnedArchive -Mode first-error -Pattern 'exit 7.*Cannot open archive' -Calls 1
    }

    It 'detects extraction-verdict and cleanup mutants' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSourceBuild.Common.psm1'))
        foreach ($case in @(
            @{ Find = 'elseif ($LASTEXITCODE -ne 0)'; Replace = 'elseif ($false)'; Check = { param($command) Assert-SourceArchiveFailure -Command $command -Mode second-error -Pattern '7z tar extraction.*Data Error' -Calls 2 } },
            @{ Find = 'if ($pass -eq 2 -and $RemoveIntermediateTar)'; Replace = 'if ($false)'; Check = { param($command) Assert-SourceArchiveCleanup -Command $command } }
        )) {
            Invoke-WithFunctionModule -Text $text -FunctionName Expand-SourceTarball -Find $case.Find -Replace $case.Replace -Body {
                & $case.Check Expand-SourceTarball
                Assert-Throws { & $case.Check Expand-MutSourceTarball } -MessagePattern 'Assert-'
            }
        }
    }
}
