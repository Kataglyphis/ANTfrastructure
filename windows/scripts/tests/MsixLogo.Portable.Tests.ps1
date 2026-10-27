#requires -Version 7.0
# This tests staging dispatch with fakes; image decoding and actual MSIX creation require Windows.

Describe 'portable MSIX logo staging' {
  It 'uses the supplied logo and renders all four named sizes; transparent assets require the explicit switch' {
    Invoke-InTestDir { param($dir)
      $state = New-TestCallState @{ Root = $dir }
      $prelude = @'
function Read-MsixLogo {
  param($Path)
  $State.Calls.Add("read:$Path")
  $logo = [pscustomobject]@{ State = $State }
  $logo | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.State.Calls.Add('dispose') }
  return $logo
}
function Add-TestLogoCall {
  param($Kind, $Path, $Width, $Height)
  $State.Calls.Add(("{0}:{1}:{2}x{3}" -f $Kind, [IO.Path]::GetFileName($Path), $Width, $Height))
}
function Write-MsixResizedLogo { param($Image, $Path, $Width, $Height) Add-TestLogoCall render $Path $Width $Height }
function New-TransparentPng { param($Path, $Width, $Height) Add-TestLogoCall transparent $Path $Width $Height }
'@
      Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsMsix.Common.psm1' `
        -FunctionName Write-MsixStageAssets -Prelude $prelude -FixtureState $state -Body { param($fixture)
          Write-MutMsixStageAssets -StagingDir $fixture.Root -LogoPath 'project.png'
          Assert-Equal 'read:project.png' $fixture.Calls[0]
          $calls = @($fixture.Calls | Where-Object { $_ -like 'render:*' } | Sort-Object)
          Assert-Equal 'render:Square150x150Logo.png:150x150|render:Square44x44Logo.png:44x44|render:StoreLogo.png:50x50|render:Wide310x150Logo.png:310x150' ($calls -join '|')
          Assert-Equal 'dispose' $fixture.Calls[$fixture.Calls.Count - 1]
          $fixture.Calls.Clear()
          Write-MutMsixStageAssets -StagingDir $fixture.Root -GenerateTransparentLogos
          Assert-Equal 4 @($fixture.Calls | Where-Object { $_ -like 'transparent:*' }).Count
          Assert-Equal 0 @($fixture.Calls | Where-Object { $_ -like 'read:*' -or $_ -like 'render:*' }).Count
        }
    }
  }
}
