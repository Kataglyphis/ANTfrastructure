#requires -Version 7.0
# Tests converter dispatch with a fake decoder; real decoding and transparency are tested on Windows.
Describe 'portable Windows icon validation' {
  It 'passes the decoded image visibility to the shared verdict' {
    $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsMsix.Common.psm1'))
    Assert-True ($text.Contains('-IsVisible (Test-MsixImageVisible -Image $logo)'))
  }

  It 'rejects transparent and non-PNG decoded images through the shared verdict' {
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsMsix.Common.psm1' -FunctionName Assert-MsixLogoContent -Body {
      Assert-MutMsixLogoContent -IsPng $true -IsVisible $true -Path 'project.png'
      Assert-Throws -MessagePattern 'visible PNG' -Body { Assert-MutMsixLogoContent -IsPng $true -IsVisible $false -Path 'project.png' }
      Assert-Throws -MessagePattern 'visible PNG' -Body { Assert-MutMsixLogoContent -IsPng $false -IsVisible $true -Path 'project.png' }
    }
  }

  It 'requires the shared decoder to accept the source before writing an ICO' {
    Invoke-InTestDir { param($dir)
      $state = New-TestCallState @{ Root = $dir; Reject = $false }
      $prelude = @'
function Read-MsixLogo {
  param($Path)
  $State.Calls.Add($Path)
  if ($State.Reject) { throw 'decoder rejected the image' }
  $image = [pscustomobject]@{}
  $image | Add-Member ScriptMethod Dispose {}
  return $image
}
'@
      Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsIcon.Common.psm1' -FunctionName ConvertTo-PythonAppIcon `
        -Prelude $prelude -FixtureState $state -Body { param($fixture)
          $png = Join-Path (Get-RepoRoot) 'images/logo.png'
          $output = Join-Path $fixture.Root 'valid.ico'
          $null = ConvertTo-MutPythonAppIcon -PngPath $png -Destination $output
          Assert-True (Test-Path -LiteralPath $output)
          Assert-Equal $png $fixture.Calls[0]
          $fixture.Reject = $true
          $bad = Join-Path $fixture.Root 'bad.ico'
          Assert-Throws -MessagePattern 'decoder rejected' -Body { ConvertTo-MutPythonAppIcon -PngPath $png -Destination $bad }
          Assert-False (Test-Path -LiteralPath $bad)
        }
    }
  }
}
