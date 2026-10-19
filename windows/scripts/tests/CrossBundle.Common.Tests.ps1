#requires -Version 7.0
# Cross-build configure args and the DLL closure over synthetic PE import tables; real binaries are the arch gate's job.

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

Describe 'Get-CrossConfigureArgs' {
    It 'is empty on the host, so an x64 configure line does not change' {
        Assert-Equal 0 @(Get-CrossConfigureArgs -Arch amd64 -Corrosion -Vulkan).Count 'amd64 adds nothing'
    }

    It 'names the target to CMake and, when asked, to Corrosion' {
        $a = @(Get-CrossConfigureArgs -Arch arm64 -Corrosion)
        Assert-Equal ((@(Get-CMakeCrossArgs -Arch arm64) + '-DRust_CARGO_TARGET=aarch64-pc-windows-msvc') -join ' ') ($a -join ' ') 'the hub''s cross args, then the cargo target'
        Assert-Equal 0 @($a -match 'Vulkan_LIBRARY').Count 'no Vulkan library without -Vulkan'
        Assert-Equal 0 @(@(Get-CrossConfigureArgs -Arch arm64) -match 'Rust_CARGO_TARGET').Count 'no cargo target without -Corrosion'
    }

    It 'takes Vulkan_LIBRARY from the SDK''s arm64 Lib, and refuses an SDK without one' {
        Invoke-InTestDir { param($dir)
            $sdk = Join-Path $dir 'VulkanSDK'
            $null = New-Item -ItemType Directory -Force -Path "$sdk\Lib", "$sdk\Lib-ARM64"
            Set-Content -LiteralPath "$sdk\Lib\vulkan-1.lib" -Value 'x64'
            Invoke-WithEnv @{ VULKAN_SDK = $sdk } {
                Assert-Throws { Get-CrossConfigureArgs -Arch arm64 -Vulkan } -MessagePattern 'Lib-ARM64\\vulkan-1\.lib.*com\.lunarg\.vulkan\.arm64'
                Set-Content -LiteralPath "$sdk\Lib-ARM64\vulkan-1.lib" -Value 'arm64'
                $a = @(Get-CrossConfigureArgs -Arch arm64 -Vulkan)
                Assert-Equal "-DVulkan_LIBRARY=$sdk\Lib-ARM64\vulkan-1.lib" ($a | Select-Object -Last 1) 'the per-arch import library, never the x64 one'
            }
            Invoke-WithEnv @{ VULKAN_SDK = $null } {
                Assert-Throws { Get-CrossConfigureArgs -Arch arm64 -Vulkan } -MessagePattern 'VULKAN_SDK'
            }
        }
    }
}

Describe 'Get-WindowsPackageArch' {
    It 'spells each target the way MSIX, WiX and the VC++ redist do, and refuses anything else' {
        Assert-Equal 'x64' (Get-WindowsPackageArch -Arch amd64) 'amd64 packages as x64'
        Assert-Equal 'x64' (Get-WindowsPackageArch -Arch x64) 'the hub accepts the x64 alias'
        Assert-Equal 'arm64' (Get-WindowsPackageArch -Arch arm64) 'arm64 packages as arm64'
        Assert-Throws { Get-WindowsPackageArch -Arch riscv64 } -MessagePattern 'Unsupported Windows target architecture'
    }
}

