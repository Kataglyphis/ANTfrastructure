#requires -Version 7.0
# Exercises formatting-to-uv forwarding; it does not run a native formatter.

BeforeAll {
  Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsFormatting.Common.psm1') -Force -DisableNameChecking
}

Describe 'Locked formatting project' {
  BeforeEach {
    Mock -ModuleName WindowsFormatting.Common -CommandName Get-Command { [pscustomobject]@{ Source = 'uv' } }
    Mock -ModuleName WindowsFormatting.Common -CommandName New-UvBuildDelegates { [pscustomobject]@{ LogInfo = $null; LogWarning = $null; CommandRunner = $null } }
    Mock -ModuleName WindowsFormatting.Common -CommandName Initialize-UvVenv { 'C:\venv\Scripts\python.exe' }
    Mock -ModuleName WindowsFormatting.Common -CommandName Install-UvLockedProject { 'installer diagnostic' }
    Mock -ModuleName WindowsFormatting.Common -CommandName Assert-UvLockedProject { if ($ProjectPath -eq 'missing') { throw 'Missing locked uv project file' } }
  }

  It 'returns only the selected interpreter and forwards the locked project path' {
    $result = @(Initialize-UvVenvPython -Context ([pscustomobject]@{}) -WorkspacePath 'C:\work' -UvProjectPath 'C:\hub tools\cmake')
    $result | Should -HaveCount 1
    $result[0] | Should -Be 'C:\venv\Scripts\python.exe'
    Should -Invoke Install-UvLockedProject -ModuleName WindowsFormatting.Common -Times 1 -Exactly -ParameterFilter {
      $VenvPython -eq 'C:\venv\Scripts\python.exe' -and $ProjectPath -eq 'C:\hub tools\cmake'
    }
  }

  It 'rejects conflicting or missing project inputs before creating a venv' {
    $cases = @(
      @{ Requirements = 'old.txt'; Project = 'project'; Error = '*Choose either*' },
      @{ Requirements = ''; Project = 'missing'; Error = '*Missing locked uv project*' }
    )
    foreach ($case in $cases) {
      { Initialize-UvVenvPython -Context ([pscustomobject]@{}) -WorkspacePath 'C:\work' -RequirementsPath $case.Requirements -UvProjectPath $case.Project } | Should -Throw $case.Error
    }
    Should -Invoke Initialize-UvVenv -ModuleName WindowsFormatting.Common -Times 0 -Exactly
  }

  It 'forwards the locked project through the cmake-format entry point' {
    Mock -ModuleName WindowsFormatting.Common -CommandName Initialize-UvVenvPython { 'C:\venv\Scripts\python.exe' }
    Mock -ModuleName WindowsFormatting.Common -CommandName Test-Path { $true }
    Mock -ModuleName WindowsFormatting.Common -CommandName Get-ProjectCmakeFiles { @('C:\work\CMakeLists.txt') }
    Mock -ModuleName WindowsFormatting.Common -CommandName Invoke-BuildExternal { }
    Invoke-CmakeFormatStep -Context ([pscustomobject]@{}) -WorkspacePath 'C:\work' -UvProjectPath 'C:\hub tools\cmake' -Check
    Should -Invoke Initialize-UvVenvPython -ModuleName WindowsFormatting.Common -Times 1 -Exactly -ParameterFilter {
      $UvProjectPath -eq 'C:\hub tools\cmake'
    }
    Should -Invoke Invoke-BuildExternal -ModuleName WindowsFormatting.Common -Times 1 -Exactly -ParameterFilter {
      $Parameters -contains '--check'
    }
  }
}
