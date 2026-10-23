#requires -Version 7.0
# The real GStreamer cargo scope runs over fake clone/cargo commands; Rust compilation and upstream network access are not covered.

function Assert-GstCargoEnvironment {
    param($State)
    $State.Calls.Clear()
    $State.CloneFailure = $false
    Invoke-WithEnv @{ GIT_SSL_NO_VERIFY = 'caller'; ANT_CARGO_SCOPE = $null } {
        $before = (Get-Location).Path
        Assert-Equal 19 (Invoke-MutGstCargoFixture) 'native cargo failure reaches the caller'
        Assert-False $State.Inside.TlsDisabled 'cargo TLS verification must be enabled'
        Assert-Equal cargo $State.Inside.Scope
        Assert-Equal $State.SourceDir $State.Inside.Directory
        Assert-Equal 'build|--locked|--config' ($State.Calls[0][0..2] -join '|')
        Assert-Equal 'mirror-config' ([IO.File]::ReadAllText($State.Calls[0][3]).Trim())
        Assert-Equal caller $env:GIT_SSL_NO_VERIFY
        Assert-False (Test-Path Env:ANT_CARGO_SCOPE) 'a previously absent variable remains absent'
        Assert-Equal $before (Get-Location).Path 'the cargo working directory is restored'
        $State.CloneFailure = $true
        Assert-Throws { Invoke-MutGstCargoFixture } -MessagePattern 'fixture clone failed'
        Assert-Equal caller $env:GIT_SSL_NO_VERIFY 'throwing before cargo still restores TLS policy'
        Assert-False (Test-Path Env:ANT_CARGO_SCOPE)
        Assert-Equal 1 $State.Calls.Count 'clone failure cannot start cargo'
    }.GetNewClosure()
}

Describe 'GStreamer cargo environment ownership' {
    It 'preserves native status, verified TLS, caller environment and location on native and clone failures' {
        $call = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -Name Invoke-WithProcessEnvironment)
        Assert-Equal 1 $call.Count
        $assignment = Get-TestAstAncestor -Node $call[0] -Type ([Management.Automation.Language.AssignmentStatementAst]) -First
        Assert-Equal '$cargoExit' $assignment.Left.Extent.Text
        $text = 'function Invoke-GstCargoFixture {' + @'
$resolvedBuildDir = $State.BuildDir
$rsSrcDir = $State.SourceDir
$rsEnv = [ordered]@{ GIT_SSL_NO_VERIFY = $null; ANT_CARGO_SCOPE = 'cargo' }
$rsPlan = @{ Args = @('build', '--locked'); Env = $rsEnv }
$GstVersion = 'fixture'
'@ + "`n" + $assignment.Extent.Text + '; $cargoExit }'
        Invoke-InTestDir -Files @{ 'src/Cargo.lock' = 'lock' } -Body { param($dir)
            $state = New-TestCallState @{ Code = 19; SourceDir = (Join-Path $dir src); BuildDir = (Join-Path $dir build); Inside = $null; CloneFailure = $false; Text = $text }
            Invoke-WithTestNativeCommand -Name cargo -FixtureState $state -Implementation { param($State, $ArgumentList)
                $State.Inside = @{ TlsDisabled = (Test-Path Env:GIT_SSL_NO_VERIFY); Scope = $env:ANT_CARGO_SCOPE; Directory = (Get-Location).Path }
                'compiler output'
            } -Body { param($state)
                $module = @{ Text = $state.Text; FunctionName = @('Invoke-GstCargoFixture'); FixtureState = $state; Prelude = @'
function Invoke-GitClone { param($RepoUrl, $Tag, $SourceDir) if ($State.CloneFailure) { throw 'fixture clone failed' } }
function Get-GstRustSourceMirrorConfig { param($CargoLock) 'mirror-config' }
function log { param($Text) }
'@ }
                Invoke-WithFunctionModule @module -Body { param($state) Assert-GstCargoEnvironment $state }
                Invoke-TestFunctionMutations -ModuleArguments $module -Find '-Environment $rsEnv' -Replace '-Environment @{}' -Expected 'cargo TLS verification must be enabled' -Body { param($state) Assert-GstCargoEnvironment $state }
            }
        }.GetNewClosure()
    }
}
