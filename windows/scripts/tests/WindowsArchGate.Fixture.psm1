#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Synthetic bytes and child gates exercise file inspection without running target binaries.

function Write-ArchGateBinary {
    param([string]$Path, [scriptblock]$Content)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    $writer = [IO.BinaryWriter]::new($stream)
    try { & $Content $writer } finally { $writer.Dispose(); $stream.Dispose() }
}

function New-ArchGateMachineFile {
    param([Parameter(Mandatory)][string]$Path, [uint16]$Machine, [ValidateSet('Coff', 'BadOffset', 'BadSignature')][string]$Kind = 'Coff')
    Write-ArchGateBinary -Path $Path -Content { param($writer)
        $length = switch ($Kind) { Coff { 4 }; BadOffset { 64 }; BadSignature { 66 } }
        $writer.Write([byte[]]::new($length))
        [void]$writer.Seek(0, [IO.SeekOrigin]::Begin)
        if ($Kind -eq 'Coff') { $writer.Write($Machine); return }
        $writer.Write([byte[]](0x4D, 0x5A))
        [void]$writer.Seek(0x3C, [IO.SeekOrigin]::Begin)
        $writer.Write([uint32]$(if ($Kind -eq 'BadOffset') { 0x100 } else { 0x38 }))
        if ($Kind -eq 'BadSignature') {
            [void]$writer.Seek(0x38, [IO.SeekOrigin]::Begin)
            $writer.Write([byte[]](0x4E, 0x45))
        }
    }
}

function New-ArchGateArchive {
    param([Parameter(Mandatory)][string]$Path, [uint16]$Machine, [switch]$ShortImport,
        [string]$MemberName = 'foo.obj', [switch]$LinkerMember, [switch]$InvalidSize)
    $payload = [byte[]]::new(20)
    $machineOffset = if ($ShortImport) { $payload[2] = 0xFF; $payload[3] = 0xFF; 6 } else { 0 }
    [BitConverter]::GetBytes($Machine).CopyTo($payload, $machineOffset)
    $members = @()
    if ($LinkerMember) { $members += @{ Name = '/'; Payload = [byte[]]::new(4); Size = '4' } }
    $members += @{ Name = $MemberName; Payload = $payload; Size = $(if ($InvalidSize) { 'NOTANUMBER' } else { "$($payload.Length)" }) }
    Write-ArchGateBinary -Path $Path -Content { param($writer)
        $writer.Write([Text.Encoding]::ASCII.GetBytes("!<arch>`n"))
        foreach ($member in $members) {
            foreach ($field in @($member.Name.PadRight(16).Substring(0, 16), '0'.PadRight(12),
                    '0'.PadRight(6), '0'.PadRight(6), '100644'.PadRight(8), $member.Size.PadLeft(10), "`r`n")) {
                $writer.Write([Text.Encoding]::ASCII.GetBytes($field))
            }
            if (-not $InvalidSize) { $writer.Write($member.Payload) }
        }
    }
}

function New-ArchGateWheel {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Member)
    Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    [void](New-TestWheel -Path $Path -Member $Member)
}

function Assert-ArchGateTree {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('amd64', 'arm64')][string]$Arch = 'arm64',
        [switch]$Standalone, [switch]$Fails, [string[]]$Pattern = @())
    $gate = Join-Path (Get-RepoRoot) 'windows/scripts/build/Test-TargetArch.ps1'
    $output = @(& pwsh -NoProfile -File $gate -Path $Path -Arch $Arch -MinInspected 1 -ImportWalk -Standalone:$Standalone 2>&1) -join "`n"
    $code = $LASTEXITCODE
    if ($Fails) { Assert-True ($code -ne 0) "the gate unexpectedly passed: $output" }
    else { Assert-Equal 0 $code "the gate failed: $output" }
    foreach ($expression in $Pattern) { Assert-Match $expression $output }
}

Export-ModuleMember -Function New-ArchGateMachineFile, New-ArchGateArchive, New-ArchGateWheel, Assert-ArchGateTree

function Invoke-ArchGateFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$RootName = 'runtime', [uint16]$Machine = 0xAA64,
        [string[]]$RuntimeDll = @('python\python314.dll'))
    $fixtureBody = $Body
    Invoke-InTestDir { param($dir)
        $root = Join-Path $dir $RootName
        foreach ($dll in $RuntimeDll) { New-OrtTestPe -Path (Join-Path $root $dll) -Machine $Machine -Import 'kernel32.dll' }
        & $fixtureBody $dir $root
    }
}

Export-ModuleMember -Function Invoke-ArchGateFixture
