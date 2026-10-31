#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The bash twin linux/scripts/lib/slang-compile.sh implements the same rules; change both together.

Describe 'WindowsSlang.Common' {
  BeforeAll {
    function New-SlangFixtureDirectory {
      param([string]$Workspace, [string]$Name)
      return (New-Item -ItemType Directory -Force -Path (Join-Path $Workspace $Name)).FullName
    }

    function New-SlangFixtureShader {
      param([string]$Workspace, [string]$Directory, [string]$File)
      $root = New-SlangFixtureDirectory -Workspace $Workspace -Name $Directory
      $shader = Join-Path $root $File
      Set-Content -LiteralPath $shader -Value 'void main() {}'
      return [pscustomobject]@{ Root = $root; Shader = $shader }
    }

    function New-SlangFixtureRootPair {
      param([string]$Workspace, [string]$Prefix)
      $primary = New-SlangFixtureDirectory -Workspace $Workspace -Name "$Prefix-primary"
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

    function New-SlangParityFixture {
      param([string]$Prefix, [string[]]$Outputs = @('a.wgsl', 'b.wgsl'),
        [Collections.IDictionary]$Generated = @{}, [Collections.IDictionary]$Pinned = @{})
      $combined = Join-Path $script:root "$Prefix-combined"
      $destination = Join-Path $script:root "$Prefix-pinned"
      New-Item -ItemType Directory -Force -Path $combined, (Join-Path $destination 'crate') | Out-Null
      $mappings = @($Outputs | ForEach-Object { [pscustomobject]@{ out = $_; dst = 'crate' } })
      $fixture = [pscustomobject]@{ Combined = $combined; Destination = $destination; Mappings = $mappings }
      foreach ($name in $Generated.Keys) {
        Set-SlangParityContent -Fixture $fixture -Name $name -Text ([string]$Generated[$name]) -Generated
      }
      foreach ($name in $Pinned.Keys) {
        Set-SlangParityContent -Fixture $fixture -Name $name -Text ([string]$Pinned[$name])
      }
      return $fixture
    }

    function Invoke-SlangFixtureEntry {
      param([object]$Entry, [string]$Source, [string]$Spirv, [string]$Wgsl, [datetime]$Stamp)
      InModuleScope WindowsSlang.Common -Parameters @{
        Entry = $Entry; Source = $Source; Spirv = $Spirv; Wgsl = $Wgsl; Stamp = $Stamp
      } -ScriptBlock {
        Invoke-SlangManifestEntry -Entry $Entry -SourceRoot $Source -SpirvOutputRoot $Spirv `
          -WgslOutputRoot $Wgsl -NewestSource $Stamp -Slangc 'missing-slangc.exe' 3>$null
      }
    }

    function Invoke-SlangFixtureParity {
      param([object]$Fixture, [string]$ExpectedRoot)
      $root = if ($ExpectedRoot) { $ExpectedRoot } else { $Fixture.Destination }
      Assert-SlangWgslOutputsMatch -Mappings $Fixture.Mappings -CombinedOutputDir $Fixture.Combined -DestinationRoot $root
    }

    function Set-SlangParityContent {
      param([object]$Fixture, [string]$Name, [string]$Text, [switch]$Generated)
      $path = if ($Generated) { Join-Path $Fixture.Combined "combined_$Name" } else { Join-Path $Fixture.Destination "crate/$Name" }
      [IO.File]::WriteAllText($path, $Text)
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
      $common = New-SlangFixtureDirectory -Workspace $roots.Secondary -Name 'common'
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
      $fixture = New-SlangParityFixture -Prefix 'parity-newlines' `
        -Generated @{ 'a.wgsl' = "fn a() {}`n"; 'b.wgsl' = "fn b() {}`n" } `
        -Pinned @{ 'a.wgsl' = "fn a() {}`r`n"; 'b.wgsl' = "fn b() {}`r`n" }
      $verified = @(Invoke-SlangFixtureParity -Fixture $fixture)
      $verified.Count | Should -Be 2
      $verified[0].Name | Should -Be 'a.wgsl'
      $verified[1].Generated | Should -Be (Join-Path $fixture.Combined 'combined_b.wgsl')
    }

    It 'fails on a changed non-newline byte and an omitted emitted file' {
      $fixture = New-SlangParityFixture -Prefix 'parity-mutant' `
        -Generated @{ 'a.wgsl' = "fn a() {}`n" } -Pinned @{ 'a.wgsl' = "fn wrong() {}`n"; 'b.wgsl' = "fn b() {}`n" }
      { Invoke-SlangFixtureParity -Fixture $fixture } |
        Should -Throw -ExpectedMessage '*a.wgsl differs*missing generated b.wgsl*'
      Set-SlangParityContent -Fixture $fixture -Name 'a.wgsl' -Text "fn a() {}`r"
      { Invoke-SlangFixtureParity -Fixture $fixture } |
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
      $fixture = New-SlangParityFixture -Prefix 'parity-encoding' -Outputs @('a.wgsl') -Pinned @{ 'a.wgsl' = 'fn a() {}' }
      [IO.File]::WriteAllBytes((Join-Path $fixture.Combined 'combined_a.wgsl'), [byte[]]@(0xff))
      { Assert-SlangWgslOutputsMatch -Mappings $fixture.Mappings `
          -CombinedOutputDir $fixture.Combined -DestinationRoot $fixture.Destination } | Should -Throw
    }

    It 'compares the original snapshot when compilation overwrites a pinned destination' {
      $fixture = New-SlangParityFixture -Prefix 'parity-overwrite' `
        -Pinned @{ 'a.wgsl' = "fn pinned() {}`r`n"; 'b.wgsl' = "fn b() {}`n" }
      $snapshot = Join-Path $script:root 'parity-overwrite-snapshot'
      Copy-SlangPinnedWgslSnapshot -Mappings $fixture.Mappings -DestinationRoot $fixture.Destination -SnapshotRoot $snapshot
      Set-SlangParityContent -Fixture $fixture -Name 'a.wgsl' -Text "fn changed() {}`n"
      Set-SlangParityContent -Fixture $fixture -Name 'a.wgsl' -Text "fn changed() {}`n" -Generated
      Set-SlangParityContent -Fixture $fixture -Name 'b.wgsl' -Text "fn b() {}`r`n" -Generated
      @(Invoke-SlangFixtureParity -Fixture $fixture).Count | Should -Be 2
      { Invoke-SlangFixtureParity -Fixture $fixture -ExpectedRoot $snapshot } |
        Should -Throw -ExpectedMessage '*a.wgsl differs*'
      [IO.File]::ReadAllText((Join-Path $snapshot 'crate/a.wgsl')) | Should -Be "fn pinned() {}`r`n"
    }

    It 'refuses missing pinned files and empty snapshot roots before allocation' {
      $fixture = New-SlangParityFixture -Prefix 'parity-missing-pinned' -Outputs @('a.wgsl')
      $snapshot = Join-Path $script:root 'parity-missing-snapshot'
      { Copy-SlangPinnedWgslSnapshot -Mappings $fixture.Mappings -DestinationRoot $fixture.Destination -SnapshotRoot $snapshot } |
        Should -Throw -ExpectedMessage '*Missing pinned WGSL before compilation*'
      Test-Path -LiteralPath $snapshot | Should -BeFalse
      InModuleScope WindowsSlang.Common {
        { Get-SlangWgslDestinationPaths -Mappings @() -DestinationRoot 'unused' } | Should -Throw -ExpectedMessage '*no manifest mappings*'
        { Get-SlangWgslDestinationPaths -Mappings @([pscustomobject]@{ out = 'a.wgsl'; dst = 'crate' }) -DestinationRoot '' } |
          Should -Throw -ExpectedMessage '*destination root is empty*'
      }
    }
  }

  Context 'Test-SlangcVersionAtLeast' {
    It '<Name>' -ForEach @(
      @{ Name = 'rejects the slangc whose combined WGSL emit drops @location'; Expected = $false; Versions = @(, @('2026.1-52-gc8ddf20bb', '2026.8')) }
      @{ Name = 'accepts the floor itself and anything newer'; Expected = $true; Versions = @(@('2026.8', '2026.8'), @('2026.9', '2026.8'), @('2027.0', '2026.8')) }
      @{ Name = 'treats an unparseable version as new enough (the emit guard is the backstop)'; Expected = $true; Versions = @(@('some-dev-build', '2026.8'), @('2026.8', '')) }
    ) {
      foreach ($version in $Versions) {
        Test-SlangcVersionAtLeast -Have $version[0] -Want $version[1] | Should -Be $Expected
      }
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
      $spirv = New-SlangFixtureDirectory -Workspace $script:root -Name 'cached-spirv'
      $wgsl = New-SlangFixtureDirectory -Workspace $script:root -Name 'cached-wgsl'
      $shader = $cached.Shader
      $entry = New-SlangFixtureEntry -File 'cached.slang' -Targets @('spirv', 'wgsl')
      Set-Content -LiteralPath (Join-Path $spirv 'cached.main.spv') -Value 'cached'
      Set-Content -LiteralPath (Join-Path $wgsl 'cached.main.wgsl') -Value 'cached'
      $oldStamp = [datetime]::UtcNow.AddHours(-1)
      $newStamp = [datetime]::UtcNow
      (Get-Item $shader).LastWriteTimeUtc = $oldStamp
      (Get-Item (Join-Path $spirv 'cached.main.spv')).LastWriteTimeUtc = $newStamp
      (Get-Item (Join-Path $wgsl 'cached.main.wgsl')).LastWriteTimeUtc = $newStamp

      $result = Invoke-SlangFixtureEntry -Entry $entry -Source $source -Spirv $spirv -Wgsl $wgsl -Stamp $oldStamp
      $result.Compiled | Should -Be 0
      $result.Failures.Count | Should -Be 0
    }

    It 'reports a missing manifest shader as a failed entry' {
      $source = New-SlangFixtureDirectory -Workspace $script:root -Name 'missing-source'
      $entry = New-SlangFixtureEntry -File 'gone.slang' -Targets @('spirv')
      $result = Invoke-SlangFixtureEntry -Entry $entry -Source $source -Spirv $source -Wgsl $source -Stamp ([datetime]::UtcNow)
      $result.Compiled | Should -Be 0
      $result.Failures | Should -Contain (Join-Path $source 'gone.slang')
    }

    It 'copies valid combined WGSL but preserves the destination for an invalid emit' {
      $root = New-SlangFixtureDirectory -Workspace $script:root -Name 'combined-source'
      Set-Content -LiteralPath (Join-Path $root 'owned.slang') -Value 'void main() {}'
      $stage = New-SlangFixtureDirectory -Workspace $script:root -Name 'combined-stage'
      $destination = New-SlangFixtureDirectory -Workspace $script:root -Name 'combined-dest'
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
