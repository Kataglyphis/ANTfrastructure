#requires -Version 7.0
# Stubbed process and registry results do not exercise Docker, Windows isolation or actual host maintenance.

Describe 'Diagnostic container transport and verdicts' {
    It 'preserves candidate order, literal argv, host evidence and independently gated control/verdict results' {
        $functions = @('Resolve-DiagnosticDocker', 'Write-DiagnosticHeading', 'Write-DiagnosticHostEnvironment',
            'Invoke-DiagnosticDocker', 'Invoke-DiagnosticControl', 'Write-DiagnosticVerdict')
        $state = New-TestCallState -Properties @{ Code = 0; Output = @('marker'); Resolved = 'chosen'; Candidates = @() }
        $prelude = @'
function Invoke-TestDocker { $State.Calls.Add(@($args)); $global:LASTEXITCODE = $State.Code; $State.Output }
function Get-PreferredToolPath { param($CommandName, $CandidatePaths) $State.Candidates = $CandidatePaths; $State.Resolved }
function Get-ItemProperty { param($Path) if ($Path -notmatch 'Windows NT\\CurrentVersion$') { throw 'wrong registry path' }; [pscustomobject]@{ ProductName = 'host'; CurrentBuildNumber = '123'; UBR = '4' } }
'@
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsDiagnostics.Common.psm1' -FunctionName $functions -Prelude $prelude -FixtureState $state -Body { param($state)
            Assert-Equal 'explicit path' (Resolve-MutDiagnosticDocker -Docker 'explicit path')
            Assert-Equal 0 $state.Candidates.Count
            Invoke-WithEnv @{ DOCKER_EXE = 'owner preference' } {
                Assert-Equal 'chosen' (Resolve-MutDiagnosticDocker)
                Assert-Equal 'owner preference' $state.Candidates[0]
                Assert-Equal 'D:\Stevedore\bin\docker.exe' $state.Candidates[1]
            }
            $state.Resolved = ''
            Assert-Throws { Resolve-MutDiagnosticDocker } -MessagePattern 'docker.exe not found'
            $state.Code = 7
            $result = Invoke-MutDiagnosticDocker -Docker Invoke-TestDocker -Arguments @('build', '--build-arg', 'VALUE=a b;c') 6>$null
            Assert-Equal 7 $result.Code
            Assert-Equal 'marker' $result.Text
            Assert-Equal 'build|--build-arg|VALUE=a b;c' ($state.Calls[0] -join '|')
            $state.Code = 0
            foreach ($case in @(@{ Code = 0; Text = 'marker'; Pass = $true }, @{ Code = 7; Text = 'marker'; Pass = $false }, @{ Code = 0; Text = ''; Pass = $false })) {
                $state.Code = $case.Code; $state.Output = @($case.Text)
                $ok = Invoke-MutDiagnosticControl -Docker Invoke-TestDocker -Base 'image:test' -Command @('pwsh', '-EncodedCommand', 'encoded==') -Marker marker -SuccessDetail good -FailureDetail bad 6>$null
                Assert-Equal $case.Pass $ok
                Assert-Equal 'run|--rm|--isolation|process|image:test|pwsh|-EncodedCommand|encoded==' ($state.Calls[-1] -join '|')
            }
            $state.Output = @('engine evidence'); $state.Code = 0
            $evidence = Write-MutDiagnosticHostEnvironment -Docker Invoke-TestDocker -Base 'base:test' -ImageLabel 'Probe base img ' 6>&1 | Out-String
            Assert-Match 'Host\s+: host \(build 123.4\)' $evidence
            Assert-Match 'Probe base img : base:test' $evidence
            Assert-Match 'engine evidence' $evidence
            Assert-Equal 'version' $state.Calls[-2][0]
            Assert-Equal 'info' $state.Calls[-1][0]
            foreach ($case in @(@{ Pass = $true; Bug = $true; Code = 0; Text = 'success' }, @{ Pass = $false; Bug = $true; Code = 1; Text = 'present' }, @{ Pass = $false; Bug = $false; Code = 2; Text = 'unknown' })) {
                $records = @(Write-MutDiagnosticVerdict -Passed $case.Pass -KnownBug $case.Bug -Success success -Present present -Failure unknown 6>&1)
                Assert-Equal $case.Code $records[-1]
                Assert-Match $case.Text ($records | Out-String)
            }
        }
    }
}

Describe 'Shared diagnostic result lines' {
    It 'preserves exact success, failure and optional-detail bytes' {
        Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsDiagnostics.Common.psm1') -DisableNameChecking
        $module = Get-Module WindowsDiagnostics.Common
        Assert-True ($module.ExportedFunctions.ContainsKey('Find-ChildDirectoryFile')) 'diagnostics reexport their required library lookup'
        $lines = @(
            Write-DiagnosticResult -Name 'present' -Ok $true -Detail '64 bytes' 6>&1
            Write-DiagnosticResult -Name 'absent' -Ok $false 6>&1
            Write-DiagnosticResult -Name 'error' -Ok $false -Detail 'fixture failure' 6>&1
            Write-DiagnosticResult -Name 'separate' -Ok $false -Detail 'second line' -SeparateDetail 6>&1
        ) | ForEach-Object { "$_" }
        Assert-Equal '[ OK ] present - 64 bytes|[FAIL] absent|[FAIL] error - fixture failure|[FAIL] separate|       second line' ($lines -join '|')
    }
}

function Assert-GpuDockerLookupWiring {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast)
    $calls = @(Get-TestAstCommands -Ast $Ast -Name Resolve-DiagnosticDocker)
    Assert-Equal 1 $calls.Count 'GPU diagnostic must delegate required Docker lookup'
    Assert-Equal 0 (Get-TestCommandArguments -Command $calls[0]).Count 'shared Docker lookup owns candidate selection'
    $condition = Get-TestAstAncestor -Node $calls[0] -Type ([Management.Automation.Language.IfStatementAst]) -First
    Assert-NotNull $condition
    Assert-Match 'IsNullOrWhiteSpace\(\$Docker\)' $condition.Clauses[0].Item1.Extent.Text
    Assert-Equal 0 @(Get-TestAstCommands -Ast $Ast -Name Get-PreferredToolPath).Count 'Docker candidate selection belongs to WindowsDiagnostics.Common'
}

Describe 'GPU diagnostic Docker lookup' {
    It 'uses the required shared resolver only when the caller leaves Docker blank' {
        $ast = Get-TestScriptAst -ScriptPath 'windows/scripts/diagnostics/Test-GpuPassthrough.ps1'
        Assert-GpuDockerLookupWiring -Ast $ast
    }

    It 'rejects a removed shared resolver call after parsing the valid mutation' {
        $source = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/diagnostics/Test-GpuPassthrough.ps1'))
        $mutated = $source.Replace('$Docker = Resolve-DiagnosticDocker', '$Docker = ''fixture''')
        $ast = ConvertTo-TestScriptAst -Text $mutated
        Assert-Throws { Assert-GpuDockerLookupWiring -Ast $ast } -MessagePattern 'GPU diagnostic must delegate required Docker lookup'
    }

    It 'rejects parse errors before inspecting the resolver declaration' {
        $source = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/diagnostics/Test-GpuPassthrough.ps1'))
        $mutated = $source.Replace('$Docker = Resolve-DiagnosticDocker', '$Docker = if (')
        Assert-Throws {
            $ast = ConvertTo-TestScriptAst -Text $mutated
            Assert-GpuDockerLookupWiring -Ast $ast
        } -MessagePattern 'snippet failed to parse'
    }
}
