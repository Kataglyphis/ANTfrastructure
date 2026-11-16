#requires -Version 7.0
# Shared PE and install fixtures keep traversal controls and bundle callback proofs with their Windows consumers.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

$script:Arm64 = [uint16]0xAA64

function New-ClosureFixture {
    param([Parameter(Mandatory)][string]$Dir, [uint16]$BMachine = $script:Arm64)
    $first = Join-Path $Dir 'runtime\bin'
    $second = Join-Path $Dir 'ort\bin'
    New-OrtTestPe -Path "$first\a.dll" -Import @('b.dll', 'KERNEL32.dll') -Text @('a from the first dir') -Machine $script:Arm64
    New-OrtTestPe -Path "$first\c.dll" -DelayImport @('d.dll') -Machine $script:Arm64
    New-OrtTestPe -Path "$first\d.dll" -Text @('d') -Machine $script:Arm64
    New-OrtTestPe -Path "$first\unused.dll" -Text @('nobody imports me') -Machine $script:Arm64
    New-OrtTestPe -Path "$second\a.dll" -Text @('a from the second dir') -Machine $script:Arm64
    New-OrtTestPe -Path "$second\B.DLL" -Import @('c.dll', 'api-ms-win-crt-runtime-l1-1-0.dll') -Machine $BMachine
    New-OrtTestPe -Path "$Dir\app\app.exe" -Import @('a.dll', 'ucrtbase.dll') -Machine $script:Arm64
    return @($first, $second)
}

function Assert-ClosureRootPolicies {
    Invoke-InTestDir -Body { param($dir)
        $search = New-ClosureFixture -Dir $dir
        New-OrtTestPe -Path (Join-Path $dir 'app/plugin.dll') -Import c.dll, api-ms-real.dll -Machine $script:Arm64
        $system = Join-Path $dir System32
        New-OrtTestPe -Path (Join-Path $system api-ms-real.dll) -Import child.dll -Machine $script:Arm64
        New-OrtTestPe -Path (Join-Path $system child.dll) -Machine $script:Arm64
        $options = @{ Path = @((Join-Path $dir 'app/app.exe'), (Join-Path $dir 'app/plugin.dll')); SearchDirectory = @($search) + @($system); Arch = 'arm64' }
        $closure = @(Get-MutPeImportClosure @options)
        Assert-Equal 'a.dll|c.dll|api-ms-real.dll|B.DLL|d.dll|child.dll' (($closure | ForEach-Object { [IO.Path]::GetFileName($_) }) -join '|') 'every seed stays ahead of its imported children, including indexed API sets'
        Assert-Equal $search[0] ([IO.Path]::GetDirectoryName($closure[0])) 'the first index entry wins'
        New-OrtTestPe -Path (Join-Path $system api-ms-real.dll) -Machine 0x8664
        Assert-Throws { Get-MutPeImportClosure @options | Out-Null } -MessagePattern 'api-ms-real.*PE machine 0x8664, expected 0xAA64'
    }
}

function New-CrossBundleInstallFixture {
    param([Parameter(Mandatory)][string]$Dir, [string[]]$Extra = @())
    $fixture = $Dir
    $extraNames = $Extra
    return {
        param($File, [string[]]$Arguments)
        Set-Content -LiteralPath (Join-Path $fixture 'install.log') -Value "$File $($Arguments -join ' ')"
        $bin = Join-Path $Arguments[$Arguments.IndexOf('--prefix') + 1] 'bin'
        $null = New-Item -ItemType Directory -Force -Path $bin
        Copy-Item -LiteralPath (Join-Path $fixture 'app/app.exe') -Destination $bin
        foreach ($name in $extraNames) { Copy-Item -LiteralPath (Join-Path $fixture "runtime/bin/$name") -Destination $bin }
    }.GetNewClosure()
}

function New-CrossBundlePackageFixture {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string[]]$SearchDirectory,
        [string[]]$InstallerName = @('app.msi', 'app.zip'), [switch]$Chatty)
    $build = Join-Path $Dir 'build'
    $null = New-Item -ItemType Directory -Force -Path $build
    foreach ($name in $InstallerName) { $null = New-Item -ItemType File -Force -Path (Join-Path $build $name) }
    $checked = [Collections.Generic.List[string]]::new()
    $emitSuccess = $Chatty.IsPresent
    $check = { param($Path, $RedistText) $checked.Add((Split-Path $Path -Leaf)); if ($emitSuccess) { "PASS: $Path" } }.GetNewClosure()
    $options = @{ BuildDir = $build; DistDir = (Join-Path $Dir 'dist'); Arch = 'arm64'; SearchDirectory = $SearchDirectory;
        Runner = (New-CrossBundleInstallFixture $Dir); PackageCheck = $check }
    return [pscustomobject]@{ Options = $options; Checked = $checked }
}

Export-ModuleMember -Function New-ClosureFixture, Assert-ClosureRootPolicies, New-CrossBundleInstallFixture, New-CrossBundlePackageFixture
