#requires -Version 7.0
# Synthetic probes cover health verdicts and cross skips without executing installed tools or the full healthcheck.

function Invoke-HealthVersionFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [switch]$StaleExitMutant)
    $fixtureBody = $Body
    $source = (Get-ScriptFunctionDefinition -ScriptPath windows/scripts/build/Test-Health.ps1 -FunctionName Check, Invoke-HealthToolVersion).ToString()
    $prelude = @'
param($State)
$script:probeState = $State
$script:failed = $false
function Resolve-ToolPath {
    param($BinEnvVar, $ExeName)
    $script:probeState.Lookups++
    $script:probeState.Environment = $BinEnvVar
    $script:probeState.Executable = $ExeName
    if ($script:probeState.Missing) { return $null }
    return {
        param($argument)
        $script:probeState.Argument = $argument
        if ($null -ne $script:probeState.ExitCode) { $global:LASTEXITCODE = $script:probeState.ExitCode }
        $script:probeState.Output
    }
}
function Get-HealthFixtureFailure { $script:failed }
'@
    Invoke-InTestDir { param($dir)
        $state = @{ Lookups = 0; Missing = $false; ExitCode = 0; Output = 'version output' }
        $options = @{ Text = $source; Dir = $dir; Prelude = $prelude; ArgumentList = @($state) }
        if ($StaleExitMutant) { $options.Find = '$global:LASTEXITCODE = $null'; $options.Replace = '$global:LASTEXITCODE = 0' }
        $module = Import-FunctionModule @options
        try { & $fixtureBody $state } finally { Remove-Module $module -Force }
    }.GetNewClosure()
}

Describe 'Health tool version probes' {
    It 'preserves each tool argument, missing-tool diagnostics, cross skips and fatal output/exit verdicts' {
        foreach ($tool in @(
            @{ Label = 'ffmpeg --version'; BinEnvVar = 'FFMPEG_BIN'; ExeName = 'ffmpeg.exe'; VersionArgument = '-version' },
            @{ Label = 'gst-launch-1.0 --version'; BinEnvVar = 'GSTREAMER_BIN'; ExeName = 'gst-launch-1.0.exe'; VersionArgument = '--version' }
        )) {
            foreach ($mode in 'success', 'missing', 'empty', 'nonzero', 'cross', 'stale') {
                Invoke-HealthVersionFixture -Body { param($state)
                    $state.Missing = $mode -eq 'missing'
                    if ($mode -eq 'empty') { $state.Output = '' }
                    if ($mode -eq 'nonzero') { $state.ExitCode = 7 }
                    if ($mode -eq 'stale') { $state.ExitCode = $null }
                    $global:LASTEXITCODE = 0
                    $output = Invoke-MutHealthToolVersion @tool -Cross:($mode -eq 'cross') 6>&1 | Out-String
                    Assert-Equal ($mode -notin @('success', 'cross')) (Get-MutHealthFixtureFailure) "$($tool.Label) $mode verdict"
                    Assert-Equal $(if ($mode -eq 'cross') { 0 } else { 1 }) $state.Lookups 'cross lanes must not resolve or execute payload tools'
                    if ($mode -eq 'cross') { Assert-Match "\[SKIP\].*$([regex]::Escape($tool.ExeName)) is aarch64" $output }
                    elseif ($mode -eq 'missing') { Assert-Match ([regex]::Escape("$($tool.ExeName) not found ($($tool.BinEnvVar) env var unset and $($tool.ExeName) not on PATH)")) $output }
                    else {
                        Assert-Equal $tool.VersionArgument $state.Argument 'the actual version flag is tool-specific'
                        Assert-Equal $tool.BinEnvVar $state.Environment 'the environment override is tool-specific'
                        if ($mode -eq 'nonzero') { Assert-Match 'exit code \[7\]' $output }
                    }
                }.GetNewClosure()
            }
        }
    }

    It 'catches a reset to stale success when a probe never sets a native exit code (mutation)' {
        Invoke-HealthVersionFixture -StaleExitMutant -Body { param($state)
            $state.ExitCode = $null
            $global:LASTEXITCODE = 0
            $null = Invoke-MutHealthToolVersion -Label 'ffmpeg --version' -BinEnvVar FFMPEG_BIN -ExeName ffmpeg.exe -VersionArgument '-version' 6>&1
            Assert-Throws { Assert-True (Get-MutHealthFixtureFailure) 'an unset native exit must fail' } -MessagePattern 'an unset native exit must fail'
        }
    }
}
