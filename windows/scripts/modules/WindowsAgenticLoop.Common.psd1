@{
RootModule = 'WindowsAgenticLoop.Common.psm1'
ModuleVersion = '1.0.0'
GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
Author = 'Kataglyphis'
CompanyName = 'Kataglyphis'
Copyright = '(c) 2026 Kataglyphis. All rights reserved.'
Description = 'Reusable building blocks for the OpenCode agentic loop pattern.'
PowerShellVersion = '5.1'
FunctionsToExport = @(
    'Initialize-AgenticLoop',
    'Complete-AgenticLoop',
    'Write-AgenticLog',
    'Write-AgenticSection',
    'Get-AgenticLogFile',
    'Get-AgenticPlatform',
    'Test-IsWindows',
    'Invoke-OpenCode',
    'Get-UncheckedTaskCount',
    'Invoke-GitAutoCommit',
    'Invoke-BuildCommand',
    'Invoke-TestCommand',
    'Invoke-QualityCommand',
    'Invoke-AgenticLoop'
)
}