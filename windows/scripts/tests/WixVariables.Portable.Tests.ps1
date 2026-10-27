#requires -Version 7.0
# Validates WiX argv construction with fakes; it does not execute WiX or install an MSI.
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.NativeArgs.psm1') -DisableNameChecking -ErrorAction Stop

Describe 'portable WiX variable forwarding' {
  It 'preserves argument boundaries and rejects invalid or reserved names before invoking WiX' {
    $state = New-TestCallState @{ Argv = @() }
    $prelude = @'
function Test-Path { param($LiteralPath, $PathType) return $true }
function Resolve-WixExe { param($OverridePath) return 'wix.exe' }
function Invoke-PackagerTool {
  param($Context, $File, $Parameters, $OutputPath, $InvokerScriptBlock)
  $State.Argv = $Parameters
}
'@
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsMsix.Common.psm1' `
      -FunctionName Invoke-MsiPackage, Get-WixVariableArguments -Prelude $prelude -FixtureState $state -Body { param($fixture)
        $base = @{ Context = [pscustomobject]@{}; WxsFile = 'p.wxs'; LicenseFile = 'LICENSE.rtf'; ProductName = 'App';
          Manufacturer = 'Owner'; ExeSource = 'app.exe'; Version = '1.2.3'; OutFile = 'app.msi'; Arch = 'x64' }
        Invoke-MutMsiPackage @base -WixVariables @{ IconSource = 'path with space/logo.ico' } | Out-Null
        Assert-TestNativeArgOrder -Arguments $fixture.Argv -First '-d' -Second 'IconSource=path with space/logo.ico' -Adjacent
        foreach ($name in 'Version', 'PayloadFiles', 'bad-name') {
          $fixture.Argv = @()
          Assert-Throws -MessagePattern 'Invalid or reserved WiX variable name' -Body { Invoke-MutMsiPackage @base -WixVariables @{ $name = 'x' } }
          Assert-Equal 0 $fixture.Argv.Count
        }
      }
  }
}
