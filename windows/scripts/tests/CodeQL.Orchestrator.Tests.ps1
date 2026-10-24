#requires -Version 7.0
# Fake process and download seams keep failure policy testable without a CodeQL PE.

$script:codeQLFunctions = @(
    'Get-ForwardSwitchValue', 'Get-CodeQLDatabaseCreateArgs', 'Get-CodeQLTimeoutMinutes',
    'Resolve-CodeQLExecutable', 'Invoke-CodeQLPackDownloads', 'Get-CodeQLInnerCommand',
    'Invoke-CodeQLRunPhase', 'Initialize-CodeQLDatabaseCluster', 'Get-CodeQLAnalyzeArgs', 'Invoke-CodeQLLanguageAnalysis',
    'Invoke-CodeQLAnalyses', 'Invoke-BuildCodeQL'
)
$script:codeQLPrelude = @'
$script:CodeQLState = $State
function Write-BuildLog { param($Context, $Message) $script:CodeQLState.Logs.Add("info|$Message") }
function Write-BuildLogWarning { param($Context, $Message) $script:CodeQLState.Logs.Add("warn|$Message") }
function Write-BuildLogError { param($Context, $Message) $script:CodeQLState.Logs.Add("error|$Message") }
function Write-BuildLogSuccess { param($Context, $Message) $script:CodeQLState.Logs.Add("success|$Message") }
function Disable-SccacheForTrace { $script:CodeQLState.DisableCount++ }
function Invoke-CodeQLProcess {
    param($CodeQLExe, $Arguments, $Phase, $TimeoutMinutes)
    $script:CodeQLState.Processes.Add([pscustomobject]@{
        Exe = $CodeQLExe; Arguments = @($Arguments); Phase = $Phase; Timeout = $TimeoutMinutes
    })
    if ($script:CodeQLState.ExitCodes.ContainsKey($Phase)) { return $script:CodeQLState.ExitCodes[$Phase] }
    return 0
}
function Invoke-CodeQLPackDownload {
    param($CodeQLExe, $QueryPack)
    $script:CodeQLState.Packs.Add($QueryPack)
    if ($script:CodeQLState.PackCodes.ContainsKey($QueryPack)) { return $script:CodeQLState.PackCodes[$QueryPack] }
    return 0
}
function Invoke-DownloadWithRetry {
    param($Url, $DestinationPath, $ExpectSignature, $Description)
    $script:CodeQLState.Downloads.Add([pscustomobject]@{
        Url = $Url; Destination = $DestinationPath; Signature = $ExpectSignature; Description = $Description
    })
    if ($script:CodeQLState.DownloadFailure) { throw 'fixture download failed' }
    [IO.File]::WriteAllText($DestinationPath, 'PK fixture')
}
function Expand-Archive {
    param($Path, $DestinationPath, [switch]$Force)
    $script:CodeQLState.Expansions++
    & ($script:CodeQLState.InstallExecutable) $DestinationPath
}
function Get-CodeScanningPathsIgnore { param($ConfigPath) return @('generated/**') }
function Remove-SarifIgnoredResult {
    param($SarifPath, $IgnoredPaths)
    $script:CodeQLState.Filters.Add([pscustomobject]@{ Path = $SarifPath; Ignored = @($IgnoredPaths) })
    return 2
}
'@
$script:codeQLPrelude += "`n" + (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsBuild.Common.psm1' -FunctionName @('Write-BuildLogMessages')).ToString()

function New-CodeQLState {
    param([string]$Workspace, [bool]$Installed = $true)
    $installer = {
        param([string]$CliDir)
        $bin = Join-Path $CliDir 'codeql'
        $null = New-Item -ItemType Directory -Force -Path $bin
        [IO.File]::WriteAllText((Join-Path $bin 'codeql.exe'), 'fixture executable')
    }
    if ($Installed) { & $installer (Join-Path $Workspace 'codeql-cli') }
    return [pscustomobject]@{
        Workspace = $Workspace
        Processes = [Collections.Generic.List[object]]::new()
        Downloads = [Collections.Generic.List[object]]::new()
        Packs = [Collections.Generic.List[string]]::new()
        Logs = [Collections.Generic.List[string]]::new()
        Filters = [Collections.Generic.List[object]]::new()
        ExitCodes = @{}
        PackCodes = @{}
        RunOptions = $null
        InstallExecutable = $installer
        DownloadFailure = $false
        DisableCount = 0
        Expansions = 0
    }
}

function Invoke-CodeQLFixture {
    param([scriptblock]$Body, [bool]$Installed = $true)
    $case = $Body
    Invoke-InTestDir { param($dir)
        $state = New-CodeQLState -Workspace $dir -Installed $Installed
        & $case $state $dir
    } -Prefix 'codeql-orchestrator-'
}

function Invoke-TestCodeQLBuild {
    param([pscustomobject]$State, [hashtable]$Forward = @{}, [string[]]$Languages = @('cpp', 'rust'),
        [string]$Config = '', [string]$Find = '', [string]$Replace = '')
    $State.RunOptions = [pscustomobject]@{ Forward = $Forward; Languages = $Languages; Config = $Config }
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsCodeQL.Common.psm1' -FunctionName $script:codeQLFunctions -Prelude $script:codeQLPrelude -FixtureState $State -Find $Find -Replace $Replace -Body { param($state)
        $options = $state.RunOptions
        Invoke-MutBuildCodeQL -Context ([pscustomobject]@{}) -Workspace $state.Workspace -ForwardParameters $options.Forward -BuildScriptPath (Join-Path $state.Workspace 'My Build.ps1') -Languages $options.Languages -CodeScanningConfig $options.Config
    }
}

