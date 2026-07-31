@{
RootModule = 'WindowsAgenticLoop.Common.psm1'
ModuleVersion = '1.1.0'
GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
Author = 'Kataglyphis'
CompanyName = 'Kataglyphis'
Copyright = '(c) 2026 Kataglyphis. All rights reserved.'
Description = 'Reusable building blocks for the planner/executor agentic loop pattern (OpenCode + Claude Code engines).'
PowerShellVersion = '7.0'
FunctionsToExport = @(
    'Initialize-AgenticLoop',
    'Complete-AgenticLoop',
    'Write-AgenticLog',
    'Write-AgenticSection',
    'Get-AgenticLogFile',
    'Get-AgenticPlatform',
    'Test-IsWindows',
    'Get-AgenticConfigValue',
    'Resolve-AgenticEngine',
    'Get-AgentTimeoutForRole',
    'Invoke-AgentProcess',
    'Invoke-OpenCode',
    'Invoke-ClaudeCode',
    'Invoke-AgenticAgent',
    'Invoke-BuildFixer',
    'Get-UncheckedTaskCount',
    'Get-BlockedTaskCount',
    'Remove-CheckedBacklogTasks',
    'Invoke-GitAutoCommit',
    'Invoke-BuildCommand',
    'Invoke-TestCommand',
    'Invoke-QualityCommand',
    'Resolve-BuildMatrixEntry',
    'Get-SanitizerEnvVars',
    'Invoke-SanitizerTestCommand',
    'Invoke-AgenticLoop'
)
}
