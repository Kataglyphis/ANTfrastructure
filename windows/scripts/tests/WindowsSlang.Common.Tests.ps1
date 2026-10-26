#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The bash twin linux/scripts/lib/slang-compile.sh implements the same rules; change both together.

Describe 'WindowsSlang.Common' {
  BeforeAll {
    function New-SlangFixtureShader {
      param([string]$Workspace, [string]$Directory, [string]$File)
      $root = (New-Item -ItemType Directory -Force -Path (Join-Path $Workspace $Directory)).FullName
      $shader = Join-Path $root $File
      Set-Content -LiteralPath $shader -Value 'void main() {}'
      return [pscustomobject]@{ Root = $root; Shader = $shader }
    }

    function New-SlangFixtureRootPair {
      param([string]$Workspace, [string]$Prefix)
      $primary = (New-Item -ItemType Directory -Force -Path (Join-Path $Workspace "$Prefix-primary")).FullName
      $secondary = New-SlangFixtureShader -Workspace $Workspace -Directory "$Prefix-secondary" -File 'owned.slang'
      return [pscustomobject]@{ Primary = $primary; Secondary = $secondary.Root; Shader = $secondary.Shader }
    }

    function New-SlangFixtureEntry {
      param([string]$File, [string[]]$Targets)
      return [pscustomobject]@{ file = $File; entry = 'main'; stage = 'compute'; targets = $Targets }
    }

    function New-SlangFixtureCompiler {
      param([string]$Workspace, [string]$Wgsl)
      $scriptPath = Join-Path $Workspace ("slangc-" + [IO.Path]::GetFileNameWithoutExtension($Wgsl) + '.cmd')
      [IO.File]::WriteAllLines($scriptPath, @(
        '@echo off',
        'if "%~1"=="-version" (',
        '  echo 2026.8',
        '  exit /b 0',
        ')',
        ':seek',
        'if "%~1"=="-o" goto emit',
        'if "%~1"=="" exit /b 2',
        'shift',
        'goto seek',
        ':emit',
        "copy /Y `"$Wgsl`" `"%~2`" >nul",
        'exit /b %errorlevel%'
      ), [Text.Encoding]::ASCII)
      return $scriptPath
    }

    function New-SlangFixtureManifestPair {
      param([string]$Workspace, [string]$Prefix, [string]$OwnerJson, [string]$DestinationPrefix = '')
      $ownerName = "$Prefix-owner.json"
      $owner = Join-Path $Workspace $ownerName
      $consumer = Join-Path $Workspace "$Prefix-consumer.json"
      Set-Content -LiteralPath $owner -Value $OwnerJson
      $consumerData = [ordered]@{ manifest = @(); wgslManifest = $ownerName }
      if ($DestinationPrefix) { $consumerData['wgslDestinationPrefix'] = $DestinationPrefix }
      Set-Content -LiteralPath $consumer -Value (ConvertTo-Json -InputObject $consumerData -Depth 4 -Compress)
      return [pscustomobject]@{ Owner = $owner; Consumer = $consumer }
    }

    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSlang.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = New-TestDir -Prefix 'slang-'

    # An IO struct with one member lacking @builtin and @location, as slangc < 2026.8 emitted in combined mode.
    $script:badWgsl = Join-Path $script:root 'bad.wgsl'
    Set-Content -Path $script:badWgsl -Encoding utf8 -Value @(
      'struct VertexOut'
      '{'
      '    @builtin(position) pos : vec4<f32>,'
      '    uv_0 : vec2<f32>,'
      '    @location(1) normal_0 : vec3<f32>,'
      '};'
      ''
      'struct PlainData'
      '{'
      '    a : f32,'
      '    b : f32,'
      '};'
    )

    $script:goodWgsl = Join-Path $script:root 'good.wgsl'
    Set-Content -Path $script:goodWgsl -Encoding utf8 -Value @(
      'struct VertexOut'
      '{'
      '    @builtin(position) pos : vec4<f32>,'
      '    @location(0) uv_0 : vec2<f32>,'
      '};'
    )
  }

  AfterAll {
    Remove-TestDir -Path $script:root
  }

  Context 'Test-WgslVaryingsAreLocated' {
    It 'names the file line of a varying member without @builtin/@location' {
      $offenders = Test-WgslVaryingsAreLocated -Path $script:badWgsl
      $offenders.Count | Should -Be 1
      $offenders[0] | Should -Match '^4: struct VertexOut: uv_0'
    }

    It 'accepts a struct whose every member is attributed' {
      (Test-WgslVaryingsAreLocated -Path $script:goodWgsl).Count | Should -Be 0
    }

    It 'ignores plain data structs (no @builtin/@location member at all)' {
      $plain = Join-Path $script:root 'plain.wgsl'
      Set-Content -Path $plain -Encoding utf8 -Value @('struct Params', '{', '    a : f32,', '    b : vec4<f32>,', '};')
      (Test-WgslVaryingsAreLocated -Path $plain).Count | Should -Be 0
    }
  }

  Context 'Pinned shader owners' {
    It 'resolves another root and adds its common modules to include paths' {
      $roots = New-SlangFixtureRootPair -Workspace $script:root -Prefix 'pinned'
      $common = (New-Item -ItemType Directory -Force -Path (Join-Path $roots.Secondary 'common')).FullName
      (Resolve-SlangSourcePath -Relative 'owned.slang' -SourceRoot $roots.Primary -AdditionalSourceRoots @($roots.Secondary)) | Should -Be $roots.Shader
      $include = Get-SlangIncludeArgument -SourceRoot $roots.Primary -SourceDirectory $roots.Primary -AdditionalSourceRoots @($roots.Secondary)
      $include | Should -Contain $common
    }

    It 'imports owner entries and prefixes only their destinations' {
      $pair = New-SlangFixtureManifestPair -Workspace $script:root -Prefix 'manifest' -DestinationPrefix 'third_party/owner' `
        -OwnerJson '{"manifest":[{"file":"owned.slang"}],"wgslMap":[{"src":"owned.slang","out":"shader.wgsl","dst":"crate"}],"depthTexturePatches":{},"minSlangcVersionForWgsl":"2026.8"}'
      $doc = Get-SlangShaderManifest -Path $pair.Consumer
      $doc.manifest[0].file | Should -Be 'owned.slang'
      $doc.wgslMap[0].dst | Should -Be (Join-Path 'third_party/owner' 'crate')
      $doc.minSlangcVersionForWgsl | Should -Be '2026.8'
    }
  }

  # Parity checks manifest rows, not a compiler that never ran or a missing row in that manifest.
  Context 'Assert-SlangWgslOutputsMatch' {
    It 'accepts newline-only differences across every manifest destination' {
      $combined = Join-Path $script:root 'parity-newlines-combined'
      $destination = Join-Path $script:root 'parity-newlines-pinned'
      New-Item -ItemType Directory -Force -Path $combined, (Join-Path $destination 'crate') | Out-Null
      [IO.File]::WriteAllText((Join-Path $combined 'combined_a.wgsl'), "fn a() {}`n")
      [IO.File]::WriteAllText((Join-Path $combined 'combined_b.wgsl'), "fn b() {}`n")
      [IO.File]::WriteAllText((Join-Path $destination 'crate/a.wgsl'), "fn a() {}`r`n")
      [IO.File]::WriteAllText((Join-Path $destination 'crate/b.wgsl'), "fn b() {}`r`n")
      $rows = @([pscustomobject]@{ out = 'a.wgsl'; dst = 'crate' }, [pscustomobject]@{ out = 'b.wgsl'; dst = 'crate' })
      $verified = @(Assert-SlangWgslOutputsMatch -Mappings $rows -CombinedOutputDir $combined -DestinationRoot $destination)
      $verified.Count | Should -Be 2
      $verified[0].Name | Should -Be 'a.wgsl'
      $verified[1].Generated | Should -Be (Join-Path $combined 'combined_b.wgsl')
    }

    It 'fails on a changed non-newline byte and an omitted emitted file' {
      $combined = Join-Path $script:root 'parity-mutant-combined'
      $destination = Join-Path $script:root 'parity-mutant-pinned'
      New-Item -ItemType Directory -Force -Path $combined, (Join-Path $destination 'crate') | Out-Null
      [IO.File]::WriteAllText((Join-Path $combined 'combined_a.wgsl'), "fn a() {}`n")
      [IO.File]::WriteAllText((Join-Path $destination 'crate/a.wgsl'), "fn wrong() {}`n")
      [IO.File]::WriteAllText((Join-Path $destination 'crate/b.wgsl'), "fn b() {}`n")
      $rows = @([pscustomobject]@{ out = 'a.wgsl'; dst = 'crate' }, [pscustomobject]@{ out = 'b.wgsl'; dst = 'crate' })
      { Assert-SlangWgslOutputsMatch -Mappings $rows -CombinedOutputDir $combined -DestinationRoot $destination } |
        Should -Throw -ExpectedMessage '*a.wgsl differs*missing generated b.wgsl*'
      [IO.File]::WriteAllText((Join-Path $destination 'crate/a.wgsl'), "fn a() {}`r")
      { Assert-SlangWgslOutputsMatch -Mappings $rows -CombinedOutputDir $combined -DestinationRoot $destination } |
        Should -Throw -ExpectedMessage '*a.wgsl differs*'
    }

    It 'rejects an empty or duplicate manifest mapping' {
      $combined = Join-Path $script:root 'parity-invalid-combined'
      $destination = Join-Path $script:root 'parity-invalid-pinned'
      { Assert-SlangWgslOutputsMatch -Mappings @() -CombinedOutputDir $combined -DestinationRoot $destination } |
        Should -Throw -ExpectedMessage '*no manifest mappings*'
      $rows = @([pscustomobject]@{ out = 'a.wgsl'; dst = 'one' }, [pscustomobject]@{ out = 'A.wgsl'; dst = 'two' })
      { Assert-SlangWgslOutputsMatch -Mappings $rows -CombinedOutputDir $combined -DestinationRoot $destination } |
        Should -Throw -ExpectedMessage '*duplicate WGSL output name*'
    }

    It 'rejects invalid UTF-8 rather than comparing replacement characters' {
      $combined = Join-Path $script:root 'parity-encoding-combined'
      $destination = Join-Path $script:root 'parity-encoding-pinned'
      New-Item -ItemType Directory -Force -Path $combined, (Join-Path $destination 'crate') | Out-Null
      [IO.File]::WriteAllBytes((Join-Path $combined 'combined_a.wgsl'), [byte[]]@(0xff))
      [IO.File]::WriteAllText((Join-Path $destination 'crate/a.wgsl'), 'fn a() {}')
      { Assert-SlangWgslOutputsMatch -Mappings @([pscustomobject]@{ out = 'a.wgsl'; dst = 'crate' }) `
          -CombinedOutputDir $combined -DestinationRoot $destination } | Should -Throw
    }
  }

  Context 'Test-SlangcVersionAtLeast' {
    It 'rejects the slangc whose combined WGSL emit drops @location' {
      Test-SlangcVersionAtLeast -Have '2026.1-52-gc8ddf20bb' -Want '2026.8' | Should -Be $false
    }

    It 'accepts the floor itself and anything newer' {
      Test-SlangcVersionAtLeast -Have '2026.8' -Want '2026.8' | Should -Be $true
      Test-SlangcVersionAtLeast -Have '2026.9' -Want '2026.8' | Should -Be $true
      Test-SlangcVersionAtLeast -Have '2027.0' -Want '2026.8' | Should -Be $true
    }

    It 'treats an unparseable version as new enough (the emit guard is the backstop)' {
      Test-SlangcVersionAtLeast -Have 'some-dev-build' -Want '2026.8' | Should -Be $true
      Test-SlangcVersionAtLeast -Have '2026.8' -Want '' | Should -Be $true
    }
  }

  Context 'Get-SlangIncludeArgument' {
    It 'passes the source root, the shader directory and every subdirectory to -I' {
      $tree = Join-Path $script:root 'tree'
      New-Item -ItemType Directory -Force -Path (Join-Path $tree 'common') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $tree 'forward') | Out-Null

      $argv = Get-SlangIncludeArgument -SourceRoot $tree -SourceDirectory (Join-Path $tree 'forward')
      @($argv | Where-Object { $_ -eq '-I' }).Count | Should -Be 4
      ($argv -contains $tree) | Should -Be $true
      ($argv -contains (Join-Path $tree 'common')) | Should -Be $true
      ($argv -contains (Join-Path $tree 'forward')) | Should -Be $true
    }
  }

  Context 'Compile staging' {
    It 'treats owner manifests and additional roots as inputs for cache staleness' {
      $roots = New-SlangFixtureRootPair -Workspace $script:root -Prefix 'stamp'
      $pair = New-SlangFixtureManifestPair -Workspace $script:root -Prefix 'stamp' `
        -OwnerJson '{"manifest":[],"wgslMap":[],"depthTexturePatches":{},"minSlangcVersionForWgsl":"2026.8"}'
      $owner = $pair.Owner
      $consumer = $pair.Consumer
      $stamp = [datetime]::UtcNow.AddHours(-3)
      (Get-Item $roots.Shader).LastWriteTimeUtc = $stamp.AddHours(1)
      (Get-Item $consumer).LastWriteTimeUtc = $stamp
      (Get-Item $owner).LastWriteTimeUtc = $stamp.AddHours(2)
      $manifest = Get-SlangShaderManifest -Path $consumer

      InModuleScope WindowsSlang.Common -Parameters @{
        Primary = $roots.Primary; Additional = $roots.Secondary; Consumer = $consumer; Manifest = $manifest
      } -ScriptBlock {
        $newest = Get-SlangNewestInputStamp -SourceRoot $Primary -AdditionalSourceRoots @($Additional) -ManifestPath $Consumer -Manifest $Manifest
        $newest | Should -Be (Get-Item (Join-Path (Split-Path $Consumer -Parent) 'stamp-owner.json')).LastWriteTimeUtc
      }
    }

    It 'skips current artifacts for both targets without invoking slangc' {
      $cached = New-SlangFixtureShader -Workspace $script:root -Directory 'cached-source' -File 'cached.slang'
      $source = $cached.Root
      $spirv = (New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'cached-spirv')).FullName
      $wgsl = (New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'cached-wgsl')).FullName
      $shader = $cached.Shader
      $entry = New-SlangFixtureEntry -File 'cached.slang' -Targets @('spirv', 'wgsl')
      Set-Content -LiteralPath (Join-Path $spirv 'cached.main.spv') -Value 'cached'
      Set-Content -LiteralPath (Join-Path $wgsl 'cached.main.wgsl') -Value 'cached'
      $oldStamp = [datetime]::UtcNow.AddHours(-1)
      $newStamp = [datetime]::UtcNow
      (Get-Item $shader).LastWriteTimeUtc = $oldStamp
      (Get-Item (Join-Path $spirv 'cached.main.spv')).LastWriteTimeUtc = $newStamp
      (Get-Item (Join-Path $wgsl 'cached.main.wgsl')).LastWriteTimeUtc = $newStamp

      InModuleScope WindowsSlang.Common -Parameters @{
        Source = $source; Spirv = $spirv; Wgsl = $wgsl; Entry = $entry; Stamp = $oldStamp
      } -ScriptBlock {
        $result = Invoke-SlangManifestEntry -Entry $Entry -SourceRoot $Source -SpirvOutputRoot $Spirv `
          -WgslOutputRoot $Wgsl -NewestSource $Stamp -Slangc 'missing-slangc.exe'
        $result.Compiled | Should -Be 0
        $result.Failures.Count | Should -Be 0
      }
    }

    It 'reports a missing manifest shader as a failed entry' {
      $source = (New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'missing-source')).FullName
      $entry = New-SlangFixtureEntry -File 'gone.slang' -Targets @('spirv')
      InModuleScope WindowsSlang.Common -Parameters @{ Source = $source; Entry = $entry } -ScriptBlock {
        $result = Invoke-SlangManifestEntry -Entry $Entry -SourceRoot $Source -SpirvOutputRoot $Source `
          -WgslOutputRoot $Source -NewestSource ([datetime]::UtcNow) -Slangc 'missing-slangc.exe' 3>$null
        $result.Compiled | Should -Be 0
        $result.Failures | Should -Contain (Join-Path $Source 'gone.slang')
      }
    }

    It 'copies valid combined WGSL but preserves the destination for an invalid emit' {
      $root = (New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'combined-source')).FullName
      Set-Content -LiteralPath (Join-Path $root 'owned.slang') -Value 'void main() {}'
      $stage = (New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'combined-stage')).FullName
      $destination = (New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'combined-dest')).FullName
      $manifest = [pscustomobject]@{
        wgslMap = @([pscustomobject]@{ src = 'owned.slang'; out = 'owned.wgsl'; dst = 'crate' })
        depthTexturePatches = [pscustomobject]@{}
        minSlangcVersionForWgsl = '2026.8'
      }
      $goodCompiler = New-SlangFixtureCompiler -Workspace $script:root -Wgsl $script:goodWgsl
      $badCompiler = New-SlangFixtureCompiler -Workspace $script:root -Wgsl $script:badWgsl
      $target = Join-Path $destination 'crate\owned.wgsl'

      InModuleScope WindowsSlang.Common -Parameters @{
        Root = $root; Stage = $stage; Destination = $destination; Manifest = $manifest
        GoodCompiler = $goodCompiler; BadCompiler = $badCompiler; Target = $target
      } -ScriptBlock {
        $good = Invoke-SlangCombinedEmits -Manifest $Manifest -SourceRoot $Root -CombinedOutputDir $Stage `
          -DestinationRoot $Destination -Slangc $GoodCompiler
        $good.Emitted | Should -Be 1
        $good.Invalid.Count | Should -Be 0
        (Test-Path -LiteralPath $Target -PathType Leaf) | Should -BeTrue

        Set-Content -LiteralPath $Target -Value 'keep-me'
        $bad = Invoke-SlangCombinedEmits -Manifest $Manifest -SourceRoot $Root -CombinedOutputDir $Stage `
          -DestinationRoot $Destination -Slangc $BadCompiler 3>$null
        $bad.Emitted | Should -Be 0
        $bad.Invalid | Should -Contain 'owned.wgsl'
        (Get-Content -LiteralPath $Target -Raw).Trim() | Should -Be 'keep-me'
      }
    }
  }

  Context 'Resolve-Slangc' {
    It 'prefers VULKAN_SDK\Bin\slangc.exe over PATH' {
      $sdk = Join-Path $script:root 'sdk'
      New-Item -ItemType Directory -Force -Path (Join-Path $sdk 'Bin') | Out-Null
      Set-Content -Path (Join-Path $sdk 'Bin\slangc.exe') -Value 'not a real binary'

      $saved = $env:VULKAN_SDK
      try {
        $env:VULKAN_SDK = $sdk
        Resolve-Slangc | Should -Be (Join-Path $sdk 'Bin\slangc.exe')
      } finally {
        $env:VULKAN_SDK = $saved
      }
    }
  }
}
