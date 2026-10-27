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

  It 'runs the first resource compiler on PATH when several copies are installed' {
    Invoke-InTestDir { param($dir)
      $bins = foreach ($name in 'first', 'second') {
        $bin = Join-Path $dir $name
        $null = New-Item -ItemType Directory -Path $bin
        if ($IsWindows) {
          Set-Content -LiteralPath (Join-Path $bin 'fake-rc.cmd') -Encoding ascii -Value @('@echo off', "echo $name> %2")
        } else {
          $tool = Join-Path $bin 'fake-rc'
          Set-Content -LiteralPath $tool -Encoding ascii -Value @('#!/bin/sh', "printf $name > `"`$2`"")
          & chmod +x $tool
        }
        $bin
      }
      $prelude = "function ConvertTo-PythonAppIcon { param(`$PngPath, `$Destination) [IO.File]::WriteAllText(`$Destination, 'ico') }"
      Invoke-WithEnv @{ PATH = ($bins -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:PATH } {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsIcon.Common.psm1' -FunctionName New-WindowsIconResource `
          -Prelude $prelude -BodyArgumentList (Join-Path $dir 'work') -Body { param($work)
            $png = Join-Path (Get-RepoRoot) 'images/logo.png'
            $resource = New-MutWindowsIconResource -PngPath $png -WorkDir $work -ResourceCompiler 'fake-rc'
            Assert-Equal 'first' ([IO.File]::ReadAllText($resource).Trim())
          }
      }
    }
  }
}
