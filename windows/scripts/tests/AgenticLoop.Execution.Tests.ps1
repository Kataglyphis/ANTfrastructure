#requires -Version 7.0
# Fakes exercise loop progress and phase policy; real agent APIs, git and native builds remain integration coverage.

Import-Module (Join-Path $PSScriptRoot 'WindowsAgentic.Fixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop

$script:agenticExecutionFactory = New-TestAgenticModuleFactory -Properties @{ ProgressAt = @(); Attempts = 0; BuildOk = $true } `
        -FunctionName @('Invoke-AgenticCommandPhase', 'Start-AgenticCommandPhase', 'Invoke-AgenticLoop', 'Get-AgenticConfigValue', 'Resolve-BuildMatrixEntry', 'Invoke-QualityCommand',
            'Get-AgenticDefaultBacklogPath', 'Get-AgenticBacklogTaskCount', 'Get-UncheckedTaskCount', 'Get-BlockedTaskCount', 'Remove-CheckedBacklogTasks') -Prelude @'
$script:AgenticExitCode = 0
function Resolve-AgenticEngine { return @{ Engine = 'fixture'; PlannerModel = 'planner'; ExecutorModel = 'executor' } }
function Invoke-AgenticAgent {
    param($Role)
    $State.Calls.Add("role|$Role")
    if ($Role -ne 'executor') { return }
    $State.Attempts++
    if ($State.ProgressAt -notcontains $State.Attempts) { return }
    $path = Join-Path $State.Root 'BACKLOG.md'
    $text = [IO.File]::ReadAllText($path)
    $text = [regex]::new('(?m)^- \[ \]').Replace($text, '- [x]', 1)
    [IO.File]::WriteAllText($path, $text)
}
function Invoke-BuildCommand { param($Configuration) $State.Calls.Add("build|$Configuration"); return $State.BuildOk }
function Invoke-GitAutoCommit { param($Message) $State.Calls.Add("commit|$Message") }
function Invoke-LoggedAgenticCommand { param($Command) $State.Calls.Add("quality|$Command"); return 17 }
function Reset-AgenticExecution {
    param([int[]]$ProgressAt, [int]$Tasks, [bool]$BuildOk = $true, [bool]$DryRun = $false)
    $State.ProgressAt = $ProgressAt; $State.Attempts = 0; $State.BuildOk = $BuildOk
    $State.Calls.Clear()
    $script:AgenticExitCode = 0; $script:AgenticDryRun = $DryRun
    Set-Content -LiteralPath (Join-Path $State.Root 'BACKLOG.md') -Value @(
        '- [x] old completed task', '- [b] blocked task'
        foreach ($number in 1..$Tasks) { "- [ ] task $number" }
    )
}
function Get-AgenticExecutionResult {
    return [pscustomobject]@{ ExitCode = $script:AgenticExitCode; Completed = $script:AgenticTasksCompleted; Iterations = $script:AgenticIterations }
}
'@

function Get-AgenticExecutionCalls {
    param($State, [string]$Kind)
    @($State.Calls | Where-Object { $_.StartsWith("$Kind|") } | ForEach-Object { $_.Substring($Kind.Length + 1) })
}

function Invoke-AgenticExecutionFixture {
    param($State, [switch]$ExecutorOnly)
    $config = @{
        intervals = @{ buildEveryNTasks = 1; qualityEveryNTasks = 2
            maxIterations = 3; maxExecutorRetries = 2; fixBuildFailures = $false; maxConsecutiveBuildFailures = 2 }
        git = @{ commitPrefix = 'fixture' }
        build = @{ windowsQualityCommand = 'quality exits unsuccessfully' }
    }
    Invoke-MutAgenticLoop -Config $config -PlannerPrompt planner -ExecutorPrompt executor -BuildConfigs debug, release `
        -OnWindows $true -RepoRoot $State.Root -SkipTests -ExecutorOnly:$ExecutorOnly
}

function Assert-AgenticBatchProgress {
    param($State, [bool]$ExecutorOnly)
        Reset-MutAgenticExecution -ProgressAt 2, 4 -Tasks 2
        Invoke-AgenticExecutionFixture -State $State -ExecutorOnly:$ExecutorOnly
        $result = Get-MutAgenticExecutionResult
        Assert-Equal 2 $result.Completed 'shared task total must reach the post-task phase'
        Assert-Equal 4 $State.Attempts 'progress resets the no-progress retry budget'
        Assert-Equal 'fixture: task #1|fixture: task #2' ((Get-AgenticExecutionCalls $State commit) -join '|')
        Assert-Equal 'debug|release' ((Get-AgenticExecutionCalls $State build) -join '|') 'build rotation follows total completed tasks'
        Assert-Equal 1 @(Get-AgenticExecutionCalls $State quality).Count 'quality uses the same total and remains advisory'
        Assert-Equal 0 $result.ExitCode
        $backlog = Get-Content -LiteralPath (Join-Path $State.Root 'BACKLOG.md') -Raw
        Assert-Equal '- [b] blocked task' $backlog.Trim() 'checked task cleanup leaves blocked tasks intact'
}

