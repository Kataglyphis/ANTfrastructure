#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: the real rustdesk.exe and its IPC to the service, TCP listeners, Chocolatey or the scheduled task.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsRustDesk.Common.psm1') -Force -DisableNameChecking

function New-FakeRustDesk {
    param([Parameter(Mandatory)][string]$Dir, [string]$CliReply = 'Done!', [switch]$IgnoreSet, [switch]$RefuseAdmin)
    $set = if ($IgnoreSet) { '' } else { '$options[$args[1]] = $args[2]; $options | ConvertTo-Json | Set-Content -LiteralPath $state' }
    $refusal = if ($RefuseAdmin) { "'Installation and administrative privileges required!'; return" } else { '' }
    $path = Join-Path $Dir 'rustdesk.ps1'
    Set-Content -LiteralPath $path -Value @"
$refusal
`$state = Join-Path `$PSScriptRoot 'options.json'
`$options = if (Test-Path -LiteralPath `$state) { Get-Content -LiteralPath `$state -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
if (`$args[0] -eq '--password') { '$CliReply'; return }
if (`$args.Count -eq 2) { "`$(`$options[`$args[1]])"; return }
$set
"@
    return $path
}

function ConvertTo-TestSecureString {
    param([Parameter(Mandatory)][string]$Text)
    return [Net.NetworkCredential]::new('', $Text).SecurePassword
}

Describe 'RustDesk CLI options' {
    It 'sets an option and reads the same value back' {
        $dir = New-TestDir -Prefix 'rustdesk-opt-'
        try {
            $exe = New-FakeRustDesk -Dir $dir
            Assert-Equal '' (Get-RustDeskOption -Exe $exe -Name 'direct-server') 'an unset option reads empty'
            Set-RustDeskOption -Exe $exe -Name 'direct-server' -Value 'Y'
            Assert-Equal 'Y' (Get-RustDeskOption -Exe $exe -Name 'direct-server')
        } finally { Remove-TestDir -Path $dir }
    }

    It 'fails when the service does not keep the value' {
        $dir = New-TestDir -Prefix 'rustdesk-opt-'
        try {
            $exe = New-FakeRustDesk -Dir $dir -IgnoreSet
            Assert-Throws { Set-RustDeskOption -Exe $exe -Name 'direct-server' -Value 'Y' } -MessagePattern "reads '' after setting 'Y'"
        } finally { Remove-TestDir -Path $dir }
    }

    It 'turns the missing-admin reply into an error instead of an empty value' {
        $dir = New-TestDir -Prefix 'rustdesk-opt-'
        try {
            $exe = New-FakeRustDesk -Dir $dir -RefuseAdmin
            Assert-Throws { Get-RustDeskOption -Exe $exe -Name 'direct-server' } -MessagePattern 'administrative privileges required'
        } finally { Remove-TestDir -Path $dir }
    }
}

Describe 'RustDesk permanent password' {
    It 'accepts only the CLI''s Done! reply' {
        $dir = New-TestDir -Prefix 'rustdesk-pw-'
        try {
            Set-RustDeskPermanentPassword -Exe (New-FakeRustDesk -Dir $dir) -Password (ConvertTo-TestSecureString 'pw-123456')
            $locked = New-FakeRustDesk -Dir $dir -CliReply 'Changing permanent password is disabled!'
            Assert-Throws { Set-RustDeskPermanentPassword -Exe $locked -Password (ConvertTo-TestSecureString 'pw-123456') } -MessagePattern 'is disabled'
        } finally { Remove-TestDir -Path $dir }
    }

    It 'keeps the password out of the error message' {
        $dir = New-TestDir -Prefix 'rustdesk-pw-'
        try {
            $echo = New-FakeRustDesk -Dir $dir -CliReply 'rejected secret-pw-42'
            $message = ''
            try { Set-RustDeskPermanentPassword -Exe $echo -Password (ConvertTo-TestSecureString 'secret-pw-42') } catch { $message = $_.Exception.Message }
            Assert-Match 'rejected \*\*\*' $message
            Assert-False ($message.Contains('secret-pw-42')) 'the password must not reach the error text'
        } finally { Remove-TestDir -Path $dir }
    }

    It 'refuses an empty password before calling the CLI' {
        Assert-Throws { Set-RustDeskPermanentPassword -Exe 'C:\missing\rustdesk.exe' -Password ([securestring]::new()) } -MessagePattern 'must not be empty'
    }
}

Describe 'RustDesk session detection' {
    It 'sees an open session only in a connection manager process' {
        $idle = @('--service', '--server', '--tray') | ForEach-Object { [pscustomobject]@{ CommandLine = "`"C:\Program Files\RustDesk\RustDesk.exe`" $_" } }
        Assert-False (Test-RustDeskSessionOpen -Process $idle) 'service, server and tray run without a session'
        Assert-False (Test-RustDeskSessionOpen -Process @([pscustomobject]@{ CommandLine = $null })) 'an unreadable command line is no session'
        $open = $idle + [pscustomobject]@{ CommandLine = '"C:\Program Files\RustDesk\RustDesk.exe" --cm' }
        Assert-True (Test-RustDeskSessionOpen -Process $open)
        Assert-True (Test-RustDeskSessionOpen -Process @([pscustomobject]@{ CommandLine = 'RustDesk.exe --cm-no-ui' }))
    }
}

Describe 'RustDesk config backup' {
    It 'copies the directories that exist and names them' {
        $dir = New-TestDir -Prefix 'rustdesk-bak-' -Files @{ 'service/RustDesk2.toml' = "[options]`ndirect-server = 'Y'" }
        try {
            $config = [pscustomobject]@{ Service = (Join-Path $dir 'service'); User = (Join-Path $dir 'absent') }
            $destination = Join-Path $dir 'backup'
            Assert-Equal 'service' ((Backup-RustDeskConfig -Destination $destination -ConfigDir $config) -join ',')
            Assert-Match "direct-server = 'Y'" (Get-Content -LiteralPath (Join-Path $destination 'service/RustDesk2.toml') -Raw)
            Assert-False (Test-Path -LiteralPath (Join-Path $destination 'user')) 'a missing source leaves no empty directory'
        } finally { Remove-TestDir -Path $dir }
    }
}

Describe 'Chocolatey installer signature' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Install-RustDesk.ps1' -FunctionName 'Assert-ChocolateyInstallerSignature')
    $chocolatey = 'CN="Chocolatey Software, Inc", O="Chocolatey Software, Inc", L=Topeka, S=Kansas, C=US'
    function New-TestSignature {
        param([string]$Status, [string]$Subject)
        return [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }
    }

    It 'accepts a valid signature from Chocolatey Software' {
        Assert-ChocolateyInstallerSignature -Signature (New-TestSignature -Status Valid -Subject $chocolatey)
    }

    It 'refuses a broken signature and another signer' {
        Assert-Throws { Assert-ChocolateyInstallerSignature -Signature (New-TestSignature -Status HashMismatch -Subject $chocolatey) } -MessagePattern 'HashMismatch'
        Assert-Throws { Assert-ChocolateyInstallerSignature -Signature (New-TestSignature -Status NotSigned -Subject '') } -MessagePattern 'NotSigned'
        $other = 'CN="Chocolatey Software, Inc", O="Evil Corp", C=US'
        Assert-Throws { Assert-ChocolateyInstallerSignature -Signature (New-TestSignature -Status Valid -Subject $other) } -MessagePattern 'not by Chocolatey'
    }
}
