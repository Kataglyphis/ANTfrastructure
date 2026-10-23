#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Test-TargetArch.ps1 is the cross lane's primary correctness signal; this pins its PE and COFF-archive machine checks.

Describe 'verify-target-arch: Get-CoffMachine / Get-ArchiveMachine' {

    BeforeAll {
        # Get-ScriptFunctionDefinition lifts only functions, so their script-level $machineNames must exist first.
        $script:machineNames = @{
            0x0000 = 'UNKNOWN'
            0x014C = 'I386'
            0x8664 = 'AMD64'
            0xAA64 = 'ARM64'
            0xA641 = 'ARM64EC'
            0xA64E = 'ARM64X'
            0x01C0 = 'ARM'
            0x01C4 = 'ARMNT'
            0x0200 = 'IA64'
            0x5032 = 'RISCV32'
            0x5064 = 'RISCV64'
        }
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Test-TargetArch.ps1' `
                -FunctionName 'Get-CoffMachine', 'Get-ArchiveMachine', 'Format-Machine')

        $script:tmp = New-TestDir -Prefix 'archgate-'

        Import-Module (Join-Path $PSScriptRoot 'WindowsArchGate.Fixture.psm1') -DisableNameChecking

    }

    AfterAll {
        if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Get-CoffMachine

    It 'Get-CoffMachine reads an AMD64 PE image' {
        $p = Join-Path $script:tmp 'amd64.dll'
        New-OrtTestPe -Path $p -Machine 0x8664
        Assert-Equal 0x8664 (Get-CoffMachine -LiteralPath $p) 'AMD64 PE machine'
    }

    It 'Get-CoffMachine reads an ARM64 PE image' {
        $p = Join-Path $script:tmp 'arm64.dll'
        New-OrtTestPe -Path $p -Machine 0xAA64
        Assert-Equal 0xAA64 (Get-CoffMachine -LiteralPath $p) 'ARM64 PE machine'
    }

    It 'Get-CoffMachine reads an ARM64EC PE image' {
        $p = Join-Path $script:tmp 'arm64ec.dll'
        New-OrtTestPe -Path $p -Machine 0xA641
        Assert-Equal 0xA641 (Get-CoffMachine -LiteralPath $p) 'ARM64EC PE machine'
    }

    It 'Get-CoffMachine reads a COFF object (.obj) machine from byte 0' {
        $p = Join-Path $script:tmp 'foo.obj'
        New-ArchGateMachineFile -Path $p -Machine 0x8664 -Kind Coff
        Assert-Equal 0x8664 (Get-CoffMachine -LiteralPath $p) 'COFF object machine at offset 0'
    }

    It 'Get-CoffMachine returns null for a text file (not PE, not a known COFF machine)' {
        $p = Join-Path $script:tmp 'text.dll'
        Set-Content $p 'not a PE file' -Encoding ASCII -NoNewline
        $r = Get-CoffMachine -LiteralPath $p
        Assert-Null $r 'text file returns null, not a wrong machine'
    }

    It 'Get-CoffMachine returns null for a file shorter than 4 bytes' {
        $p = Join-Path $script:tmp 'tiny.dll'
        [IO.File]::WriteAllBytes($p, [byte[]](0x4D, 0x5A, 0x00))
        $r = Get-CoffMachine -LiteralPath $p
        Assert-Null $r 'file under 4 bytes returns null'
    }

    It 'Get-CoffMachine returns null for a non-existent file (no throw)' {
        $r = Get-CoffMachine -LiteralPath (Join-Path $script:tmp 'does-not-exist.dll')
        Assert-Null $r 'missing file returns null, never throws'
    }

    It 'Get-CoffMachine returns null when e_lfanew points outside the file' {
        $p = Join-Path $script:tmp 'bad-pe.dll'
        New-ArchGateMachineFile -Path $p -Kind BadOffset
        $r = Get-CoffMachine -LiteralPath $p
        Assert-Null $r 'PE with e_lfanew past EOF returns null'
    }

    It 'Get-CoffMachine returns null when the PE signature is wrong' {
        $p = Join-Path $script:tmp 'bad-sig.dll'
        New-ArchGateMachineFile -Path $p -Kind BadSignature
        $r = Get-CoffMachine -LiteralPath $p
        Assert-Null $r 'wrong PE signature returns null'
    }

    # Get-ArchiveMachine

    It 'Get-ArchiveMachine reads a short-import archive (AMD64)' {
        $p = Join-Path $script:tmp 'amd64.lib'
        New-ArchGateArchive -Path $p -Machine 0x8664 -ShortImport
        Assert-Equal 0x8664 (Get-ArchiveMachine -LiteralPath $p) 'short-import AMD64 archive'
    }

    It 'Get-ArchiveMachine reads a short-import archive (ARM64)' {
        $p = Join-Path $script:tmp 'arm64.lib'
        New-ArchGateArchive -Path $p -Machine 0xAA64 -ShortImport
        Assert-Equal 0xAA64 (Get-ArchiveMachine -LiteralPath $p) 'short-import ARM64 archive'
    }

    It 'Get-ArchiveMachine reads a raw-object archive' {
        $p = Join-Path $script:tmp 'raw.lib'
        New-ArchGateArchive -Path $p -Machine 0xAA64
        Assert-Equal 0xAA64 (Get-ArchiveMachine -LiteralPath $p) 'raw-object ARM64 archive'
    }

    It 'Get-ArchiveMachine skips the linker members (/ and //) and reads the first real member' {
        $p = Join-Path $script:tmp 'with-linker.lib'
        New-ArchGateArchive -Path $p -Machine 0xAA64 -ShortImport -LinkerMember
        Assert-Equal 0xAA64 (Get-ArchiveMachine -LiteralPath $p) 'skipped "/" linker member and read the real member'
    }

    It 'Get-ArchiveMachine returns null for a non-archive file' {
        $p = Join-Path $script:tmp 'not-a-lib.lib'
        Set-Content $p 'not an archive' -Encoding ASCII -NoNewline
        $r = Get-ArchiveMachine -LiteralPath $p
        Assert-Null $r 'non-archive returns null'
    }

    It 'Get-ArchiveMachine returns null for a file shorter than 8 bytes' {
        $p = Join-Path $script:tmp 'tiny.lib'
        [IO.File]::WriteAllBytes($p, [byte[]](0x21, 0x3C, 0x61, 0x72))
        $r = Get-ArchiveMachine -LiteralPath $p
        Assert-Null $r 'file under 8 bytes returns null'
    }

    It 'Get-ArchiveMachine returns null for a missing file (no throw)' {
        $r = Get-ArchiveMachine -LiteralPath (Join-Path $script:tmp 'does-not-exist.lib')
        Assert-Null $r 'missing file returns null, never throws'
    }

    It 'Get-ArchiveMachine returns null for a truncated archive (member header past EOF)' {
        $p = Join-Path $script:tmp 'truncated.lib'
        # Just the magic, no room for a member header
        [IO.File]::WriteAllBytes($p, [System.Text.Encoding]::ASCII.GetBytes("!<arch>`n"))
        $r = Get-ArchiveMachine -LiteralPath $p
        Assert-Null $r 'truncated archive returns null, not an exception'
    }

    It 'Get-ArchiveMachine returns null for a malformed size field (no throw)' {
        $p = Join-Path $script:tmp 'bad-size.lib'
        New-ArchGateArchive -Path $p -Machine 0xAA64 -InvalidSize
        $r = Get-ArchiveMachine -LiteralPath $p
        Assert-Null $r 'malformed size returns null, not an exception'
    }

    # Format-Machine

    It 'Format-Machine names a known machine type' {
        Assert-Equal '0x8664 (AMD64)' (Format-Machine 0x8664) 'AMD64 named'
    }

    It 'Format-Machine names an unrecognized machine type' {
        Assert-Equal '0x1234 (UNRECOGNIZED)' (Format-Machine 0x1234) 'unknown machine'
    }
}

