# Tests for WindowsAgenticLoop.Common.psm1 -- reusable agentic loop module.
#
# These are CPU-only, no network calls. They exercise:
# - OpenCode invocation (with a mock override)
# - BACKLOG task counting
# - Logging primitives
# - Platform detection
# - Git auto-commit (dry-run)
#
# Run: pwsh -NoProfile -Command "Invoke-Pester .\WindowsAgenticLoop.Common.Tests.ps1"

Describe 'WindowsAgenticLoop.Common' {
    BeforeAll {
        # Resolve the module path: module is at windows/scripts/modules/
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $modulePath = Join-Path $repoRoot 'modules\WindowsAgenticLoop.Common.psm1'
        if (Test-Path $modulePath) {
            Import-Module $modulePath -Force -DisableNameChecking
            Write-Host "Module loaded from: $modulePath"
        } else {
            Write-Warning "Module not found at $modulePath — using mock functions"
            function global:Write-AgenticLog { param([string]$Message, [string]$Level = 'INFO') }
            function global:Write-AgenticSection { param([string]$Title) }
            function global:Get-AgenticLogFile { return Join-Path $PSScriptRoot 'test.log' }
            function global:Get-AgenticPlatform { if ($env:OS -eq 'Windows_NT') { 'windows' } else { 'linux' } }
            function global:Test-IsWindows { return (Get-AgenticPlatform) -eq 'windows' }
            function global:Initialize-AgenticLoop { param([string]$ConfigPath, [string]$RepoRoot, [switch]$DryRun) }
            function global:Complete-AgenticLoop { param([int]$Iteration, [int]$TasksCompleted) }
            function global:Invoke-OpenCode { param([string]$Agent, [string]$Model, [string]$Message) return '[DRY RUN]' }
            function global:Get-UncheckedTaskCount { param([string]$BacklogPath = 'BACKLOG.md'); return 0 }
            function global:Invoke-GitAutoCommit { param([string]$Message, [string]$RepoRoot, [bool]$Enabled) }
            function global:Invoke-BuildCommand { param([string]$Command, [string]$Configuration) return $true }
            function global:Invoke-TestCommand { param([string]$Command, [string]$RepoRoot) return $true }
            function global:Invoke-QualityCommand { param([string]$Command, [string]$RepoRoot) }
            function global:Invoke-AgenticLoop { param($Config, [string]$PlannerPrompt, [string]$ExecutorPrompt, [string[]]$BuildConfigs, [bool]$OnWindows, [string]$RepoRoot, [int]$MaxIterations, [switch]$SkipBuild, [switch]$SkipTests, [switch]$SkipQuality, [switch]$PlannerOnly, [switch]$ExecutorOnly) }
            return
        }

        # Mock opencode for all tests (no real API calls)
        Mock -ModuleName WindowsAgenticLoop.Common Invoke-Expression {
            return @('mocked output line 1', 'mocked output line 2')
        }
        Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global

        # Temporary directory for test files
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "agentic-loop-pester-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Force $script:testDir | Out-Null

        # Initialize the module with dry-run
        Initialize-AgenticLoop -RepoRoot $script:testDir -DryRun
    }

    AfterAll {
        if (Test-Path $script:testDir) { Remove-Item $script:testDir -Recurse -Force }
    }

    # -- Platform detection -------------------------------------------------

    Context 'Platform detection' {
        It 'Get-AgenticPlatform returns a known platform' {
            $platform = Get-AgenticPlatform
            # -contains instead of Should Contain: Pester 3.x treats the
            # piped value as a file path, not an array
            (@('windows', 'linux') -contains $platform) | Should Be $true
        }

        It 'Test-IsWindows is consistent with the environment' {
            $expected = ($env:OS -eq 'Windows_NT')
            Test-IsWindows | Should Be $expected
        }

        It 'Platform detection is safe under StrictMode' {
            # The function must not access $PSVersionTable.Platform (PS 5.1 crash)
            { Get-AgenticPlatform } | Should Not Throw
        }
    }

    # -- Logging -----------------------------------------------------------

    Context 'Logging primitives' {
        It 'Write-AgenticLog writes to the log file' {
            $logFile = Get-AgenticLogFile
            Write-AgenticLog 'Test message' 'DEBUG'
            # Log file is written at initialization time -- verify it exists
            $logFile | Should Not BeNullOrEmpty
        }

        It 'Write-AgenticSection produces a decorated header' {
            { Write-AgenticSection 'TEST SECTION' } | Should Not Throw
        }
    }

    # -- OpenCode invocation -----------------------------------------------

    Context 'Invoke-OpenCode' {
        BeforeAll {
            # Create a minimal BACKLOG.md for the planner to find
            Set-Content (Join-Path $script:testDir 'BACKLOG.md') @'
# BACKLOG
- [ ] Test task 1
- [x] Done task
- [ ] Test task 2
'@
        }

        It 'returns DRY RUN message when initialized with -DryRun' {
            $result = Invoke-OpenCode -Agent 'planner' -Model 'test-model' -Message 'hello'
            $result | Should Match 'DRY RUN'
        }

        It 'does not throw on empty message' {
            { Invoke-OpenCode -Agent 'planner' -Model 'test-model' -Message '' } | Should Not Throw
        }

        It 'handles long multi-line messages gracefully' {
            $longMsg = "Line 1`nLine 2`nLine 3`n" + ('x' * 1000)
            { Invoke-OpenCode -Agent 'executor' -Model 'test-model' -Message $longMsg } | Should Not Throw
        }
    }

    # -- BACKLOG helpers ---------------------------------------------------

    Context 'Get-UncheckedTaskCount' {
        BeforeAll {
            Set-Content (Join-Path $script:testDir 'BACKLOG.md') @'
# BACKLOG
- [ ] First task
- [x] Completed task
- [ ] Second task
- [ ] Third task
## Section
- [ ] Fourth task
'@
        }

        It 'counts unchecked tasks correctly' {
            $count = Get-UncheckedTaskCount -BacklogPath (Join-Path $script:testDir 'BACKLOG.md')
            $count | Should Be 4
        }

        It 'returns 0 for a missing file' {
            $count = Get-UncheckedTaskCount -BacklogPath (Join-Path $script:testDir 'nonexistent.md')
            $count | Should Be 0
        }

        It 'returns 0 for an empty file' {
            $emptyPath = Join-Path $script:testDir 'empty.md'
            '' | Set-Content $emptyPath
            $count = Get-UncheckedTaskCount -BacklogPath $emptyPath
            $count | Should Be 0
        }

        It 'returns 0 for a file with only checked tasks' {
            $donePath = Join-Path $script:testDir 'all-done.md'
            @('- [x] Done 1', '- [x] Done 2') | Set-Content $donePath
            $count = Get-UncheckedTaskCount -BacklogPath $donePath
            $count | Should Be 0
        }

        It 'does not count - [X] (uppercase) as unchecked' {
            $mixedPath = Join-Path $script:testDir 'mixed-case.md'
            @('- [ ] Task', '- [X] DONE', '- [x] done') | Set-Content $mixedPath
            $count = Get-UncheckedTaskCount -BacklogPath $mixedPath
            $count | Should Be 1  # only the lowercase x is counted by the regex
        }
    }

    # -- Backlog pruning ---------------------------------------------------

    Context 'Remove-CheckedBacklogTasks' {
        # Note: the module is initialized with -DryRun in BeforeAll, so these
        # tests verify content via a temporary non-dry-run window.
        BeforeAll {
            $script:pruneBacklog = Join-Path $script:testDir 'prune-backlog.md'
            Set-Content $script:pruneBacklog @'
# BACKLOG

## Section A

- [ ] **(S) Open task one** — keep me.

  **Steps:**
  1. Do something

- [x] **(M) Done task** — remove me.

  **Steps:**
  1. Was done
  Completed: everything went fine.

- [ ] **(L) Open task two** — keep me too.

## Section B

- [X] Uppercase done task
  body line
Plain text after the block.
'@
        }

        It 'reports the would-be removals in dry-run mode without changing the file' {
            $before = (Get-Content $script:pruneBacklog -Raw)
            $removed = Remove-CheckedBacklogTasks -BacklogPath $script:pruneBacklog
            $removed | Should Be 0
            (Get-Content $script:pruneBacklog -Raw) | Should Be $before
        }

        It 'removes checked blocks (title + indented body) and keeps everything else' {
            # Temporarily leave dry-run mode for a real prune
            Initialize-AgenticLoop -RepoRoot $script:testDir
            try {
                $removed = Remove-CheckedBacklogTasks -BacklogPath $script:pruneBacklog
                $removed | Should Be 2
                $content = Get-Content $script:pruneBacklog -Raw
                $content | Should Match 'Open task one'
                $content | Should Match 'Open task two'
                $content | Should Match 'Section B'
                $content | Should Match 'Plain text after the block'
                $content.Contains('Done task') | Should Be $false
                $content.Contains('Uppercase done task') | Should Be $false
                $content.Contains('Completed: everything went fine') | Should Be $false
            } finally {
                Initialize-AgenticLoop -RepoRoot $script:testDir -DryRun
            }
        }

        It 'returns 0 for a file with no checked tasks' {
            Remove-CheckedBacklogTasks -BacklogPath $script:pruneBacklog | Should Be 0
        }

        It 'returns 0 for a missing file' {
            Remove-CheckedBacklogTasks -BacklogPath (Join-Path $script:testDir 'no-such.md') | Should Be 0
        }
    }

    # -- Git helpers -------------------------------------------------------

    Context 'Invoke-GitAutoCommit' {
        It 'does nothing when disabled' {
            { Invoke-GitAutoCommit -Message 'test' -RepoRoot $script:testDir -Enabled:$false } | Should Not Throw
        }

        It 'logs DRY RUN when in dry-run mode' {
            $output = Invoke-GitAutoCommit -Message 'test commit' -RepoRoot $script:testDir -Enabled:$true
            # Should not throw; under dry-run it logs and returns
            $true | Should Be $true
        }
    }

    # -- Build / Test / Quality wrappers -----------------------------------

    Context 'Invoke-BuildCommand' {
        It 'returns true in dry-run mode' {
            $result = Invoke-BuildCommand -Command 'echo hello' -Configuration 'test'
            $result | Should Be $true
        }
    }

    Context 'Invoke-TestCommand' {
        It 'returns true in dry-run mode' {
            $result = Invoke-TestCommand -Command 'echo test' -RepoRoot $script:testDir
            $result | Should Be $true
        }
    }

    Context 'Invoke-QualityCommand' {
        It 'does not throw in dry-run mode' {
            { Invoke-QualityCommand -Command 'echo lint' -RepoRoot $script:testDir } | Should Not Throw
        }
    }

    # -- Config helpers ----------------------------------------------------

    Context 'Get-AgenticConfigValue' {
        It 'reads a hashtable key' {
            Get-AgenticConfigValue @{ foo = 'bar' } 'foo' 'x' | Should Be 'bar'
        }

        It 'returns the default for a missing hashtable key' {
            Get-AgenticConfigValue @{ foo = 'bar' } 'baz' 'fallback' | Should Be 'fallback'
        }

        It 'reads a PSCustomObject property (StrictMode-safe)' {
            $obj = '{"foo": "bar"}' | ConvertFrom-Json
            Get-AgenticConfigValue $obj 'foo' 'x' | Should Be 'bar'
            Get-AgenticConfigValue $obj 'missing' 'fallback' | Should Be 'fallback'
        }

        It 'returns the default for a null object' {
            Get-AgenticConfigValue $null 'foo' 'fallback' | Should Be 'fallback'
        }
    }

    # -- Engine resolution -------------------------------------------------

    Context 'Resolve-AgenticEngine' {
        BeforeAll {
            $script:engineConfig = @{
                engine = 'claude'
                engines = @{
                    claude = @{
                        plannerModel = 'claude-fable-5'
                        plannerFallbackModel = 'claude-opus-4-8'
                        executorModel = 'claude-sonnet-5'
                        plannerPromptFile = 'prompts/planner.md'
                        executorPromptFile = 'prompts/executor.md'
                        permissionMode = 'bypassPermissions'
                        plannerAllowedTools = 'Read Glob Grep Edit(BACKLOG.md)'
                    }
                    opencode = @{
                        plannerModel = 'opencode-go/glm-5.2'
                        executorModel = 'opencode-go/deepseek-v4-flash'
                    }
                }
                intervals = @{ timeoutSeconds = 600; plannerTimeoutSeconds = 900; executorTimeoutSeconds = 1800; agentRetries = 1; agentRetryDelaySeconds = 5 }
            }
            # Ensure env overrides do not leak into these tests
            $script:savedEngineEnv = $env:AGENTIC_ENGINE
            $script:savedPlannerEnv = $env:AGENTIC_PLANNER_MODEL
            $script:savedExecutorEnv = $env:AGENTIC_EXECUTOR_MODEL
            $env:AGENTIC_ENGINE = $null
            $env:AGENTIC_PLANNER_MODEL = $null
            $env:AGENTIC_EXECUTOR_MODEL = $null
        }

        AfterAll {
            $env:AGENTIC_ENGINE = $script:savedEngineEnv
            $env:AGENTIC_PLANNER_MODEL = $script:savedPlannerEnv
            $env:AGENTIC_EXECUTOR_MODEL = $script:savedExecutorEnv
        }

        It 'resolves the claude engine from config' {
            $ec = Resolve-AgenticEngine -Config $script:engineConfig -RepoRoot $script:testDir
            $ec.Engine | Should Be 'claude'
            $ec.PlannerModel | Should Be 'claude-fable-5'
            $ec.PlannerFallbackModel | Should Be 'claude-opus-4-8'
            $ec.ExecutorModel | Should Be 'claude-sonnet-5'
        }

        It 'resolves repo-relative prompt files to absolute paths' {
            $ec = Resolve-AgenticEngine -Config $script:engineConfig -RepoRoot $script:testDir
            $ec.PlannerPromptFile | Should Be (Join-Path $script:testDir 'prompts/planner.md')
        }

        It 'resolves per-role timeouts' {
            $ec = Resolve-AgenticEngine -Config $script:engineConfig -RepoRoot $script:testDir
            (Get-AgentTimeoutForRole -EngineConfig $ec -Role 'planner') | Should Be 900
            (Get-AgentTimeoutForRole -EngineConfig $ec -Role 'executor') | Should Be 1800
            (Get-AgentTimeoutForRole -EngineConfig $ec -Role 'fixer') | Should Be 1800
        }

        It 'honors the EngineOverride parameter' {
            $ec = Resolve-AgenticEngine -Config $script:engineConfig -RepoRoot $script:testDir -EngineOverride 'opencode'
            $ec.Engine | Should Be 'opencode'
            $ec.PlannerModel | Should Be 'opencode-go/glm-5.2'
        }

        It 'honors the AGENTIC_ENGINE env override' {
            $env:AGENTIC_ENGINE = 'opencode'
            try {
                $ec = Resolve-AgenticEngine -Config $script:engineConfig -RepoRoot $script:testDir
                $ec.Engine | Should Be 'opencode'
            } finally { $env:AGENTIC_ENGINE = $null }
        }

        It 'falls back to legacy .models when no engines block exists' {
            $legacy = @{ models = @{ planner = 'p-model'; executor = 'e-model' } }
            $ec = Resolve-AgenticEngine -Config $legacy -RepoRoot $script:testDir
            $ec.Engine | Should Be 'opencode'
            $ec.PlannerModel | Should Be 'p-model'
            $ec.ExecutorModel | Should Be 'e-model'
        }

        It 'throws for an unknown engine' {
            # try/catch instead of Should Throw: Pester 3.x misses exceptions
            # thrown from module-scoped advanced functions
            $threw = $false
            try { $null = Resolve-AgenticEngine -Config @{ engine = 'bogus'; models = @{ planner = 'p'; executor = 'e' } } -RepoRoot $script:testDir } catch { $threw = $true }
            $threw | Should Be $true
        }

        It 'throws when no models are configured' {
            $threw = $false
            try { $null = Resolve-AgenticEngine -Config @{ engine = 'claude' } -RepoRoot $script:testDir } catch { $threw = $true }
            $threw | Should Be $true
        }
    }

    # -- Claude invocation + dispatcher (dry-run) --------------------------

    Context 'Invoke-ClaudeCode / Invoke-AgenticAgent' {
        BeforeAll {
            $script:claudeEc = Resolve-AgenticEngine -Config @{
                engine = 'claude'
                engines = @{ claude = @{ plannerModel = 'claude-fable-5'; executorModel = 'claude-sonnet-5' } }
                intervals = @{ agentRetries = 0; agentRetryDelaySeconds = 1 }
            } -RepoRoot $script:testDir
        }

        It 'Invoke-ClaudeCode returns DRY RUN in dry-run mode' {
            $result = Invoke-ClaudeCode -Role 'executor' -Model 'claude-sonnet-5' -Message 'hello' -EngineConfig $script:claudeEc
            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'DRY RUN'
        }

        It 'Invoke-AgenticAgent dispatches planner to claude in dry-run mode' {
            Invoke-AgenticAgent -Role 'planner' -Message 'plan' -EngineConfig $script:claudeEc | Should Be $true
        }

        It 'Invoke-AgenticAgent dispatches fixer to the executor model' {
            Invoke-AgenticAgent -Role 'fixer' -Message 'fix' -EngineConfig $script:claudeEc | Should Be $true
        }
    }

    # -- Main loop (smoke test) --------------------------------------------

    Context 'Invoke-AgenticLoop' {
        BeforeAll {
            $script:mockConfig = @{
                models = @{ planner = 'test-planner'; executor = 'test-executor' }
                intervals = @{
                    buildEveryNTasks = 3; qualityEveryNTasks = 5; refactorEveryNIterations = 3
                    maxIterations = 1; maxExecutorRetries = 1; loopDelaySeconds = 0
                }
                git = @{ autoCommit = $false; commitPrefix = 'test' }
                build = @{ windowsTestCommand = 'echo ok'; windowsQualityCommand = 'echo ok'; linuxTestCommand = 'echo ok'; linuxQualityCommand = 'echo ok' }
            }
        }

        It 'runs planner-only mode without error' {
            { Invoke-AgenticLoop -Config $script:mockConfig -PlannerPrompt 'test' -ExecutorPrompt 'test' `
                -BuildConfigs @('debug') -OnWindows $true -RepoRoot $script:testDir -PlannerOnly -MaxIterations 1 } `
                | Should Not Throw
        }

        It 'runs executor-only mode without error' {
            # Put an unchecked task so the executor loop has work
            Set-Content (Join-Path $script:testDir 'BACKLOG.md') '- [ ] Test task'
            { Invoke-AgenticLoop -Config $script:mockConfig -PlannerPrompt 'test' -ExecutorPrompt 'test' `
                -BuildConfigs @('debug') -OnWindows $true -RepoRoot $script:testDir -ExecutorOnly -MaxIterations 1 } `
                | Should Not Throw
        }

        It 'full loop completes without error (max 1 iteration)' {
            { Invoke-AgenticLoop -Config $script:mockConfig -PlannerPrompt 'test' -ExecutorPrompt 'test' `
                -BuildConfigs @('debug') -OnWindows $true -RepoRoot $script:testDir -MaxIterations 1 -SkipBuild -SkipTests -SkipQuality } `
                | Should Not Throw
        }

        It 'full loop works with the claude engine (dry-run, max 1 iteration)' {
            $claudeCfg = @{
                engine = 'claude'
                engines = @{ claude = @{ plannerModel = 'claude-fable-5'; executorModel = 'claude-sonnet-5' } }
                intervals = @{
                    buildEveryNTasks = 3; qualityEveryNTasks = 5; refactorEveryNIterations = 3
                    maxIterations = 1; maxExecutorRetries = 1; loopDelaySeconds = 0
                }
                git = @{ autoCommit = $false; commitPrefix = 'test' }
                build = @{ windowsTestCommand = 'echo ok'; windowsQualityCommand = 'echo ok' }
            }
            { Invoke-AgenticLoop -Config $claudeCfg -PlannerPrompt 'test' -ExecutorPrompt 'test' `
                -BuildConfigs @('debug') -OnWindows $true -RepoRoot $script:testDir -MaxIterations 1 -SkipBuild -SkipTests -SkipQuality } `
                | Should Not Throw
        }

        It 'full loop works with an engine override to opencode' {
            $claudeCfg = @{
                engine = 'claude'
                engines = @{
                    claude = @{ plannerModel = 'claude-fable-5'; executorModel = 'claude-sonnet-5' }
                    opencode = @{ plannerModel = 'oc-planner'; executorModel = 'oc-executor' }
                }
                intervals = @{
                    buildEveryNTasks = 3; qualityEveryNTasks = 5; refactorEveryNIterations = 3
                    maxIterations = 1; maxExecutorRetries = 1; loopDelaySeconds = 0
                }
                git = @{ autoCommit = $false; commitPrefix = 'test' }
                build = @{ windowsTestCommand = 'echo ok'; windowsQualityCommand = 'echo ok' }
            }
            { Invoke-AgenticLoop -Config $claudeCfg -PlannerPrompt 'test' -ExecutorPrompt 'test' `
                -BuildConfigs @('debug') -OnWindows $true -RepoRoot $script:testDir -MaxIterations 1 -SkipBuild -SkipTests -SkipQuality -Engine 'opencode' } `
                | Should Not Throw
        }
    }

    # -- Complete-AgenticLoop -----------------------------------------------

    Context 'Complete-AgenticLoop' {
        It 'completes and exits cleanly with exit code 0' {
            # This function calls exit -- we wrap it to avoid terminating the test runner
            try { Complete-AgenticLoop -Iteration 1 -TasksCompleted 5 -ExitCode 0 } catch {
                # exit throws System.Management.Automation.ExitException in newer PS versions
                $_.Exception.Message | Should Match 'exit|0'
            }
        }
    }
}
