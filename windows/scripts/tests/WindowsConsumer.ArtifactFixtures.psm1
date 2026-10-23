#requires -Version 7.0
# Shared fake transport keeps consumer copy tests on one argv and status recorder.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop
$script:CopySource = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsBuild.Common.psm1' -FunctionName Invoke-BuildArtifactCopy, Sync-BuildArtifacts).ToString() + "`n" +
    (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsFlutter.Common.psm1' -FunctionName Sync-FlutterArtifactTree, Sync-FastLocalArtifactsToHost).ToString()

function New-TestArtifactCopyModuleArguments {
    param([string]$Root = '', [int[]]$Codes = @())
    @{
        Text = $script:CopySource
        FixtureState = (New-TestCallState @{ Root = $Root; Code = 0; Codes = [Collections.Generic.Queue[int]]::new([int[]]$Codes); Warnings = [Collections.Generic.List[string]]::new() })
        Prelude = @'
function Write-BuildLog {}
function Write-BuildLogWarning { param($Context, $Message) $State.Warnings.Add($Message) }
function robocopy.exe {
    $State.Calls.Add(@($args))
    'discarded native stdout'
    Write-Error 'discarded native diagnostic' -ErrorAction Continue
    $global:LASTEXITCODE = if ($State.Codes.Count) { $State.Codes.Dequeue() } else { $State.Code }
}
'@
    }
}

Export-ModuleMember -Function New-TestArtifactCopyModuleArguments
