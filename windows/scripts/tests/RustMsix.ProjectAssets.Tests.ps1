#requires -Version 7.0
# Exercises the Rust packager's real dispatch and license copy; actual image rendering is tested separately on Windows.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/WindowsMsix.Common.psm1') -DisableNameChecking -ErrorAction Stop

Describe 'Rust MSIX project assets' {
  It 'uses the real script helper to stage the original license and pass the project logo to the shared renderer' {
    Invoke-InTestDir { param($dir)
      $source = Join-Path $dir 'project terms'
      [IO.File]::WriteAllText($source, 'Project terms')
      $state = New-TestCallState @{ Root = $dir }
      $prelude = @'
function Write-MsixStageAssets {
  param($StagingDir, $LogoPath)
  $State.Calls.Add("$StagingDir|$LogoPath")
}
'@
      Invoke-WithFunctionModule -ScriptPath 'windows/scripts/rust/New-MsixPackage.ps1' -FunctionName Set-RustMsixProjectAssets `
        -Prelude $prelude -FixtureState $state -Body { param($fixture)
          $stage = Join-Path $fixture.Root 'payload'
          $logo = Join-Path $fixture.Root 'project.png'
          Set-MutRustMsixProjectAssets -License (Join-Path $fixture.Root 'project terms') -Logo $logo -StagingDir $stage
          Assert-Equal 'Project terms' ([IO.File]::ReadAllText((Join-Path $stage 'LICENSE')))
          Assert-Equal "$stage|$logo" $fixture.Calls[0]
          Assert-Throws -MessagePattern 'not found' -Body {
            Set-MutRustMsixProjectAssets -License (Join-Path $fixture.Root 'missing') -Logo $logo -StagingDir $stage
          }
        }
    }
  }

  It 'calls the shared helper and validates license before resetting the stage' {
    $scriptText = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/rust/New-MsixPackage.ps1'))
    $validation = $scriptText.IndexOf('$projectLicense = Resolve-PackageLicense')
    $reset = $scriptText.IndexOf('Remove-Item $stagingRoot -Recurse -Force')
    Assert-True ($validation -ge 0 -and $reset -gt $validation)
    Assert-True ($scriptText.Contains('Set-RustMsixProjectAssets -License $projectLicense -Logo (Resolve-PathFromRoot -Root $Workspace -Path $LogoPath) -StagingDir $stagingRoot'))
  }

  It 'rejects a missing logo through the shared stage renderer' {
    Invoke-InTestDir { param($dir)
      Assert-Throws -MessagePattern 'MSIX logo not found' -Body {
        Write-MsixStageAssets -StagingDir $dir -LogoPath (Join-Path $dir 'missing.png')
      }
    }
  }
}
