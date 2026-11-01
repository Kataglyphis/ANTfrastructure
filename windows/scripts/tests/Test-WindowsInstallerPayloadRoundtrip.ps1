#requires -Version 7.0
# Build a text-only fixture to exercise real MSI administrative extraction without installing an app.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parent = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath
$scratch = Join-Path $parent "gpu-msi-roundtrip-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
$previous = [Environment]::GetEnvironmentVariable('GPU_TEST_MSI', 'Process')
try {
    Set-Content -LiteralPath (Join-Path $scratch 'gpu-fixture.txt') -Value 'gpu-fixture' -NoNewline -Encoding ascii
    @'
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="GPU fixture" Manufacturer="Fixture" Version="1.0.0" UpgradeCode="{A2A70CD0-7E6B-4662-8174-324A5A961192}">
    <MediaTemplate EmbedCab="yes" />
    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="GpuFixture">
        <Component Id="FixtureComponent" Guid="{127C0F57-E336-44B2-8585-FCFDC4B9F8C1}">
          <File Id="FixtureFile" Source="gpu-fixture.txt" />
        </Component>
      </Directory>
    </StandardDirectory>
    <Feature Id="FixtureFeature"><ComponentRef Id="FixtureComponent" /></Feature>
  </Package>
</Wix>
'@ | Set-Content -LiteralPath (Join-Path $scratch 'fixture.wxs') -Encoding utf8
    Push-Location -LiteralPath $scratch
    try {
        & wix build -arch x64 -o fixture.msi fixture.wxs
        if ($LASTEXITCODE -ne 0) { throw 'Could not build the text-only MSI fixture.' }
    } finally { Pop-Location }
    $env:GPU_TEST_MSI = Join-Path $scratch 'fixture.msi'
    $test = Join-Path $PSScriptRoot '../../../shared/python/tests/test_windows_installer_payload_real.py'
    & python -I $test
    if ($LASTEXITCODE -ne 0) { throw 'The real MSI extraction fixture failed.' }
} finally {
    [Environment]::SetEnvironmentVariable('GPU_TEST_MSI', $previous, 'Process')
    $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
    $prefix = $parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture path: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}