Describe 'verify-target-arch: device-OS import allowances (#121 QNN)' {
    BeforeAll { $script:archGateText = (Get-TestScriptAst -ScriptPath 'windows/scripts/build/Test-TargetArch.ps1').Extent.Text }

    It '<Name>' -ForEach @(
        @{ Name = 'classifies the Qualcomm FastRPC drivers as device OS (libcdsprpc/libadsprpc)'; Literal = 'lib(cds|ads)prpc\.dll'; Why = 'FastRPC' }
        @{ Name = "allowlists the cp313 torch stack's interpreter as an external (python313.dll)"; Literal = 'python313\.dll'; Why = 'cp313' }
    ) {
        Assert-True ($script:archGateText.Contains($Literal)) "the gate must retain its import allowance: $Literal"
        Assert-True ($script:archGateText.Contains($Why)) "the allowance must retain its reason: $Why"
    }

}

Describe 'verify-target-arch: the import walk opens every wheel' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'WindowsArchGate.Fixture.psm1') -DisableNameChecking
        # The gate resolves system imports against $env:SystemRoot\System32; a fake one holds the names these fixtures import.
        $script:savedSystemRoot = $env:SystemRoot
        $script:fakeSystemRoot = Join-Path $TestDrive 'Windows'
        $script:fakeSys32 = Join-Path $script:fakeSystemRoot 'System32'
        New-Item -ItemType Directory -Force -Path $script:fakeSys32 | Out-Null
        Set-Content -LiteralPath (Join-Path $script:fakeSys32 'kernel32.dll') -Value 'MZ'
        $env:SystemRoot = $script:fakeSystemRoot
    }

    AfterAll {
        $env:SystemRoot = $script:savedSystemRoot
    }


    It 'walks two same-named wheels, as the GIL and the free-threaded tree each ship ensurepip''s pip' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Invoke-ArchGateFixture -Body { param($d, $rt)
            foreach ($tree in 'python', 'python-freethreaded') {
                $src = Join-Path $d "wheel-$tree"
                New-OrtTestPe -Path (Join-Path $src 'pip\_vendor\distlib\t64-arm.exe') -Machine 0xAA64 -Import 'kernel32.dll'
                $whl = Join-Path $rt "$tree\Lib\ensurepip\_bundled\pip-26.2.1-py3-none-any.whl"
                New-Item -ItemType Directory -Force -Path (Split-Path $whl) | Out-Null
                [IO.Compression.ZipFile]::CreateFromDirectory($src, $whl)
            }
            Assert-ArchGateTree -Path $rt -Pattern 'import walk: 3 file\(s\) walked, 0 unresolved'

        }
    }

    It 'machine-checks every wheel member, and a cp3XYt wheel''s modules may import only python3XYt.dll (mutation)' {
        Invoke-ArchGateFixture -RuntimeDll 'python\python314.dll', 'python-freethreaded\python314t.dll' -Body { param($d, $rt)
            $whl = Join-Path $rt 'wheels-cp314t\av-1.0-cp314-cp314t-win_arm64.whl'
            New-ArchGateWheel -Path $whl -Member @{ 'av\_core.cp314t-win_arm64.pyd' = @{ Machine = 0xAA64; Import = 'python314t.dll' }; 'av\avutil.dll' = @{ Machine = 0xAA64; Import = 'kernel32.dll' } }
            Assert-ArchGateTree -Path $rt -Pattern 'cp3XYt wheels: 1 wheel\(s\), 1 module\(s\) import their free-threaded runtime, 0 finding\(s\)'
            New-ArchGateWheel -Path $whl -Member @{ 'av\_core.cp314t-win_arm64.pyd' = @{ Machine = 0x8664; Import = 'python314t.dll' } }
            Assert-ArchGateTree -Path $rt -Fails -Pattern 'av-1\.0-cp314-cp314t-win_arm64\.whl!av[\\/]_core\.cp314t-win_arm64\.pyd  is 0x8664 \(AMD64\)'
            New-ArchGateWheel -Path $whl -Member @{ 'av\_core.pyd' = @{ Machine = 0xAA64; Import = 'python314.dll' } }
            Assert-ArchGateTree -Path $rt -Fails -Pattern @(
                'FREE-THREADED ABI: .*av[\\/]_core\.pyd imports python314\.dll, not python314t\.dll'
                'FREE-THREADED ABI: .*av-1\.0-cp314-cp314t-win_arm64\.whl has no module importing its free-threaded runtime'
            )
        }
    }

    It 'skips an NSIS installer, an x86 stub on every arch, and still fails an x86 exe without the NSIS header (mutation)' {
        Invoke-ArchGateFixture -RootName dist -RuntimeDll 'bundle\bin\app.exe' -Body { param($d, $tree)
            $setup = Join-Path $tree 'packages\App-1.0-Release-aarch64.exe'
            New-OrtTestPe -Path $setup -Machine 0x014C -Import 'kernel32.dll'
            Assert-ArchGateTree -Path $tree -Standalone -Fails -Pattern 'App-1\.0-Release-aarch64\.exe  is 0x014C \(I386\)'
            $header = [byte[]](@(0, 0, 0, 0, 0xEF, 0xBE, 0xAD, 0xDE) + [Text.Encoding]::ASCII.GetBytes('NullsoftInst') + [byte[]]::new(8))
            $fs = [IO.File]::Open($setup, [IO.FileMode]::Append)
            try { $fs.Write($header, 0, $header.Length) } finally { $fs.Dispose() }
            Assert-ArchGateTree -Path $tree -Standalone -Pattern 'NSIS installers, an x86 stub on every arch, skipped 1 file\(s\)'
            New-OrtTestPe -Path (Join-Path $tree 'bundle\bin\helper.exe') -Machine 0x014C -Import 'kernel32.dll'
            Assert-ArchGateTree -Path $tree -Standalone -Fails
        }
    }

    It 'reports the launcher templates of a real pip wheel, one per arch, and still fails a foreign binary beside them (mutation)' {
        Invoke-ArchGateFixture -Machine 0x8664 -RuntimeDll python314.dll -Body { param($d, $rt)
            $whl = Join-Path $rt 'Lib\ensurepip\_bundled\pip-26.2.1-py3-none-any.whl'
            $templates = @{}
            foreach ($t in @(@('t32', 0x014C), @('w32', 0x014C), @('t64', 0x8664), @('w64', 0x8664), @('t64-arm', 0xAA64), @('w64-arm', 0xAA64))) {
                $templates["pip\_vendor\distlib\$($t[0]).exe"] = @{ Machine = $t[1]; Import = 'kernel32.dll' }
            }
            New-ArchGateWheel -Path $whl -Member $templates
            Assert-ArchGateTree -Path $rt -Arch amd64 -Standalone -Pattern 'launcher templates, one per arch by design, skipped 6 file\(s\)'
            $templates['pip\_vendor\rich\arm64-helper.exe'] = @{ Machine = 0xAA64; Import = 'kernel32.dll' }
            New-ArchGateWheel -Path $whl -Member $templates
            Assert-ArchGateTree -Path $rt -Arch amd64 -Standalone -Fails -Pattern 'arm64-helper\.exe  is 0xAA64 \(ARM64\), expected 0x8664 \(AMD64\)'
        }
    }
    It 'detects a child-verdict mutant that turns an empty inspection into success' {
        $script:emptyGateRoot = Join-Path $TestDrive 'empty-gate'
        New-Item -ItemType Directory -Force -Path $script:emptyGateRoot | Out-Null
        Assert-Throws { Assert-ArchGateTree -Path $script:emptyGateRoot } -MessagePattern 'the gate failed'
        $definition = (Get-Command Assert-ArchGateTree).Definition
        $text = "function Assert-ArchGateTree {`n$definition`n}"
        Invoke-WithFunctionModule -Text $text -FunctionName Assert-ArchGateTree -Find '$code = $LASTEXITCODE' -Replace '$code = 0' -Body {
            Assert-Throws {
                Assert-Throws { Assert-MutArchGateTree -Path $script:emptyGateRoot } -MessagePattern 'the gate failed'
            } -MessagePattern 'expected an exception but none was thrown'
        }
    }

}