function Assert-AgenticFailureCap {
    param($State, [bool]$ExecutorOnly)
        Reset-MutAgenticExecution -ProgressAt 1, 2, 3 -Tasks 3 -BuildOk $false
        Invoke-AgenticExecutionFixture -State $State -ExecutorOnly:$ExecutorOnly
        $result = Get-MutAgenticExecutionResult
        Assert-Equal 1 $result.ExitCode 'both modes must fail when the build failure cap is hit'
        Assert-Equal 2 $result.Completed 'the failure cap stops further tasks'
        Assert-Equal 2 $State.Attempts
        Assert-Equal 2 @(Get-AgenticExecutionCalls $State build).Count
        $ending = if ($ExecutorOnly) { 'stopping' } else { 'stopping loop' }
        Assert-True ($State.Calls -contains "log|ERROR|Too many consecutive build failures — $ending") 'mode-specific failure diagnostic'
        Assert-Equal 1 (Get-MutUncheckedTaskCount -BacklogPath (Join-Path $State.Root 'BACKLOG.md'))
}

function Invoke-AgenticModeAssertions {
    param($State, [scriptblock]$Assertion)
    foreach ($executorOnly in @($true, $false)) { & $Assertion $State $executorOnly }
}

function Invoke-AgenticExecutionAssertions {
    param([scriptblock]$Assertion)
    $probe = $Assertion
    Invoke-InTestDir { param($dir)
        $recipe = & $script:agenticExecutionFactory $dir
        Invoke-WithFunctionModule @recipe -Body $probe
    }
}

Describe 'Agentic executor batch' {
    Invoke-TestMutationChecks -Check @(
        @{ Name = 'preserves progress totals, cleanup and post-task scheduling, with a counter fault control'; Arguments = @{
            ModuleArgumentsFactory = $script:agenticExecutionFactory; Find = '$CompletedTotal.Value++'
            Replace = '$null = $CompletedTotal.Value'; Expected = 'shared task total'; Body = { param($state) Invoke-AgenticModeAssertions $state ${function:Assert-AgenticBatchProgress} } } }
        @{ Name = 'sets a failing exit code and stops both modes at the build failure cap, with a fault control'; Arguments = @{
            ModuleArgumentsFactory = $script:agenticExecutionFactory; Find = '$script:AgenticExitCode = 1'
            Replace = '$script:AgenticExitCode = 0'; Expected = 'both modes must fail'; Body = { param($state) Invoke-AgenticModeAssertions $state ${function:Assert-AgenticFailureCap} } } }
        @{ Name = 'logs command phases but disables execution in dry runs, with a guard fault control'; Arguments = @{
            ModuleArgumentsFactory = $script:agenticExecutionFactory; Find = 'return (-not $script:AgenticDryRun)'
            Replace = 'return $true'; Expected = 'phase guard'; Body = {
                param($state)
                Reset-MutAgenticExecution -ProgressAt @() -Tasks 1
                Assert-True (Start-MutAgenticCommandPhase -Command 'recorded phase' -Title 'phase title')
                Reset-MutAgenticExecution -ProgressAt @() -Tasks 1 -DryRun $true
                Assert-False (Start-MutAgenticCommandPhase -Command 'recorded phase' -Title 'phase title') 'phase guard must disable dry-run execution'
                Assert-True ($state.Calls.Contains('log|INFO|Command: recorded phase')) 'dry-run commands remain logged'
            } } }
    )

    It 'bounds no-progress retries and retains planner starvation recovery and dry-run short circuit' {
        Invoke-AgenticExecutionAssertions { param($state)
                Reset-MutAgenticExecution -ProgressAt @() -Tasks 1
                Invoke-AgenticExecutionFixture -State $state -ExecutorOnly
                Assert-Equal 2 $state.Attempts 'executor-only retry cap'
                Reset-MutAgenticExecution -ProgressAt @() -Tasks 1
                Invoke-AgenticExecutionFixture -State $state
                Assert-Equal 'executor|executor|planner|executor|executor' ((Get-AgenticExecutionCalls $state role) -join '|') 'full mode gives the planner one recovery opportunity'
                Assert-Equal 2 (Get-MutAgenticExecutionResult).Iterations
                Reset-MutAgenticExecution -ProgressAt @() -Tasks 1 -DryRun $true
                Invoke-AgenticExecutionFixture -State $state -ExecutorOnly
                Assert-Equal 1 $state.Attempts 'dry runs do not exhaust the ordinary retry budget'
                Assert-Equal 0 (Get-MutAgenticExecutionResult).Completed
        }
    }

    It 'counts actionable and blocked lines separately and treats a missing backlog as empty' {
        Invoke-AgenticExecutionAssertions { param($state)
                $path = Join-Path $state.Root 'BACKLOG.md'
                Assert-Equal 0 (Get-MutUncheckedTaskCount -BacklogPath $path)
                Assert-Equal 0 (Get-MutBlockedTaskCount -BacklogPath $path)
                Set-Content -LiteralPath $path -Value @('- [ ] actionable', '- [b] blocked', '- [B] also blocked', '- [x] done', '  - [ ] nested')
                Assert-Equal 1 (Get-MutUncheckedTaskCount -BacklogPath $path)
                Assert-Equal 2 (Get-MutBlockedTaskCount -BacklogPath $path)
                Push-Location $state.Root
                try {
                    Assert-Equal 1 (Get-MutUncheckedTaskCount) 'default backlog resolves in the current location at call time'
                    Assert-Equal 2 (Get-MutBlockedTaskCount)
                } finally { Pop-Location }
        }
    }
}