function Assert-CodeQLPhases {
    param([pscustomobject]$State, [string]$Expected)
    Assert-Equal $Expected (($State.Processes | ForEach-Object Phase) -join ',')
}

Describe 'Invoke-BuildCodeQL orchestration' {
    It 'creates a scoped database and analyzes both languages with the quoted forwarded command' {
        Invoke-CodeQLFixture { param($state, $dir)
            $config = Join-Path $dir 'codeql.yml'
            [IO.File]::WriteAllText($config, ('paths-ignore:' + [Environment]::NewLine + '  - generated/**'))
            Invoke-WithEnv @{ CODEQL_TIMEOUT_MINUTES = '27' } {
                Invoke-TestCodeQLBuild -State $state -Forward @{ CodeQL = $true; Configuration = 'Release win'; CleanCodeQLDb = $false } -Config $config
            }
            Assert-CodeQLPhases -State $state -Expected 'database create,analyze cpp,analyze rust'
            Assert-Equal 1 $state.DisableCount
            Assert-Equal 0 $state.Downloads.Count
            Assert-Equal 0 $state.Packs.Count
            Assert-True (@($state.Processes | Where-Object { $_.Timeout -ne 27 }).Count -eq 0) 'every process uses the configured timeout'
            $create = $state.Processes[0].Arguments
            Assert-True ($create -contains "--codescanning-config=$config") 'database creation receives the config'
            Assert-True ($create -contains '--language=cpp') 'cpp is traced'
            Assert-True ($create -contains '--language=rust') 'rust is traced'
            $command = @($create | Where-Object { $_ -like '--command=*' })[0]
            Assert-Match '"[^"]*My Build.ps1"' $command 'build script path stays quoted'
            Assert-Match '"Release win"' $command 'forwarded value stays quoted'
            Assert-False ($command -match '-CodeQL(?:\s|$)') 'the inner build must not recurse into CodeQL'
            Assert-Equal 2 $state.Filters.Count 'both SARIF files are filtered'
            Assert-True (Test-Path -LiteralPath (Join-Path $dir 'logs\codeql-results')) 'result directory exists'
        }
    }

    It 'fails immediately when database creation fails' {
        Invoke-CodeQLFixture { param($state, $dir)
            $state.ExitCodes['database create'] = 7
            Assert-Throws { Invoke-TestCodeQLBuild -State $state } -MessagePattern 'CodeQL Database Cluster creation failed'
            Assert-Equal 1 $state.Processes.Count 'analysis cannot run against a failed database'
            Assert-Equal 'database create' $state.Processes[0].Phase
        }
    }

    It 'retries a failed security suite with the basic pack and continues to the next language' {
        Invoke-CodeQLFixture { param($state, $dir)
            $state.ExitCodes['analyze cpp'] = 5
            Invoke-TestCodeQLBuild -State $state
            Assert-CodeQLPhases -State $state -Expected 'database create,analyze cpp,analyze cpp (pack),analyze rust'
            Assert-True ($state.Processes[1].Arguments -contains 'codeql/cpp-queries:codeql-suites/cpp-security-and-quality.qls') 'security suite attempted first'
            Assert-True ($state.Processes[2].Arguments -contains 'codeql/cpp-queries') 'basic pack used on retry'
            Assert-True ($state.Logs -contains 'warn|Analysis with query suite failed for cpp, trying with query pack...') 'the fallback is visible'
        }
    }

    It 'tries every language but fails with all fallback failures named' {
        Invoke-CodeQLFixture { param($state, $dir)
            foreach ($phase in @('analyze cpp', 'analyze cpp (pack)', 'analyze rust', 'analyze rust (pack)')) { $state.ExitCodes[$phase] = 2 }
            Assert-Throws { Invoke-TestCodeQLBuild -State $state } -MessagePattern 'analysis failed for language\(s\): cpp, rust'
            Assert-Equal 5 $state.Processes.Count 'both languages get both attempts'
            Assert-False ($state.Logs -contains 'success|=== CodeQL Analysis Complete ===') 'partial results cannot report success'
        }
    }

    It 'reuses a database without disabling sccache or validating a new config' {
        Invoke-CodeQLFixture { param($state, $dir)
            $cluster = Join-Path $dir 'codeql-db-cluster'
            $null = New-Item -ItemType Directory -Path $cluster
            Invoke-TestCodeQLBuild -State $state -Config (Join-Path $state.Workspace 'missing.yml')
            Assert-CodeQLPhases -State $state -Expected 'analyze cpp,analyze rust'
            Assert-Equal 0 $state.DisableCount
            Assert-True ($state.Logs -contains 'info|Skipping database creation and reusing existing CodeQL DB cluster (a code-scanning config applies only to a new one: -CleanCodeQLDb).') 'reuse scope is visible'
        }
    }

    It 'cleans an existing database before tracing and forwards overwrite' {
        Invoke-CodeQLFixture { param($state, $dir)
            $cluster = Join-Path $dir 'codeql-db-cluster'
            $null = New-Item -ItemType Directory -Path $cluster
            [IO.File]::WriteAllText((Join-Path $cluster 'old.txt'), 'old')
            Invoke-TestCodeQLBuild -State $state -Forward @{ CleanCodeQLDb = $true }
            Assert-Equal 1 $state.DisableCount
            Assert-Equal 'database create' $state.Processes[0].Phase
            Assert-True ($state.Processes[0].Arguments -contains '--overwrite') 'clean runs overwrite'
            Assert-False (Test-Path -LiteralPath (Join-Path $cluster 'old.txt')) 'stale cluster is gone'
        }
    }

    It 'treats a failed query pack download as advisory and passes download to both analyze attempts' {
        Invoke-CodeQLFixture { param($state, $dir)
            $state.PackCodes['codeql/cpp-queries'] = 9
            $state.ExitCodes['analyze cpp'] = 1
            Invoke-TestCodeQLBuild -State $state -Forward @{ CodeQLDownload = $true }
            Assert-Equal 'codeql/cpp-queries,codeql/rust-queries' ($state.Packs -join ',')
            Assert-True ($state.Logs -contains 'warn|Failed to download codeql/cpp-queries, continuing...') 'pack failure is advisory'
            Assert-True (@($state.Processes | Where-Object { $_.Phase -like 'analyze *' -and $_.Arguments -notcontains '--download' }).Count -eq 0) 'every analysis attempt may download its query'
            Assert-True ($state.Logs -contains 'success|=== CodeQL Analysis Complete ===') 'fallback success completes the run'
        }
    }

    It 'downloads the pinned CLI with a PK guard when absent' {
        Invoke-CodeQLFixture -Installed $false { param($state, $dir)
            Invoke-WithEnv @{ CODEQL_VERSION = 'v2.18.4' } {
                Invoke-TestCodeQLBuild -State $state -Languages @('cpp')
            }
            Assert-Equal 1 $state.Downloads.Count
            Assert-Match '/v2\.18\.4/codeql-win64\.zip$' $state.Downloads[0].Url
            Assert-Equal 'PK' $state.Downloads[0].Signature
            Assert-Equal 1 $state.Expansions
            Assert-Equal 2 $state.Processes.Count 'create and analysis follow extraction'
        }
    }

    It 'stops before creating a database when the CLI download fails' {
        Invoke-CodeQLFixture -Installed $false { param($state, $dir)
            $state.DownloadFailure = $true
            Assert-Throws { Invoke-TestCodeQLBuild -State $state } -MessagePattern 'fixture download failed'
            Assert-Equal 1 $state.Downloads.Count
            Assert-Equal 0 $state.Expansions
            Assert-Equal 0 $state.Processes.Count
        }
    }

    It 'rejects a mutation that suppresses the database failure' {
        Invoke-CodeQLFixture { param($state, $dir)
            $state.ExitCodes['database create'] = 7
            Assert-Throws {
                Assert-Throws {
                    Invoke-TestCodeQLBuild -State $state -Find '$succeeded = 0 -eq (Invoke-CodeQLProcess -CodeQLExe $Run.CodeQLExe -Arguments $Arguments -Phase $Phase -TimeoutMinutes $Run.TimeoutMinutes)' -Replace '$succeeded = $true'
                } -MessagePattern 'CodeQL Database Cluster creation failed'
            } -MessagePattern 'expected an exception but none was thrown'
        }
    }
}
