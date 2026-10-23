#requires -Version 7.0
# A real Windows batch command covers native argv, streams and status; shell portability and CMake execution belong to separate suites.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1') -ErrorAction Stop

function New-NativeBuildTransportFixture {
    param($Root)
    $tool = New-TestBatchTool -Directory $Root -Name 'copy [args].cmd' -ExitCode 7 -Line @('echo first', 'echo.', '1>&2 echo native-error', 'echo ARG1=[%~1] ARG2=[%~2]')
    return @{ ScriptPath = 'windows/scripts/modules/WindowsBuild.Common.psm1'; FunctionName = @('Write-BuildCommandOutput', 'Invoke-BuildExternal')
        FixtureState = (New-TestCallState @{ Tool = $tool; Logs = [Collections.Generic.List[string]]::new() })
        Prelude = 'function Write-BuildLog { param($Context, $Message) $State.Logs.Add($Message) }' }
}

function Assert-NativeBuildTransport {
    param($State)
    $context = [pscustomobject]@{}
    foreach ($sample in @(@{ Value = @{}; Expected = 'ARG1=[] ARG2=[]' }, @{ Value = ''; Expected = 'ARG1=[] ARG2=[]' },
            @{ Value = @(); Expected = 'ARG1=[] ARG2=[]' }, @{ Value = @('a b', 'second'); Expected = 'ARG1=[a b] ARG2=[second]' })) {
        $State.Logs.Clear()
        $global:LASTEXITCODE = 37
        Assert-Equal 7 (Invoke-MutBuildExternal -Context $context -File $State.Tool -Parameters $sample.Value -IgnoreExitCode)
        Assert-Equal 37 $global:LASTEXITCODE 'the caller native status survives'
        Assert-True ($State.Logs.Contains($sample.Expected)) 'native argv must preserve empty calls and supplied values'
        Assert-True ($State.Logs.Contains('first')) 'stdout remains logged'
        Assert-True ($State.Logs.Contains('native-error')) 'stderr remains logged'
        Assert-False ($State.Logs.Contains('')) 'blank output is retained only in failure evidence'
    }
    $failure = ''
    try { Invoke-MutBuildExternal -Context $context -File $State.Tool -Parameters @{} } catch { $failure = $_.Exception.Message }
    Assert-Match 'exit code 7' $failure
    foreach ($pattern in @('first\n\n', 'native-error', 'ARG1=\[\] ARG2=\[\]')) { Assert-Match $pattern $failure 'failure evidence retains both streams and blank lines' }
    Assert-Equal 37 $global:LASTEXITCODE
}

Describe 'Build native command transport' {
    It 'shares argument-free and argument-bearing output capture and detects dropped native arguments' {
        Invoke-TestFunctionMutations -ModuleArgumentsFactory ${function:New-NativeBuildTransportFixture} -IncludeControl `
            -Find '& $File @parameterList 2>&1' -Replace '& $File 2>&1' -Expected 'native argv must preserve empty calls and supplied values' `
            -Body { param($state) Assert-NativeBuildTransport $state }
    }
}
