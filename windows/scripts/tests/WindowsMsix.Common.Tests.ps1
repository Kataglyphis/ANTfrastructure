#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsMsix.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsMsix.Common.psm1'
    Import-Module $modulePath -Force

    $script:tmp = (New-Item -ItemType Directory `
        -Path (Join-Path $env:TEMP ('msix-common-' + (Get-Random))) -Force).FullName
  }

  AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Expand-XmlTemplateTokens' {
    It 'XML-escapes the substituted value' {
      Expand-XmlTemplateTokens -Template '<root>__TOKEN__</root>' -TokenMap @{ '__TOKEN__' = 'A & B <C>' } |
        Should -Be '<root>A &amp; B &lt;C&gt;</root>'
    }
  }

  Context 'Resolve-WindowsSdkToolPath' {
    It 'returns $null when the tool is on neither PATH nor any SDK candidate directory' {
      # Test-Path is mocked too, or the Windows Kits scan resolves a real SDK on the host.
      Mock -ModuleName WindowsMsix.Common -CommandName Get-Command { return $null }
      Mock -ModuleName WindowsMsix.Common -CommandName Test-Path { return $false }

      Resolve-WindowsSdkToolPath -ToolName 'nonexistent.exe' -OverridePath $null | Should -BeNullOrEmpty
    }

    It 'throws when an explicit override path does not exist' {
      Mock -ModuleName WindowsMsix.Common -CommandName Test-Path { return $false }

      { Resolve-WindowsSdkToolPath -ToolName 'signtool.exe' -OverridePath 'C:\does\not\exist.exe' } |
        Should -Throw -ExpectedMessage '*does not exist*'
    }
  }

  Context 'New-TransparentPng' {
    It 'writes a non-empty PNG file' {
      $out = Join-Path $script:tmp 't.png'
      New-TransparentPng -Path $out -Width 16 -Height 16

      Test-Path $out | Should -BeTrue
      (Get-Item -LiteralPath $out).Length | Should -BeGreaterThan 0
    }
  }

  Context 'Get-PackageVersion' {
    It 'pads a short version to the four components an AppxManifest needs' {
      $ws = (New-Item -ItemType Directory -Path (Join-Path $script:tmp 'v1') -Force).FullName
      Set-Content -LiteralPath (Join-Path $ws 'version.txt') -Value '1.2' -Encoding utf8
      Get-PackageVersion -WorkspacePath $ws | Should -Be '1.2.0.0'
    }

    It 'takes the digits out of a decorated version, and drops extra components' {
      $ws = (New-Item -ItemType Directory -Path (Join-Path $script:tmp 'v2') -Force).FullName
      Set-Content -LiteralPath (Join-Path $ws 'VERSION.txt') -Value "v3.4.5.6.7-rc1`n" -Encoding utf8
      Get-PackageVersion -WorkspacePath $ws | Should -Be '3.4.5.6'
    }

    It 'falls back to the default when there is no version file' {
      $ws = (New-Item -ItemType Directory -Path (Join-Path $script:tmp 'v3') -Force).FullName
      Get-PackageVersion -WorkspacePath $ws -Default '0.0.1.0' | Should -Be '0.0.1.0'
    }
  }

  Context 'Invoke-MsixPackage' {
    BeforeAll {
      # Provides Invoke-MsixSign, which -Sign checks for; the -Sign cases mock it.
      Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsMsix.Signing.psm1') `
        -Force -DisableNameChecking
      # makeappx is absent on CI runners, so this stub creates the file it would.
      $script:fakeMakeappx = {
        param([string]$File, [string[]]$Parameters)
        Set-Content -LiteralPath $Parameters[$Parameters.IndexOf('/p') + 1] -Value 'msix' -Encoding utf8
      }
      # The smallest template, for the cases that never read the manifest back.
      $script:bareTemplate = Join-Path $script:tmp 'bare.template.xml'
      Set-Content -LiteralPath $script:bareTemplate -Value '<Package/>' -Encoding utf8
    }

    BeforeEach {
      Mock -ModuleName WindowsMsix.Common -CommandName Resolve-WindowsSdkToolPath { 'C:\fake\makeappx.exe' }
    }

    It 'writes all four logo assets and an escaped manifest, then packs' {
      $ws = (New-Item -ItemType Directory -Path (Join-Path $script:tmp 'pkg') -Force).FullName
      $staging = Join-Path $ws 'staging'
      $template = Join-Path $ws 'AppxManifest.template.xml'
      Set-Content -LiteralPath $template -Encoding utf8 `
        -Value '<Package><Name>__PACKAGE_NAME__</Name><Desc>__DESCRIPTION__</Desc></Package>'
      $out = Join-Path $ws 'out\app_1.0.0.0_x64.msix'

      Invoke-MsixPackage -Context ([pscustomobject]@{}) -StagingDir $staging `
        -ManifestTemplatePath $template -OutputPath $out `
        -TokenMap @{ '__PACKAGE_NAME__' = 'App'; '__DESCRIPTION__' = 'A & B' } `
        -GenerateTransparentLogos -InvokerScriptBlock $script:fakeMakeappx | Out-Null

      foreach ($asset in @('StoreLogo.png', 'Square44x44Logo.png',
                           'Square150x150Logo.png', 'Wide310x150Logo.png')) {
        Test-Path (Join-Path $staging "Assets\$asset") | Should -BeTrue -Because "a package missing $asset fails to install with an error that names none of them"
      }
      (Get-Content -LiteralPath (Join-Path $staging 'AppxManifest.xml') -Raw) |
        Should -BeLike '*A &amp; B*'
      Test-Path $out | Should -BeTrue
    }

    It 'throws when makeappx reports success and produces nothing' {
      # Without this check the lane goes green and the artifact upload finds no file.
      $ws = Join-Path $script:tmp 'pkg2'

      { Invoke-MsixPackage -Context ([pscustomobject]@{}) -StagingDir (Join-Path $ws 'staging') `
          -ManifestTemplatePath $script:bareTemplate -OutputPath (Join-Path $ws 'out\nothing.msix') `
          -TokenMap @{} -GenerateTransparentLogos -InvokerScriptBlock { } } |
        Should -Throw -ExpectedMessage '*produced no package*'
    }

    # The certificate lives at the repository root, which only the caller knows.
    It 'refuses -Sign without -SigningRoot before it stages anything' {
      # Before the template is read, whose absence would otherwise be the error.
      $staging = Join-Path $script:tmp 'unrooted\staging'

      { Invoke-MsixPackage -Context ([pscustomobject]@{}) -StagingDir $staging `
          -ManifestTemplatePath (Join-Path $script:tmp 'no-such-template.xml') `
          -OutputPath (Join-Path $script:tmp 'unrooted\app.msix') `
          -TokenMap @{} -Sign -InvokerScriptBlock $script:fakeMakeappx } |
        Should -Throw -ExpectedMessage '*-SigningRoot*'
      Test-Path -LiteralPath $staging | Should -BeFalse -Because 'the check runs before any work'
    }

    It 'hands -SigningRoot to Invoke-MsixSign, not the staging directory''s parent' {
      Mock -ModuleName WindowsMsix.Common -CommandName Invoke-MsixSign { }
      $build = Join-Path $script:tmp 'rooted\build'
      $root = Join-Path $script:tmp 'rooted\repo'

      Invoke-MsixPackage -Context ([pscustomobject]@{}) -StagingDir (Join-Path $build 'msix\staging') `
        -ManifestTemplatePath $script:bareTemplate -OutputPath (Join-Path $build 'app.msix') `
        -TokenMap @{} -GenerateTransparentLogos -Sign -SigningRoot $root -InvokerScriptBlock $script:fakeMakeappx | Out-Null

      Should -Invoke -ModuleName WindowsMsix.Common -CommandName Invoke-MsixSign -Times 1 -Exactly `
        -ParameterFilter { $WorkspacePath -eq $root }
    }
  }

  Context 'Invoke-MsiPackage' {
    BeforeAll {
      $script:msiIn = (New-Item -ItemType Directory -Path (Join-Path $script:tmp 'msi-in') -Force).FullName
      'main.wxs', 'License.rtf', 'app.exe', 'wix.exe' | ForEach-Object { New-Item -ItemType File -Path (Join-Path $script:msiIn $_) -Force | Out-Null }
      # Records the argv and writes the -out file, as wix build does.
      $script:fakeWix = {
        param($exe, $argv)
        $script:wixCall = @{ Exe = $exe; Argv = $argv }
        $out = $argv[[array]::IndexOf($argv, '-out') + 1]
        Set-Content -LiteralPath $out -Value 'msi'
      }
      $script:msiArgs = @{
        Context = [pscustomobject]@{}; WxsFile = (Join-Path $script:msiIn 'main.wxs')
        LicenseFile = (Join-Path $script:msiIn 'License.rtf'); ExeSource = (Join-Path $script:msiIn 'app.exe')
        ProductName = 'App & Co'; Manufacturer = 'Kataglyphis'; Version = '1.2.3'; Arch = 'arm64'
        WixPath = (Join-Path $script:msiIn 'wix.exe'); InvokerScriptBlock = $script:fakeWix
      }
    }

    It 'hands every moving value to the .wxs as a preprocessor variable' {
      $out = Join-Path $script:tmp 'msi-out\app-1.2.3-arm64.msi'
      Invoke-MsiPackage @script:msiArgs -OutFile $out | Should -Be $out
      $argv = $script:wixCall.Argv -join ' '
      $argv | Should -BeLike 'build -arch arm64 -ext WixToolset.UI.wixext *'
      foreach ($d in 'Version=1.2.3', 'ProductName=App & Co', 'Manufacturer=Kataglyphis') {
        $script:wixCall.Argv | Should -Contain $d
      }
      $argv | Should -Not -BeLike '*PayloadFiles=1*' -Because 'no payload list means no fragment for main.wxs to include'
    }

    It 'writes one component per payload file, a Subdirectory only where one is given' {
      $frag = Join-Path $script:tmp 'msi-frag\payload.wxs'
      $files = @(
        [pscustomobject]@{ Source = 'C:\p\a&b.dll'; Subdirectory = '' }
        [pscustomobject]@{ Source = 'C:\p\lib\c.dll'; Subdirectory = 'lib' }
      )
      Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\p.msi') -PayloadFiles $files -FragmentPath $frag | Out-Null
      $script:wixCall.Argv[-1] | Should -Be $frag
      $xml = Get-Content -LiteralPath $frag -Raw
      $xml | Should -BeLike "*Id='payload0' Bitness='always64'><File Id='payloadFile0' Source='C:\p\a&amp;b.dll'*"
      $xml | Should -BeLike "*Id='payload1' Bitness='always64' Subdirectory='lib'>*"
    }

    It 'throws when wix build reports success and writes nothing' {
      { Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\none.msi') -InvokerScriptBlock { } } |
        Should -Throw -ExpectedMessage '*wix reported success but produced no package*'
    }

    It 'names the missing input before it runs anything' {
      $script:wixCall = $null
      { Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\x.msi') -LicenseFile 'C:\no\License.rtf' } |
        Should -Throw -ExpectedMessage '*the license*'
      $script:wixCall | Should -BeNullOrEmpty
    }

    It 'refuses a payload list without a fragment path' {
      { Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\y.msi') -PayloadFiles @([pscustomobject]@{ Source = 'a'; Subdirectory = '' }) } |
        Should -Throw -ExpectedMessage '*-FragmentPath*'
    }
  }

  Context 'Resolve-WixExe' {
    It 'throws when an explicit path does not exist' {
      { Resolve-WixExe -OverridePath 'C:\does\not\wix.exe' } | Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'takes wix.exe from $env:WIX before PATH' {
      $wixDir = (New-Item -ItemType Directory -Path (Join-Path $script:tmp 'wix-root') -Force).FullName
      Set-Content -LiteralPath (Join-Path $wixDir 'wix.exe') -Value 'x'
      Mock -ModuleName WindowsMsix.Common -CommandName Get-Command { [pscustomobject]@{ Source = 'C:\elsewhere\wix.exe' } }
      $saved = $env:WIX
      try {
        $env:WIX = $wixDir
        Resolve-WixExe -OverridePath '' | Should -Be (Join-Path $wixDir 'wix.exe')
      } finally { $env:WIX = $saved }
    }

    It 'returns $null when neither WIX nor PATH has it' {
      Mock -ModuleName WindowsMsix.Common -CommandName Get-Command { return $null }
      Mock -ModuleName WindowsMsix.Common -CommandName Test-Path { return $false }
      $saved = $env:WIX
      try {
        $env:WIX = ''
        Resolve-WixExe -OverridePath '' | Should -BeNullOrEmpty
      } finally { $env:WIX = $saved }
    }
  }
}
