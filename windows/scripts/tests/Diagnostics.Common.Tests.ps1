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
