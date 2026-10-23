#requires -Version 7.0
# Shared PE fixtures keep traversal fault controls and bundle regressions on the same physical import tree.

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

Export-ModuleMember -Function New-ClosureFixture, Assert-ClosureRootPolicies
