#requires -Version 7.0
# Copy-PeImportClosure (WindowsCrossBundle.Common): the DLL closure a cross lane's product carries, walked
# over synthetic PE import tables. NOT covered: a real binary's imports (the cross lanes' arch gate is that).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsCrossBundle.Common.psm1') -Force -DisableNameChecking

$script:Arm64 = [uint16]0xAA64

# Two search dirs: a.dll -> b.dll -> c.dll ~> d.dll (~> a delay-load), with names only the OS has.
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

Describe 'Copy-PeImportClosure' {
    It 'copies the transitive closure, delay-loads included, the first search dir winning, and leaves OS-only names to the device' {
        Invoke-InTestDir { param($dir)
            $search = New-ClosureFixture -Dir $dir
            $out = Join-Path $dir 'bundle'
            $copied = @(Copy-PeImportClosure -Path "$dir\app\app.exe" -SearchDirectory $search -Destination $out -Arch arm64)
            Assert-Equal 'a.dll,B.DLL,c.dll,d.dll' (@($copied | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object) -join ',') 'a, then b through a, c through b, d through c''s delay-load table'
            Assert-True ([System.IO.File]::ReadAllText("$out\a.dll").Contains('a from the first dir')) 'the first search dir holding a name wins'
            Assert-False (Test-Path "$out\unused.dll") 'nothing is copied that no binary imports'
            Assert-False (@(Get-ChildItem $out -Name) -match 'KERNEL32|api-ms-|ucrtbase') 'OS and API-set names are the device''s, not copied'
        }
    }

    It 'refuses a closure DLL built for another machine, naming it' {
        Invoke-InTestDir { param($dir)
            $search = New-ClosureFixture -Dir $dir -BMachine ([uint16]0x8664)
            Assert-Throws { Copy-PeImportClosure -Path "$dir\app\app.exe" -SearchDirectory $search -Destination "$dir\bundle" -Arch arm64 } `
                -MessagePattern 'imported as b\.dll, which the device could not load: .*B\.DLL is PE machine 0x8664, expected 0xAA64'
        }
    }

    It 'walks a runtime-loaded DLL passed as a seed, and returns an empty list when nothing is found' {
        Invoke-InTestDir { param($dir)
            $search = New-ClosureFixture -Dir $dir
            New-OrtTestPe -Path "$dir\app\plugin.dll" -Import @('c.dll') -Machine $script:Arm64
            $copied = @(Copy-PeImportClosure -Path "$dir\app\plugin.dll" -SearchDirectory $search -Destination "$dir\bundle" -Arch arm64)
            Assert-Equal 'c.dll,d.dll' (($copied | ForEach-Object { Split-Path $_ -Leaf }) -join ',') 'the seed''s own imports, then theirs'
            New-OrtTestPe -Path "$dir\app\lonely.exe" -Import @('KERNEL32.dll') -Machine $script:Arm64
            Assert-Equal 0 @(Copy-PeImportClosure -Path "$dir\app\lonely.exe" -SearchDirectory $search -Destination "$dir\bundle2" -Arch arm64).Count 'nothing to copy'
        }
    }
}