Describe 'Get-ProductDllSearchPath' {
    It 'searches the chain ORT, then the media stack, then the target arch''s VC++ runtime, and only what exists' {
        Invoke-InTestDir { param($dir)
            $onnx = Join-Path $dir 'onnx'; $runtime = Join-Path $dir 'runtime\bin'; $redist = Join-Path $dir 'redist'
            $null = New-Item -ItemType Directory -Force -Path "$onnx\bin", $runtime, "$redist\x64\Microsoft.VC145.CRT", "$redist\arm64\Microsoft.VC145.CRT", "$redist\arm64\Microsoft.VC145.OPENMP"
            Invoke-WithEnv @{ ONNX_ROOT = $onnx; VCToolsRedistDir = $redist } {
                Assert-Equal "$onnx\bin|$runtime|$redist\arm64\Microsoft.VC145.CRT" ((Get-ProductDllSearchPath -Arch arm64 -RuntimeBin $runtime) -join '|') 'arm64: chain ORT, media stack, the arm64 CRT only'
                Assert-Equal "$onnx\bin|$runtime|$redist\x64\Microsoft.VC145.CRT" ((Get-ProductDllSearchPath -Arch amd64 -RuntimeBin $runtime) -join '|') 'amd64 takes the x64 CRT'
            }
            Invoke-WithEnv @{ ONNX_ROOT = $null; VCToolsRedistDir = $null } {
                Assert-Equal $runtime ((Get-ProductDllSearchPath -Arch amd64 -RuntimeBin $runtime) -join '|') 'without the variables only the media stack is left'
                Assert-Equal 0 @(Get-ProductDllSearchPath -Arch amd64 -RuntimeBin (Join-Path $dir 'missing')).Count 'a directory that does not exist is never offered'
            }
        }
    }
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

Describe 'New-PortableBundle' {
    # The fixture's app.exe as the install tree's binary, plus -Extra installed beside it; records the cmake argv.
    function script:New-FakeInstall([string]$Dir, [string[]]$Extra = @()) {
        $fixture = $Dir
        $extraNames = $Extra
        return {
            param($File, [string[]]$Arguments)
            Set-Content -LiteralPath (Join-Path $fixture 'install.log') -Value "$File $($Arguments -join ' ')"
            $bin = Join-Path $Arguments[$Arguments.IndexOf('--prefix') + 1] 'bin'
            $null = New-Item -ItemType Directory -Force -Path $bin
            Copy-Item -LiteralPath "$fixture\app\app.exe" -Destination $bin
            foreach ($name in $extraNames) { Copy-Item -LiteralPath "$fixture\runtime\bin\$name" -Destination $bin }
        }.GetNewClosure()
    }

    It 'installs, adds the imported DLLs, and copies the .msi, .zip and their NSIS .exe but no test binary' {
        Invoke-InTestDir { param($dir)
            $search = New-ClosureFixture -Dir $dir
            $build = Join-Path $dir 'build'
            foreach ($f in 'app.msi', 'app.zip', 'app.exe', 'unit_tests.exe') { $null = New-Item -ItemType File -Force -Path (Join-Path $build $f) }
            $r = New-PortableBundle -BuildDir $build -DistDir "$dir\dist" -Arch arm64 -SearchDirectory $search -Runner (New-FakeInstall $dir)
            Assert-Equal "cmake --install $build --prefix $dir\dist\bundle --config Release" (Get-Content -LiteralPath "$dir\install.log")
            Assert-Equal 'a.dll,B.DLL,c.dll,d.dll' (@($r.Added | Sort-Object) -join ',') 'the closure of app.exe'
            Assert-True (Test-Path -LiteralPath "$dir\dist\bundle\bin\d.dll") 'beside the binary'
            Assert-Equal 'app.exe,app.msi,app.zip' (@(Get-ChildItem -LiteralPath "$dir\dist\packages" -Name | Sort-Object) -join ',')
        }
    }

    It 'returns its result object alone: cmake''s output, from the default runner or a passed one, goes to the host' {
        Invoke-InTestDir { param($dir)
            $bundleArgs = @{ BuildDir = "$dir\build"; DistDir = "$dir\dist"; Arch = 'arm64'; SearchDirectory = (New-ClosureFixture -Dir $dir) }
            $null = New-Item -ItemType Directory -Force -Path "$dir\tools", $bundleArgs.BuildDir
            Set-Content -LiteralPath "$dir\tools\cmake.cmd" -Value @('@echo off', 'echo -- Install configuration: "Release"',
                'mkdir "%~4\bin"', "copy /y `"$dir\app\app.exe`" `"%~4\bin\`" >nul", 'echo -- Installing: %~4\bin\app.exe')
            $r = @(Invoke-WithEnv @{ PATH = "$dir\tools;$env:PATH" } { New-PortableBundle @bundleArgs })
            Assert-Equal 1 $r.Count 'the default runner: one object, no cmake line'
            Assert-Equal "$dir\dist\bundle" $r[0].Bundle
            Assert-Equal 4 @($r[0].Added).Count 'the fake cmake installed app.exe, and its closure followed'
            $install = New-FakeInstall $dir
            $chatty = { param($File, [string[]]$Arguments) '-- Installing: a line a logged runner returns'; & $install $File $Arguments }.GetNewClosure()
            $r = @(New-PortableBundle @bundleArgs -Runner $chatty)
            Assert-Equal 1 $r.Count 'a passed runner''s output does not join the result either'
            Assert-Equal "$dir\dist\packages" $r[0].Packages
        }
    }

    It 'with -RequireCompleteInstall throws when the closure has to add a DLL, and passes a complete install tree' {
        Invoke-InTestDir { param($dir)
            $search = New-ClosureFixture -Dir $dir
            $null = New-Item -ItemType Directory -Force -Path "$dir\build"
            Assert-Throws { New-PortableBundle -BuildDir "$dir\build" -DistDir "$dir\dist" -Arch arm64 -SearchDirectory $search -Runner (New-FakeInstall $dir) -RequireCompleteInstall } `
                -MessagePattern 'The install tree lacks a\.dll, B\.DLL, c\.dll, d\.dll, which its binaries import'
            Copy-Item -LiteralPath "$dir\ort\bin\B.DLL" -Destination "$dir\runtime\bin\B.DLL"
            $r = New-PortableBundle -BuildDir "$dir\build" -DistDir "$dir\dist" -Arch arm64 -SearchDirectory $search -RequireCompleteInstall `
                -Runner (New-FakeInstall $dir -Extra 'a.dll', 'B.DLL', 'c.dll', 'd.dll')
            Assert-Equal 0 $r.Added.Count 'nothing missing'
        }
    }
}
