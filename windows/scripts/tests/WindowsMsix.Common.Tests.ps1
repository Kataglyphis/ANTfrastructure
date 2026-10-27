#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Staging and tool wiring are tested here; this suite does not build or install a real MSI or MSIX.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.TextFixtures.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WindowsMsixLicenseFixture.psm1') -DisableNameChecking -ErrorAction Stop
function script:Assert-MsixRenderedImage {
  param([string]$Path, [int]$Width, [int]$Height)
  $image = [System.Drawing.Bitmap]::new($Path)
  try {
    $image.Width | Should -Be $Width
    $image.Height | Should -Be $Height
    $center = $image.GetPixel([int]($Width / 2), [int]($Height / 2))
    $center.A | Should -BeGreaterThan 0
    $center.R | Should -BeGreaterThan 200
    $image.GetPixel(0, 0).A | Should -Be 0
  } finally { $image.Dispose() }
}


Describe 'WindowsMsix.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsMsix.Common.psm1'
    Import-Module $modulePath -Force

    $script:tmp = New-TestDir -Prefix 'msix-common-'
  }

  AfterAll {
    Remove-TestDir -Path $script:tmp
  }
  Context 'Copy-PackageLicense' {
    It 'copies the complete licence and refuses missing or empty terms' {
      Invoke-InTestDir -Body { param($ws) Assert-TestPackageLicense -Root $ws }
    }
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

      Assert-Throws -MessagePattern 'does not exist' -Body {
        Resolve-WindowsSdkToolPath -ToolName 'signtool.exe' -OverridePath 'C:\does\not\exist.exe'
      }
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
      Invoke-InTestDir -Files @{ 'version.txt' = "1.2$([Environment]::NewLine)" } -Body { param($ws)
        Get-PackageVersion -WorkspacePath $ws | Should -Be '1.2.0.0'
      }
    }

    It 'takes the digits out of a decorated version, and drops extra components' {
      Invoke-InTestDir -Files @{ 'VERSION.txt' = "v3.4.5.6.7-rc1`n$([Environment]::NewLine)" } -Body { param($ws)
        Get-PackageVersion -WorkspacePath $ws | Should -Be '3.4.5.6'
      }
    }

    It 'takes CMakeLists.txt project() VERSION when there is no version file, as CPack does' {
      $cmake = @('cmake_minimum_required(VERSION 3.25)', 'project(', '  Demo', '  VERSION 0.0.2', '  LANGUAGES CXX)')
      Invoke-InTestDir -Files @{ 'CMakeLists.txt' = (ConvertTo-TestFileText -Line $cmake) } -Body { param($ws)
        Get-PackageVersion -WorkspacePath $ws -Default '0.0.1.0' | Should -Be '0.0.2.0'
      }
    }

    It 'lets a version file win over CMakeLists.txt' {
      Invoke-InTestLineDir -LineFiles @{ 'CMakeLists.txt' = @('project(Demo VERSION 9.9.9)'); 'VERSION.txt' = @('1.5.1') } -Body { param($ws)
        Get-PackageVersion -WorkspacePath $ws | Should -Be '1.5.1.0'
      }
    }

    It 'falls back to the default when there is no version file' {
      Invoke-InTestDir { param($ws)
        Get-PackageVersion -WorkspacePath $ws -Default '0.0.1.0' | Should -Be '0.0.1.0'
      }
    }

    It 'reads -VersionFile as version_util.sh --file-version does, pyproject.toml too' {
      Invoke-InTestDir -Body { param($ws)
        Set-Content -LiteralPath (Join-Path $ws 'Cargo.toml') -Encoding utf8 -Value @(
          '[package]', 'name = "x"', 'version = "2.3.4-rc1"', '[dependencies]', 'serde = { version = "1" }', '[workspace.package]', 'version = "5.6.7"')
        Set-Content -LiteralPath (Join-Path $ws 'pubspec.yaml') -Encoding utf8 -Value @('name: app', 'version: 2.0.0+2')
        Set-Content -LiteralPath (Join-Path $ws 'pyproject.toml') -Encoding utf8 -Value @(
          '[tool.other]', 'version = "9.9"', '[project]', 'name = "p"', 'version = "0.10.1"')
        Get-PackageVersion -WorkspacePath $ws -VersionFile 'Cargo.toml' -Required | Should -Be '5.6.7.0'
        Get-PackageVersion -WorkspacePath $ws -VersionFile 'pubspec.yaml' -Components 3 -Required | Should -Be '2.0.0'
        Get-PackageVersion -WorkspacePath $ws -VersionFile (Join-Path $ws 'pyproject.toml') | Should -Be '0.10.1.0'
        Write-TestFileTree -Root $ws -Files @{ 'Cargo.toml' = (ConvertTo-TestFileText -Line @('[package]', 'version = "2.3.4-rc1"')) }
        Get-PackageVersion -WorkspacePath $ws -VersionFile 'Cargo.toml' | Should -Be '2.3.4.0'
      }
    }

    It 'throws with -Required instead of falling back to the default' {
      Invoke-InTestDir { param($ws)
        Assert-Throws -MessagePattern 'no version in.*VERSION\.txt.*refuses the 0\.0\.1\.0 fallback' -Body {
          Get-PackageVersion -WorkspacePath $ws -Required
        }
        Assert-Throws -MessagePattern 'no version in.*pubspec\.yaml' -Body {
          Get-PackageVersion -WorkspacePath $ws -VersionFile 'pubspec.yaml' -Required
        }
        Write-TestFileTree -Root $ws -Files @{ 'Cargo.toml' = (ConvertTo-TestFileText -Line @('[package]', 'version.workspace = true')) }
        Assert-Throws -MessagePattern 'no version in.*Cargo\.toml' -Body {
          Get-PackageVersion -WorkspacePath $ws -VersionFile 'Cargo.toml' -Required
        }
        Get-PackageVersion -WorkspacePath $ws -VersionFile 'Cargo.toml' | Should -Be '0.0.1.0'
      }
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

    It 'resizes a visible project logo to every required size without stretching it' {
      $ws = Join-Path $script:tmp 'real-logos'
      New-Item -ItemType Directory -Path $ws -Force | Out-Null
      $logoPath = Join-Path $ws 'logo.png'
      Copy-Item -LiteralPath (Join-Path (Get-RepoRoot) 'images/logo.png') -Destination $logoPath
      $staging = Join-Path $ws 'staging'
      Invoke-MsixPackage -Context ([pscustomobject]@{}) -StagingDir $staging -LogoPath $logoPath `
        -ManifestTemplatePath $script:bareTemplate -OutputPath (Join-Path $ws 'app.msix') `
        -TokenMap @{} -InvokerScriptBlock $script:fakeMakeappx | Out-Null
      $cases = @('StoreLogo.png 50 50', 'Square44x44Logo.png 44 44',
        'Square150x150Logo.png 150 150', 'Wide310x150Logo.png 310 150')
      foreach ($case in $cases) {
        $parts = $case -split ' '
        Assert-MsixRenderedImage -Path (Join-Path $staging "Assets\$($parts[0])") -Width $parts[1] -Height $parts[2]
      }
    }

    It 'rejects missing, malformed, non-PNG and fully transparent project logos' {
      $ws = Join-Path $script:tmp 'bad-logos'
      New-Item -ItemType Directory -Path $ws -Force | Out-Null
      $packageArguments = @{ Context = [pscustomobject]@{}; StagingDir = (Join-Path $ws 'stage');
        ManifestTemplatePath = $script:bareTemplate; OutputPath = (Join-Path $ws 'out.msix');
        TokenMap = @{}; InvokerScriptBlock = $script:fakeMakeappx }
      Assert-Throws -MessagePattern 'logo not found' -Body { Invoke-MsixPackage @packageArguments -LogoPath (Join-Path $ws 'missing.png') }
      $bad = Join-Path $ws 'bad.png'
      [IO.File]::WriteAllText($bad, 'not an image')
      Assert-Throws -MessagePattern 'not a readable image' -Body { Invoke-MsixPackage @packageArguments -LogoPath $bad }
      $transparent = Join-Path $ws 'transparent.png'
      New-TransparentPng -Path $transparent -Width 8 -Height 8
      Assert-Throws -MessagePattern 'visible PNG' -Body { Invoke-MsixPackage @packageArguments -LogoPath $transparent }
      $jpeg = Join-Path $ws 'logo.jpg'
      $image = [System.Drawing.Bitmap]::new(8, 8)
      try { $image.Save($jpeg, [System.Drawing.Imaging.ImageFormat]::Jpeg) } finally { $image.Dispose() }
      Assert-Throws -MessagePattern 'visible PNG' -Body { Invoke-MsixPackage @packageArguments -LogoPath $jpeg }
      Test-Path -LiteralPath $packageArguments.OutputPath | Should -BeFalse
    }

    It 'throws when makeappx reports success and produces nothing' {
      # Without this check the lane goes green and the artifact upload finds no file.
      $ws = Join-Path $script:tmp 'pkg2'

      Assert-Throws -MessagePattern 'produced no package' -Body {
        Invoke-MsixPackage -Context ([pscustomobject]@{}) -StagingDir (Join-Path $ws 'staging') `
          -ManifestTemplatePath $script:bareTemplate -OutputPath (Join-Path $ws 'out\nothing.msix') `
          -TokenMap @{} -GenerateTransparentLogos -InvokerScriptBlock { }
      }
    }

    # The certificate lives at the repository root, which only the caller knows.
    It 'refuses -Sign without -SigningRoot before it stages anything' {
      # Before the template is read, whose absence would otherwise be the error.
      $staging = Join-Path $script:tmp 'unrooted\staging'

      Assert-Throws -MessagePattern '-SigningRoot' -Body {
        Invoke-MsixPackage -Context ([pscustomobject]@{}) -StagingDir $staging `
          -ManifestTemplatePath (Join-Path $script:tmp 'no-such-template.xml') `
          -OutputPath (Join-Path $script:tmp 'unrooted\app.msix') `
          -TokenMap @{} -Sign -InvokerScriptBlock $script:fakeMakeappx
      }
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

    It 'with -RequireSignature signs and throws on a package that came out unsigned or signed by another subject' {
      Mock -ModuleName WindowsMsix.Common -CommandName Invoke-MsixSign { }
      $build = Join-Path $script:tmp 'required\build'
      $package = @{ Context = ([pscustomobject]@{}); StagingDir = (Join-Path $build 'staging'); ManifestTemplatePath = $script:bareTemplate
        OutputPath = (Join-Path $build 'app.msix'); TokenMap = @{}; GenerateTransparentLogos = $true; SigningRoot = $build
        InvokerScriptBlock = $script:fakeMakeappx; RequireSignature = $true; SignerSubject = 'CN=Pub' }
      Mock -ModuleName WindowsMsix.Common -CommandName Get-AuthenticodeSignature { [pscustomobject]@{ SignerCertificate = $null } }
      Assert-Throws -MessagePattern 'app\.msix is not signed' -Body { Invoke-MsixPackage @package }
      Should -Invoke -ModuleName WindowsMsix.Common -CommandName Invoke-MsixSign -Times 1 -Exactly
      Mock -ModuleName WindowsMsix.Common -CommandName Get-AuthenticodeSignature { [pscustomobject]@{ SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other' } } }
      Assert-Throws -MessagePattern 'signed by CN=Other, not CN=Pub' -Body { Invoke-MsixPackage @package }
      Mock -ModuleName WindowsMsix.Common -CommandName Get-AuthenticodeSignature { [pscustomobject]@{ SignerCertificate = [pscustomobject]@{ Subject = 'CN=Pub' } } }
      Invoke-MsixPackage @package | Should -Be $package.OutputPath
      $package.Remove('SigningRoot')
      Assert-Throws -MessagePattern '-SigningRoot' -Body { Invoke-MsixPackage @package }
    }
  }

  Context 'Invoke-MsiPackage' {
    BeforeAll {
      $script:msiIn = Join-Path $script:tmp 'msi-in'
      Write-TestFileTree -Root $script:msiIn -Files @{ 'main.wxs' = ''; 'License.rtf' = ''; 'app.exe' = ''; 'wix.exe' = '' }
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

    It 'passes additional WiX variables as distinct argv tokens and preserves spaces' {
      $icon = Join-Path $script:tmp 'icon dir\project icon.ico'
      Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\extra.msi') `
        -WixVariables @{ IconSource = $icon } | Out-Null
      $idx = [array]::IndexOf($script:wixCall.Argv, "IconSource=$icon")
      $idx | Should -BeGreaterThan 0
      $script:wixCall.Argv[$idx - 1] | Should -Be '-d'
    }

    It 'rejects invalid and reserved WiX variables before invoking the tool' {
      foreach ($name in 'Version', 'ExeSource', 'PayloadFiles', 'bad-name', 'x y') {
        $script:wixCall = $null
        Assert-Throws -MessagePattern 'Invalid or reserved WiX variable name' -Body {
          Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\invalid.msi') -WixVariables @{ $name = 'x' }
        }
        $script:wixCall | Should -BeNullOrEmpty
      }
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
      Assert-Throws -MessagePattern 'wix reported success but produced no package' -Body {
        Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\none.msi') -InvokerScriptBlock { }
      }
    }

    It 'names the missing input before it runs anything' {
      $script:wixCall = $null
      Assert-Throws -MessagePattern 'the license' -Body {
        Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\x.msi') -LicenseFile 'C:\no\License.rtf'
      }
      $script:wixCall | Should -BeNullOrEmpty
    }

    It 'refuses a payload list without a fragment path' {
      Assert-Throws -MessagePattern '-FragmentPath' -Body {
        Invoke-MsiPackage @script:msiArgs -OutFile (Join-Path $script:tmp 'msi-out\y.msi') -PayloadFiles @([pscustomobject]@{ Source = 'a'; Subdirectory = '' })
      }
    }
  }

  Context 'Resolve-WixExe' {
    It 'throws when an explicit path does not exist' {
      Assert-Throws -MessagePattern 'does not exist' -Body { Resolve-WixExe -OverridePath 'C:\does\not\wix.exe' }
    }

    It 'takes wix.exe from $env:WIX before PATH' {
      $wixDir = Join-Path $script:tmp 'wix-root'
      Write-TestFileTree -Root $wixDir -Files @{ 'wix.exe' = "x$([Environment]::NewLine)" }
      Mock -ModuleName WindowsMsix.Common -CommandName Get-Command { [pscustomobject]@{ Source = 'C:\elsewhere\wix.exe' } }
      Invoke-WithEnv @{ WIX = $wixDir } {
        Resolve-WixExe -OverridePath '' | Should -Be (Join-Path $wixDir 'wix.exe')
      }
    }

    It 'returns $null when neither WIX nor PATH has it' {
      Mock -ModuleName WindowsMsix.Common -CommandName Get-Command { return $null }
      Mock -ModuleName WindowsMsix.Common -CommandName Test-Path { return $false }
      Invoke-WithEnv @{ WIX = '' } {
        Resolve-WixExe -OverridePath '' | Should -BeNullOrEmpty
      }
    }
  }
}
