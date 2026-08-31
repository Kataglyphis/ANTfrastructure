#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# verify-target-arch.ps1 is the arm64 cross lane's PRIMARY correctness signal:
# every shipped binary is PE-machine-checked against the target, and a COFF
# archive (.lib) machine check that is NOT a naive bytes[0x3C] walk. The
# Get-ArchiveMachine bound was fixed in production (the +6 bound was two bytes
# short and threw on a small final member), not by a test — this suite pins it.
#
# The functions live inside the script body (not a module), so they are lifted
# out of the script's AST via Get-ScriptFunctionDefinition. The $machineNames
# hashtable they reference is a script-level variable, so it is defined in
# BeforeAll before the dot-source.

Describe 'verify-target-arch: Get-CoffMachine / Get-ArchiveMachine' {

    BeforeAll {
        # $machineNames is a script-level hashtable the functions reference;
        # Get-ScriptFunctionDefinition lifts only function bodies, so it must
        # be in scope before the dot-source.
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
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\verify-target-arch.ps1' `
                -FunctionName 'Get-CoffMachine', 'Get-ArchiveMachine', 'Format-Machine')

        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('archgate-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:tmp | Out-Null

        # Fixture helpers as $script:-scoped scriptblocks (Pester 5+ It blocks
        # are child scopes that do not see functions defined at the file level).
        $script:NewPe = {
            param([string]$Path, [int]$Machine)
            $bytes = New-Object byte[] 0x48
            $bytes[0] = 0x4D; $bytes[1] = 0x5A
            $bytes[0x3C] = 0x40; $bytes[0x3D] = 0x00; $bytes[0x3E] = 0x00; $bytes[0x3F] = 0x00
            $bytes[0x40] = 0x50; $bytes[0x41] = 0x45; $bytes[0x42] = 0x00; $bytes[0x43] = 0x00
            $bytes[0x44] = $Machine -band 0xFF
            $bytes[0x45] = ($Machine -shr 8) -band 0xFF
            [IO.File]::WriteAllBytes($Path, $bytes)
        }
        $script:NewCoffObj = {
            param([string]$Path, [int]$Machine)
            $bytes = New-Object byte[] 4
            $bytes[0] = $Machine -band 0xFF
            $bytes[1] = ($Machine -shr 8) -band 0xFF
            [IO.File]::WriteAllBytes($Path, $bytes)
        }
        $script:NewArchive = {
            param([string]$Path, [int]$Machine, [switch]$ShortImport, [string]$MemberName = 'foo.obj')
            $ms = New-Object System.IO.MemoryStream
            $bw = New-Object System.IO.BinaryWriter($ms)
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes("!<arch>`n"))
            $name = $MemberName.PadRight(16).Substring(0, 16)
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes($name))
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(12)))
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes('100644'.PadRight(8)))
            $payload = if ($ShortImport) {
                $p = New-Object byte[] 20
                $p[2] = 0xFF; $p[3] = 0xFF
                $p[6] = $Machine -band 0xFF
                $p[7] = ($Machine -shr 8) -band 0xFF
                ,$p
            } else {
                $p = New-Object byte[] 20
                $p[0] = $Machine -band 0xFF
                $p[1] = ($Machine -shr 8) -band 0xFF
                ,$p
            }
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes("$($payload.Length)".PadLeft(10)))
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n"))
            $bw.Write($payload)
            $bw.Flush()
            [IO.File]::WriteAllBytes($Path, $ms.ToArray())
        }
    }

    AfterAll {
        if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # ── Get-CoffMachine ────────────────────────────────────────────────────────

    It 'Get-CoffMachine reads an AMD64 PE image' {
        $p = Join-Path $script:tmp 'amd64.dll'
        & $script:NewPe -Path $p -Machine 0x8664
        Assert-Equal 0x8664 (Get-CoffMachine -LiteralPath $p) 'AMD64 PE machine'
    }

    It 'Get-CoffMachine reads an ARM64 PE image' {
        $p = Join-Path $script:tmp 'arm64.dll'
        & $script:NewPe -Path $p -Machine 0xAA64
        Assert-Equal 0xAA64 (Get-CoffMachine -LiteralPath $p) 'ARM64 PE machine'
    }

    It 'Get-CoffMachine reads an ARM64EC PE image' {
        $p = Join-Path $script:tmp 'arm64ec.dll'
        & $script:NewPe -Path $p -Machine 0xA641
        Assert-Equal 0xA641 (Get-CoffMachine -LiteralPath $p) 'ARM64EC PE machine'
    }

    It 'Get-CoffMachine reads a COFF object (.obj) machine from byte 0' {
        $p = Join-Path $script:tmp 'foo.obj'
        & $script:NewCoffObj -Path $p -Machine 0x8664
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
        $bytes = New-Object byte[] 64
        $bytes[0] = 0x4D; $bytes[1] = 0x5A
        # e_lfanew = 0x100 (beyond the 64-byte file)
        $bytes[0x3C] = 0x00; $bytes[0x3D] = 0x01; $bytes[0x3E] = 0x00; $bytes[0x3F] = 0x00
        [IO.File]::WriteAllBytes($p, $bytes)
        $r = Get-CoffMachine -LiteralPath $p
        Assert-Null $r 'PE with e_lfanew past EOF returns null'
    }

    It 'Get-CoffMachine returns null when the PE signature is wrong' {
        $p = Join-Path $script:tmp 'bad-sig.dll'
        $bytes = New-Object byte[] 66
        $bytes[0] = 0x4D; $bytes[1] = 0x5A
        $bytes[0x3C] = 0x38; $bytes[0x3D] = 0x00; $bytes[0x3E] = 0x00; $bytes[0x3F] = 0x00
        # "NE" instead of "PE"
        $bytes[0x38] = 0x4E; $bytes[0x39] = 0x45; $bytes[0x3A] = 0x00; $bytes[0x3B] = 0x00
        [IO.File]::WriteAllBytes($p, $bytes)
        $r = Get-CoffMachine -LiteralPath $p
        Assert-Null $r 'wrong PE signature returns null'
    }

    # ── Get-ArchiveMachine ──────────────────────────────────────────────────────

    It 'Get-ArchiveMachine reads a short-import archive (AMD64)' {
        $p = Join-Path $script:tmp 'amd64.lib'
        & $script:NewArchive -Path $p -Machine 0x8664 -ShortImport
        Assert-Equal 0x8664 (Get-ArchiveMachine -LiteralPath $p) 'short-import AMD64 archive'
    }

    It 'Get-ArchiveMachine reads a short-import archive (ARM64)' {
        $p = Join-Path $script:tmp 'arm64.lib'
        & $script:NewArchive -Path $p -Machine 0xAA64 -ShortImport
        Assert-Equal 0xAA64 (Get-ArchiveMachine -LiteralPath $p) 'short-import ARM64 archive'
    }

    It 'Get-ArchiveMachine reads a raw-object archive' {
        $p = Join-Path $script:tmp 'raw.lib'
        & $script:NewArchive -Path $p -Machine 0xAA64
        Assert-Equal 0xAA64 (Get-ArchiveMachine -LiteralPath $p) 'raw-object ARM64 archive'
    }

    It 'Get-ArchiveMachine skips the linker members (/ and //) and reads the first real member' {
        $p = Join-Path $script:tmp 'with-linker.lib'
        # Build an archive with a "/" member first, then the real short-import member.
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("!<arch>`n"))
        # First member: "/" (linker member), size 4
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('/'.PadRight(16)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(12)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('100644'.PadRight(8)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('         4'))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n"))
        $bw.Write([byte[]](0, 0, 0, 0))  # 4-byte payload
        # Second member: real object, short-import, ARM64
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('foo.obj'.PadRight(16)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(12)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('100644'.PadRight(8)))
        $payload = New-Object byte[] 20
        $payload[2] = 0xFF; $payload[3] = 0xFF
        $payload[6] = 0x64; $payload[7] = 0xAA  # 0xAA64 little-endian
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("$($payload.Length)".PadLeft(10)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n"))
        $bw.Write($payload)
        $bw.Flush()
        [IO.File]::WriteAllBytes($p, $ms.ToArray())
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
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("!<arch>`n"))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('foo.obj'.PadRight(16)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(12)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('0'.PadRight(6)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('100644'.PadRight(8)))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('NOTANUMBER'))  # 10 bytes, not a number
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n"))
        $bw.Flush()
        [IO.File]::WriteAllBytes($p, $ms.ToArray())
        $r = Get-ArchiveMachine -LiteralPath $p
        Assert-Null $r 'malformed size returns null, not an exception'
    }

    # ── Format-Machine ──────────────────────────────────────────────────────────

    It 'Format-Machine names a known machine type' {
        Assert-Equal '0x8664 (AMD64)' (Format-Machine 0x8664) 'AMD64 named'
    }

    It 'Format-Machine names an unrecognized machine type' {
        Assert-Equal '0x1234 (UNRECOGNIZED)' (Format-Machine 0x1234) 'unknown machine'
    }
}

Describe 'verify-target-arch: device-OS import allowances (#121 QNN)' {

    It 'classifies the Qualcomm FastRPC drivers as device OS (libcdsprpc/libadsprpc)' {
        $scriptText = Get-Content -Raw (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\build\verify-target-arch.ps1')
        Assert-True ($scriptText.Contains('lib(cds|ads)prpc\.dll')) 'libcdsprpc/libadsprpc must be client-OS allowed (QAIRT HTP stubs import them; they ship in every Windows-on-Snapdragon OS image)'
        Assert-True ($scriptText.Contains('FastRPC')) 'the comment must say why'
    }
}
